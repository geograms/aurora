/*
 * mesh_session — the Mesh Session Protocol v1 (MSP), doc/mesh.md §3 Plane 2.
 *
 * MSP is the mesh's GATT data plane: once two nodes hold a GATT link
 * (FFE0/FFF1/FFF2 — the same channel the legacy parcel transport uses), MSP
 * frames move message custody, gossip and bulk file chunks between them.
 * Every frame fits one ATT write/notify and starts with the magic 0x4D 0x01,
 * which cannot collide with legacy parcels (their second byte is an A-Z
 * letter) nor JSON receipts (first byte '{') — the demux in ble_service_io
 * routes on that prefix and everything else flows to the old path untouched.
 *
 * The protocol is deliberately flat and little-endian so the ESP32 mirror
 * (esp32/components/geogram_blemesh/blemesh_session.c) is a line-for-line
 * port; test/mesh_session_test.dart carries hex fixtures both codecs must
 * reproduce byte-identically.
 *
 * Session shape (either side may carry any lane after HELLO — "symmetric"):
 *
 *   dialer                            served
 *     HELLO  ------------------------>
 *            <------------------------  HELLO
 *     GOSSIP <----------------------->  GOSSIP        (control swap)
 *     MSG*   <----------------------->  MSG_ACK/REJ   (custody, both ways)
 *     FILE_OFFER/CHUNK/WIN_ACK <----->  ...           (bulk, one at a time)
 *     BYE    ------------------------>                 (politeness or done)
 *
 * Custody semantics: a MSG_ACK is the handover — the sender demotes its copy
 * to archive the moment the ack lands (doc/mesh.md §6). Bulk custody is the
 * FILE_OK after a full-file SHA-256 verify on the receiver's spool.
 *
 * Flow control: chunk data is paced by the transport (write-with-response on
 * the client→server direction, native notify pump on server→client) plus the
 * app-level WIN_ACK credit window on top, which doubles as the resync point —
 * the receiver states the next contiguous offset it wants, so a lost chunk
 * costs one window, not the transfer.
 */
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

const int kMspMagic = 0x4D;
const int kMspVersion = 0x01;

/// Frame types.
class MspType {
  static const hello = 0x01;
  static const gossip = 0x02;
  static const bye = 0x03;
  static const msg = 0x10;
  static const msgAck = 0x11;
  static const msgRej = 0x12;
  static const fileOffer = 0x20;
  static const fileAccept = 0x21;
  static const fileReject = 0x22;
  static const chunk = 0x23;
  static const winAck = 0x24;
  static const fileDone = 0x25;
  static const fileOk = 0x26;
  static const fileFail = 0x27;
}

/// HELLO capability bits.
class MspCaps {
  static const msgCustody = 1 << 0;
  static const bulkRx = 1 << 1;
  static const bulkTx = 1 << 2;
  static const gossip = 1 << 3;
  static const writeNoResponse = 1 << 4; // phase-2 upgrade, reserved
}

const int kMspMaxCallsign = 9;
const int kMspChunkHeader = 3 + 4 + 4; // envelope + xfer + offset
const int kMspDefaultWindow = 16;
const int kMspMsgBatchMax = 32;

// ---------------------------------------------------------------------------
// Codec — small writer/reader over the flat LE wire format.
// ---------------------------------------------------------------------------

class _W {
  final BytesBuilder b = BytesBuilder();
  void u8(int v) => b.addByte(v & 0xFF);
  void u16(int v) {
    b.addByte(v & 0xFF);
    b.addByte((v >> 8) & 0xFF);
  }

  void u32(int v) {
    for (var i = 0; i < 4; i++) {
      b.addByte((v >> (8 * i)) & 0xFF);
    }
  }

  void u64(int v) {
    for (var i = 0; i < 8; i++) {
      b.addByte((v >> (8 * i)) & 0xFF);
    }
  }

  void bytes(List<int> d) => b.add(d);

  /// Callsign-style string: [len u8][ASCII], truncated to [max].
  void cs(String s, {int max = kMspMaxCallsign}) {
    final d = s.codeUnits.where((c) => c >= 0x20 && c < 0x7F).take(max).toList();
    u8(d.length);
    bytes(d);
  }
}

class _R {
  final Uint8List d;
  int o = 0;
  _R(this.d);
  bool get ok => o <= d.length;
  int u8() {
    if (o + 1 > d.length) {
      o = d.length + 1;
      return 0;
    }
    return d[o++];
  }
  int u16() {
    if (o + 2 > d.length) {
      o = d.length + 1;
      return 0;
    }
    final v = d[o] | (d[o + 1] << 8);
    o += 2;
    return v;
  }

  int u32() {
    if (o + 4 > d.length) {
      o = d.length + 1;
      return 0;
    }
    var v = 0;
    for (var i = 0; i < 4; i++) {
      v |= d[o + i] << (8 * i);
    }
    o += 4;
    return v;
  }

  int u64() {
    if (o + 8 > d.length) {
      o = d.length + 1;
      return 0;
    }
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v |= d[o + i] << (8 * i);
    }
    o += 8;
    return v;
  }

  Uint8List bytes(int n) {
    if (n < 0 || o + n > d.length) {
      o = d.length + 1;
      return Uint8List(0);
    }
    final r = Uint8List.sublistView(d, o, o + n);
    o += n;
    return r;
  }

  String cs({int max = 64}) {
    final n = u8();
    if (n > max) {
      o = d.length + 1;
      return '';
    }
    return String.fromCharCodes(bytes(n));
  }
}

Uint8List _env(int type, _W body) {
  final b = BytesBuilder();
  b.addByte(kMspMagic);
  b.addByte(kMspVersion);
  b.addByte(type);
  b.add(body.b.toBytes());
  return b.toBytes();
}

/// True when [data] is an MSP frame (the ble_service_io demux test).
bool mspIsFrame(Uint8List data) =>
    data.length >= 3 && data[0] == kMspMagic && data[1] == kMspVersion;

/// Decode a full MSP frame to its typed form; null on malformed/unknown.
Object? mspDecode(Uint8List frame) {
  if (!mspIsFrame(frame)) return null;
  final r = _R(Uint8List.sublistView(frame, 3));
  switch (frame[2]) {
    case MspType.hello:
      return MspHello._decode(r);
    case MspType.gossip:
      return MspGossip._decode(r);
    case MspType.msg:
      return MspMsg._decode(r);
    case MspType.msgAck:
      return MspMsgAck._decode(r);
    case MspType.msgRej:
      return MspMsgRej._decode(r);
    case MspType.fileOffer:
      return MspFileOffer._decode(r);
    case MspType.fileAccept:
      return MspFileAccept._decode(r);
    case MspType.fileReject:
      return MspFileReject._decode(r);
    case MspType.chunk:
      return MspChunk._decode(r);
    case MspType.winAck:
      return MspWinAck._decode(r);
    default:
      return null;
  }
}

// --- typed frames -----------------------------------------------------------

class MspHello {
  final int caps;
  final String callsign;
  final int maxFrame;
  final int spoolFreeKb;
  final int pendingMsgs;
  final int pendingBulk;
  MspHello({
    required this.caps,
    required this.callsign,
    required this.maxFrame,
    this.spoolFreeKb = 0,
    this.pendingMsgs = 0,
    this.pendingBulk = 0,
  });

  Uint8List encode() {
    final w = _W()
      ..u16(caps)
      ..cs(callsign)
      ..u16(maxFrame)
      ..u32(spoolFreeKb)
      ..u16(pendingMsgs)
      ..u8(pendingBulk);
    return _env(MspType.hello, w);
  }

  static MspHello? _decode(_R r) {
    final caps = r.u16();
    final cs = r.cs(max: kMspMaxCallsign);
    final mf = r.u16();
    final sf = r.u32();
    final pm = r.u16();
    final pb = r.u8();
    if (!r.ok || cs.isEmpty) return null;
    return MspHello(
        caps: caps,
        callsign: cs,
        maxFrame: mf,
        spoolFreeKb: sf,
        pendingMsgs: pm,
        pendingBulk: pb);
  }
}

class MspGossipEntry {
  final Uint8List hash; // 3 bytes
  final int cost;
  MspGossipEntry(this.hash, this.cost);
}

class MspGossip {
  final bool more;
  final List<MspGossipEntry> entries;
  final Uint8List bloom; // only on the last frame; empty otherwise
  MspGossip({this.more = false, this.entries = const [], Uint8List? bloom})
      : bloom = bloom ?? Uint8List(0);

  Uint8List encode() {
    final w = _W()..u8(more ? 1 : 0)..u8(entries.length.clamp(0, 255));
    for (final e in entries.take(255)) {
      w.bytes(e.hash.sublist(0, 3));
      w.u8(e.cost);
    }
    w.u16(bloom.length);
    w.bytes(bloom);
    return _env(MspType.gossip, w);
  }

  static MspGossip? _decode(_R r) {
    final flags = r.u8();
    final k = r.u8();
    final es = <MspGossipEntry>[];
    for (var i = 0; i < k; i++) {
      final h = Uint8List.fromList(r.bytes(3));
      final c = r.u8();
      if (!r.ok) return null;
      es.add(MspGossipEntry(h, c));
    }
    final bl = r.u16();
    final bloom = Uint8List.fromList(r.bytes(bl));
    if (!r.ok) return null;
    return MspGossip(more: (flags & 1) != 0, entries: es, bloom: bloom);
  }
}

class MspBye {
  static const done = 0, politeness = 1, error = 2;
  final int reason;
  MspBye(this.reason);
  Uint8List encode() => _env(MspType.bye, _W()..u8(reason));
}

class MspMsg {
  final int seq;
  final String am; // 6 chars or empty
  final int ts; // epoch seconds
  final Uint8List wire; // raw compact 0x41 frame
  MspMsg({required this.seq, this.am = '', required this.ts, required this.wire});

  Uint8List encode() {
    final amB = List<int>.filled(6, 0);
    for (var i = 0; i < am.length && i < 6; i++) {
      amB[i] = am.codeUnitAt(i);
    }
    final w = _W()
      ..u8(seq)
      ..u8(am.isNotEmpty ? 1 : 0)
      ..bytes(amB)
      ..u32(ts)
      ..u16(wire.length)
      ..bytes(wire);
    return _env(MspType.msg, w);
  }

  static MspMsg? _decode(_R r) {
    final seq = r.u8();
    final flags = r.u8();
    final amB = r.bytes(6);
    final ts = r.u32();
    final wl = r.u16();
    final wire = Uint8List.fromList(r.bytes(wl));
    if (!r.ok) return null;
    final am = (flags & 1) != 0
        ? String.fromCharCodes(amB.where((b) => b != 0))
        : '';
    return MspMsg(seq: seq, am: am, ts: ts, wire: wire);
  }
}

class MspMsgAck {
  final List<int> seqs;
  MspMsgAck(this.seqs);
  Uint8List encode() {
    final w = _W()..u8(seqs.length.clamp(0, 255));
    for (final s in seqs.take(255)) {
      w.u8(s);
    }
    return _env(MspType.msgAck, w);
  }

  static MspMsgAck? _decode(_R r) {
    final n = r.u8();
    final seqs = <int>[];
    for (var i = 0; i < n; i++) {
      seqs.add(r.u8());
    }
    if (!r.ok) return null;
    return MspMsgAck(seqs);
  }
}

class MspMsgRej {
  static const duplicate = 1, quota = 2, malformed = 3;
  final int seq;
  final int reason;
  MspMsgRej(this.seq, this.reason);
  Uint8List encode() => _env(MspType.msgRej, _W()..u8(seq)..u8(reason));
  static MspMsgRej? _decode(_R r) {
    final s = r.u8();
    final re = r.u8();
    if (!r.ok) return null;
    return MspMsgRej(s, re);
  }
}

class MspFileOffer {
  final int xfer;
  final Uint8List sha256; // 32 bytes
  final int size;
  final int ttlS;
  final String origin;
  final String target;
  final String ext;
  final String name;
  MspFileOffer({
    required this.xfer,
    required this.sha256,
    required this.size,
    required this.ttlS,
    required this.origin,
    required this.target,
    this.ext = '',
    this.name = '',
  });

  Uint8List encode() {
    final w = _W()
      ..u32(xfer)
      ..bytes(sha256.sublist(0, 32))
      ..u64(size)
      ..u32(ttlS)
      ..cs(origin)
      ..cs(target)
      ..cs(ext, max: 16)
      ..cs(name, max: 64);
    return _env(MspType.fileOffer, w);
  }

  static MspFileOffer? _decode(_R r) {
    final x = r.u32();
    final sha = Uint8List.fromList(r.bytes(32));
    final size = r.u64();
    final ttl = r.u32();
    final origin = r.cs(max: kMspMaxCallsign);
    final target = r.cs(max: kMspMaxCallsign);
    final ext = r.cs(max: 16);
    final name = r.cs(max: 64);
    if (!r.ok || origin.isEmpty) return null;
    return MspFileOffer(
        xfer: x,
        sha256: sha,
        size: size,
        ttlS: ttl,
        origin: origin,
        target: target,
        ext: ext,
        name: name);
  }
}

class MspFileAccept {
  final int xfer;
  final int offset;
  final int window;
  MspFileAccept(this.xfer, this.offset, this.window);
  Uint8List encode() =>
      _env(MspType.fileAccept, _W()..u32(xfer)..u32(offset)..u16(window));
  static MspFileAccept? _decode(_R r) {
    final x = r.u32();
    final o = r.u32();
    final w = r.u16();
    if (!r.ok) return null;
    return MspFileAccept(x, o, w);
  }
}

class MspFileReject {
  static const quota = 1, noRoute = 2, busy = 3, expired = 4;
  final int xfer;
  final int reason;
  MspFileReject(this.xfer, this.reason);
  Uint8List encode() => _env(MspType.fileReject, _W()..u32(xfer)..u8(reason));
  static MspFileReject? _decode(_R r) {
    final x = r.u32();
    final re = r.u8();
    if (!r.ok) return null;
    return MspFileReject(x, re);
  }
}

class MspChunk {
  final int xfer;
  final int offset;
  final Uint8List data;
  MspChunk(this.xfer, this.offset, this.data);
  Uint8List encode() =>
      _env(MspType.chunk, _W()..u32(xfer)..u32(offset)..bytes(data));
  static MspChunk? _decode(_R r) {
    final x = r.u32();
    final o = r.u32();
    if (!r.ok) return null;
    final data = Uint8List.fromList(r.bytes(r.d.length - r.o));
    return MspChunk(x, o, data);
  }
}

class MspWinAck {
  final int xfer;
  final int nextOffset;
  final int window;
  MspWinAck(this.xfer, this.nextOffset, this.window);
  Uint8List encode() =>
      _env(MspType.winAck, _W()..u32(xfer)..u32(nextOffset)..u16(window));
  static MspWinAck? _decode(_R r) {
    final x = r.u32();
    final o = r.u32();
    final w = r.u16();
    if (!r.ok) return null;
    return MspWinAck(x, o, w);
  }
}

class MspXferSignal {
  final int type; // fileDone / fileOk / fileFail
  final int xfer;
  final int reason; // fileFail only
  MspXferSignal(this.type, this.xfer, {this.reason = 0});
  Uint8List encode() {
    final w = _W()..u32(xfer);
    if (type == MspType.fileFail) w.u8(reason);
    return _env(type, w);
  }
}

class MspFileFailReason {
  static const hashMismatch = 1, io = 2, cancelled = 3;
}

// ---------------------------------------------------------------------------
// Session delegate — everything the FSM needs from store/spool/table, kept
// abstract so unit tests can drive two sessions back-to-back in memory.
// ---------------------------------------------------------------------------

/// One parked message offered for custody handover.
class MeshPendingMsg {
  final String am; // '' when the frame carries no receipt id
  final Uint8List wire; // raw compact 0x41 frame
  final int ts; // epoch seconds
  /// Store lookup key (== am, or the content pseudo-key for am-less frames).
  /// Never goes on the wire.
  final String key;
  MeshPendingMsg(
      {required this.am, required this.wire, required this.ts, String? key})
      : key = key ?? am;
}

/// One spooled file ready to move to this peer.
class MeshBulkPending {
  final Uint8List sha256;
  final int size;
  final int ttlS;
  final String origin;
  final String target;
  final String ext;
  final String name;
  MeshBulkPending({
    required this.sha256,
    required this.size,
    required this.ttlS,
    required this.origin,
    required this.target,
    this.ext = '',
    this.name = '',
  });
}

/// Receiver's answer to an inbound FILE_OFFER.
class MeshBulkDecision {
  final bool accept;
  final int offset; // resume point; == size means "already have it"
  final int rejectReason;
  const MeshBulkDecision.accept(this.offset)
      : accept = true,
        rejectReason = 0;
  const MeshBulkDecision.reject(this.rejectReason)
      : accept = false,
        offset = 0;
}

abstract class MeshSessionDelegate {
  /// Messages parked for/via [peer], up to [max]. Called repeatedly until empty.
  List<MeshPendingMsg> custodyBatchFor(String peer, int max);

  /// Peer accepted custody of [m] — demote our copy to archive.
  void custodyTransferred(String peer, MeshPendingMsg m);

  /// Inbound custody message. Return 0 = accepted (ack), or an MspMsgRej
  /// reason (duplicate also acks custody semantically — sender archives).
  int msgReceived(String peer, MspMsg m);

  /// Our own DV digest + have-bloom for the gossip swap.
  MspGossip gossipData();

  /// Peer's gossip landed (feed the mesh table + purge bloom matches).
  void gossipReceived(String peer, MspGossip g);

  /// Next spooled file to move to [peer], or null.
  MeshBulkPending? nextBulkFor(String peer);

  /// Inbound FILE_OFFER — open/inspect spool, return the resume decision.
  MeshBulkDecision bulkOffered(String peer, MspFileOffer offer);

  /// Read up to [len] payload bytes at [offset] for an outbound transfer.
  /// Returns an empty list at EOF or on error.
  Uint8List bulkRead(Uint8List sha256, int offset, int len);

  /// Persist inbound chunk. False on I/O error (transfer fails).
  bool bulkWrite(Uint8List sha256, int offset, Uint8List data);

  /// Full-file SHA-256 verify of the inbound spool. True = custody taken.
  bool bulkVerified(Uint8List sha256);

  /// Transfer finished (either direction). [ok] false = failed/rejected.
  /// [toPeer] true when we were sending. offset==size dup-accepts count as ok.
  void bulkDone(String peer, Uint8List sha256, bool ok, {required bool toPeer});

  /// Session ended (link down, BYE, or timeout).
  void sessionClosed(String peer, {required bool clean});
}

// ---------------------------------------------------------------------------
// Session FSM
// ---------------------------------------------------------------------------

enum MeshSessionState { hello, active, closed }

/// One MSP session over one live GATT link.
class MeshSession {
  final bool dialer; // we initiated the connection
  final String selfCallsign;
  final int caps;
  final int maxFrame; // ATT payload budget for our sends
  final Future<void> Function(Uint8List frame) send;
  final MeshSessionDelegate delegate;
  final Duration helloTimeout;
  final Duration sessionCap; // politeness: BYE + drop when exceeded
  final Duration stallTimeout;
  final void Function(String msg)? log;

  MeshSessionState state = MeshSessionState.hello;
  String peerCallsign = '';
  int peerCaps = 0;
  int peerMaxFrame = 0;
  int peerPendingMsgs = 0;
  int peerPendingBulk = 0;

  final DateTime _openedAt = DateTime.now();
  DateTime _lastRx = DateTime.now();
  Timer? _helloTimer;
  Timer? _stallTimer;
  bool _helloSent = false;
  bool _byeSent = false;

  // custody tx: seq -> pending message awaiting MSG_ACK/REJ
  final Map<int, MeshPendingMsg> _outMsgs = {};
  int _nextSeq = 0;
  bool _custodyDraining = false;
  bool _custodyDrained = false;

  // bulk tx (we send)
  _BulkTx? _tx;
  // bulk rx (we receive)
  _BulkRx? _rx;

  int spoolFreeKb;
  int pendingMsgs;
  int pendingBulk;

  MeshSession({
    required this.dialer,
    required this.selfCallsign,
    required this.send,
    required this.delegate,
    this.caps = MspCaps.msgCustody |
        MspCaps.bulkRx |
        MspCaps.bulkTx |
        MspCaps.gossip,
    this.maxFrame = 509,
    this.spoolFreeKb = 0,
    this.pendingMsgs = 0,
    this.pendingBulk = 0,
    this.helloTimeout = const Duration(seconds: 5),
    this.sessionCap = const Duration(seconds: 300),
    this.stallTimeout = const Duration(seconds: 30),
    this.log,
  });

  bool get pastCap => DateTime.now().difference(_openedAt) > sessionCap;
  bool get bulkActive => _tx != null || _rx != null;

  /// True when nothing is outstanding — a link drop now is a clean end.
  bool get idle => _outMsgs.isEmpty && !bulkActive && _custodyDrained;

  /// Kick the session off. The dialer speaks first; the served side waits
  /// for the peer's HELLO (its answer goes out from _onHello).
  Future<void> start() async {
    _helloTimer = Timer(helloTimeout, () {
      if (state == MeshSessionState.hello) {
        _log('hello timeout');
        close(clean: false);
      }
    });
    if (dialer) await _sendHello();
  }

  Future<void> _sendHello() async {
    if (_helloSent) return;
    _helloSent = true;
    await _safeSend(MspHello(
      caps: caps,
      callsign: selfCallsign,
      maxFrame: maxFrame,
      spoolFreeKb: spoolFreeKb,
      pendingMsgs: pendingMsgs,
      pendingBulk: pendingBulk,
    ).encode());
  }

  /// Feed one inbound MSP frame (already demuxed by prefix).
  Future<void> onFrame(Uint8List data) async {
    if (state == MeshSessionState.closed || data.length < 3) return;
    _lastRx = DateTime.now();
    final type = data[2];
    final r = _R(Uint8List.sublistView(data, 3));
    switch (type) {
      case MspType.hello:
        final h = MspHello._decode(r);
        if (h != null) await _onHello(h);
      case MspType.gossip:
        final g = MspGossip._decode(r);
        if (g != null && state == MeshSessionState.active) {
          delegate.gossipReceived(peerCallsign, g);
        }
      case MspType.bye:
        _log('peer bye');
        close(clean: true, notifyPeer: false);
      case MspType.msg:
        final m = MspMsg._decode(r);
        if (m != null && state == MeshSessionState.active) await _onMsg(m);
      case MspType.msgAck:
        final a = MspMsgAck._decode(r);
        if (a != null) await _onMsgAck(a.seqs);
      case MspType.msgRej:
        final j = MspMsgRej._decode(r);
        if (j != null) await _onMsgRej(j);
      case MspType.fileOffer:
        final o = MspFileOffer._decode(r);
        if (o != null && state == MeshSessionState.active) await _onOffer(o);
      case MspType.fileAccept:
        final a = MspFileAccept._decode(r);
        if (a != null) await _onAccept(a);
      case MspType.fileReject:
        final j = MspFileReject._decode(r);
        if (j != null) _onReject(j);
      case MspType.chunk:
        final c = MspChunk._decode(r);
        if (c != null) await _onChunk(c);
      case MspType.winAck:
        final w = MspWinAck._decode(r);
        if (w != null) await _onWinAck(w);
      case MspType.fileDone:
        await _onFileDone(_R(Uint8List.sublistView(data, 3)).u32());
      case MspType.fileOk:
        _onFileOk(_R(Uint8List.sublistView(data, 3)).u32());
      case MspType.fileFail:
        final rr = _R(Uint8List.sublistView(data, 3));
        _onFileFail(rr.u32(), rr.u8());
      default:
        _log('unknown frame type 0x${type.toRadixString(16)}');
    }
  }

  Future<void> _onHello(MspHello h) async {
    if (state != MeshSessionState.hello) return;
    peerCallsign = h.callsign;
    peerCaps = h.caps;
    peerMaxFrame = h.maxFrame;
    peerPendingMsgs = h.pendingMsgs;
    peerPendingBulk = h.pendingBulk;
    _helloTimer?.cancel();
    state = MeshSessionState.active;
    _log('session with $peerCallsign caps=0x${h.caps.toRadixString(16)} '
        'pending=${h.pendingMsgs}/${h.pendingBulk}');
    _armStall();
    if (!dialer) await _sendHello();
    // Control swap first, then custody, then bulk — mail beats media.
    if ((peerCaps & MspCaps.gossip) != 0) {
      await _safeSend(delegate.gossipData().encode());
    }
    if ((peerCaps & MspCaps.msgCustody) != 0) await _drainCustody();
    await _maybeStartBulk();
  }

  // --- custody lane ---------------------------------------------------------

  Future<void> _drainCustody() async {
    if (_custodyDraining || state != MeshSessionState.active) return;
    _custodyDraining = true;
    try {
      while (state == MeshSessionState.active && _outMsgs.length < 64) {
        final batch = delegate.custodyBatchFor(peerCallsign, kMspMsgBatchMax);
        if (batch.isEmpty) break;
        for (final m in batch) {
          final seq = _nextSeq = (_nextSeq + 1) & 0xFF;
          _outMsgs[seq] = m;
          await _safeSend(
              MspMsg(seq: seq, am: m.am, ts: m.ts, wire: m.wire).encode());
        }
        if (batch.length < kMspMsgBatchMax) break;
      }
    } finally {
      _custodyDraining = false;
      _custodyDrained = true;
    }
  }

  final List<int> _ackQueue = [];
  Timer? _ackTimer;

  Future<void> _onMsg(MspMsg m) async {
    final rc = delegate.msgReceived(peerCallsign, m);
    if (rc == 0 || rc == MspMsgRej.duplicate) {
      // Duplicates ack too — sender must archive either way.
      _ackQueue.add(m.seq);
      _ackTimer ??= Timer(const Duration(milliseconds: 150), () {
        _ackTimer = null;
        final seqs = List<int>.from(_ackQueue);
        _ackQueue.clear();
        if (seqs.isNotEmpty && state == MeshSessionState.active) {
          _safeSend(MspMsgAck(seqs).encode());
        }
      });
    } else {
      await _safeSend(MspMsgRej(m.seq, rc).encode());
    }
  }

  Future<void> _onMsgAck(List<int> seqs) async {
    for (final s in seqs) {
      final m = _outMsgs.remove(s);
      if (m != null) delegate.custodyTransferred(peerCallsign, m);
    }
    if (_outMsgs.isEmpty && _custodyDrained) {
      await _drainCustody(); // more may have queued meanwhile
      await _maybeStartBulk();
    }
  }

  Future<void> _onMsgRej(MspMsgRej j) async {
    final m = _outMsgs.remove(j.seq);
    if (m != null && j.reason == MspMsgRej.duplicate) {
      delegate.custodyTransferred(peerCallsign, m); // peer has it — archive
    }
    // quota/malformed: drop from session; store retries elsewhere later.
    if (_outMsgs.isEmpty && _custodyDrained) await _maybeStartBulk();
  }

  // --- bulk lane ------------------------------------------------------------

  Future<void> _maybeStartBulk() async {
    if (state != MeshSessionState.active || bulkActive || pastCap) return;
    if ((peerCaps & MspCaps.bulkRx) == 0) return;
    final next = delegate.nextBulkFor(peerCallsign);
    if (next == null) return;
    final xfer = Random().nextInt(0xFFFFFFFF);
    _tx = _BulkTx(xfer: xfer, item: next);
    _log('offer ${next.name} (${next.size} B) -> $peerCallsign');
    await _safeSend(MspFileOffer(
      xfer: xfer,
      sha256: next.sha256,
      size: next.size,
      ttlS: next.ttlS,
      origin: next.origin,
      target: next.target,
      ext: next.ext,
      name: next.name,
    ).encode());
  }

  Future<void> _onOffer(MspFileOffer o) async {
    if (_rx != null) {
      await _safeSend(MspFileReject(o.xfer, MspFileReject.busy).encode());
      return;
    }
    // Simultaneous offers: the dialer wins — the served side parks its own
    // outbound and takes the inbound (it retries next session).
    if (_tx != null && !dialer) {
      delegate.bulkDone(peerCallsign, _tx!.item.sha256, false, toPeer: true);
      _tx = null;
    } else if (_tx != null) {
      await _safeSend(MspFileReject(o.xfer, MspFileReject.busy).encode());
      return;
    }
    final d = delegate.bulkOffered(peerCallsign, o);
    if (!d.accept) {
      await _safeSend(MspFileReject(o.xfer, d.rejectReason).encode());
      return;
    }
    if (d.offset >= o.size) {
      // Already have the whole file — accept-at-size is the dup-suppression
      // handshake; the sender records a handover without sending a byte.
      await _safeSend(MspFileAccept(o.xfer, o.size, 0).encode());
      return;
    }
    _rx = _BulkRx(xfer: o.xfer, offer: o, offset: d.offset);
    _log('accept ${o.name} from $peerCallsign at ${d.offset}/${o.size}');
    await _safeSend(
        MspFileAccept(o.xfer, d.offset, kMspDefaultWindow).encode());
  }

  Future<void> _onAccept(MspFileAccept a) async {
    final tx = _tx;
    if (tx == null || a.xfer != tx.xfer) return;
    if (a.offset >= tx.item.size) {
      // Peer already has it — custody handover without transfer.
      _tx = null;
      delegate.bulkDone(peerCallsign, tx.item.sha256, true, toPeer: true);
      await _maybeStartBulk();
      return;
    }
    tx.offset = a.offset;
    await _pumpChunks(tx, a.window);
  }

  Future<void> _pumpChunks(_BulkTx tx, int window) async {
    final chunkMax = min(maxFrame, peerMaxFrame == 0 ? maxFrame : peerMaxFrame) -
        kMspChunkHeader;
    var n = 0;
    while (n < window &&
        tx.offset < tx.item.size &&
        state == MeshSessionState.active &&
        _tx == tx) {
      final want = min(chunkMax, tx.item.size - tx.offset);
      final data = delegate.bulkRead(tx.item.sha256, tx.offset, want);
      if (data.isEmpty) {
        _log('bulk read failed at ${tx.offset}');
        await _safeSend(MspXferSignal(MspType.fileFail, tx.xfer,
                reason: MspFileFailReason.io)
            .encode());
        _tx = null;
        delegate.bulkDone(peerCallsign, tx.item.sha256, false, toPeer: true);
        return;
      }
      await _safeSend(MspChunk(tx.xfer, tx.offset, data).encode());
      tx.offset += data.length;
      n++;
    }
    if (_tx == tx && tx.offset >= tx.item.size) {
      await _safeSend(MspXferSignal(MspType.fileDone, tx.xfer).encode());
    }
    // Politeness: past the cap we stop granting ourselves more windows; the
    // receiver's spool keeps the offset, next session resumes from there.
    if (pastCap && _tx == tx && tx.offset < tx.item.size) {
      _log('session cap during bulk — cycling');
      await bye(MspBye.politeness);
    }
  }

  Future<void> _onWinAck(MspWinAck w) async {
    final tx = _tx;
    if (tx == null || w.xfer != tx.xfer) return;
    tx.offset = w.nextOffset; // resync point — receiver states what it wants
    await _pumpChunks(tx, w.window);
  }

  Future<void> _onChunk(MspChunk c) async {
    final rx = _rx;
    if (rx == null || c.xfer != rx.xfer) return;
    if (c.offset != rx.offset) {
      // Gap (lost/reordered chunk) — resync: ask again from our offset.
      rx.badSince++;
      if (rx.badSince == 1) {
        await _safeSend(
            MspWinAck(rx.xfer, rx.offset, kMspDefaultWindow).encode());
      }
      return;
    }
    rx.badSince = 0;
    if (!delegate.bulkWrite(rx.offer.sha256, c.offset, c.data)) {
      await _safeSend(MspXferSignal(MspType.fileFail, rx.xfer,
              reason: MspFileFailReason.io)
          .encode());
      _rx = null;
      delegate.bulkDone(peerCallsign, rx.offer.sha256, false, toPeer: false);
      return;
    }
    rx.offset += c.data.length;
    rx.sinceAck++;
    if (rx.sinceAck >= kMspDefaultWindow && rx.offset < rx.offer.size) {
      rx.sinceAck = 0;
      await _safeSend(
          MspWinAck(rx.xfer, rx.offset, kMspDefaultWindow).encode());
    }
  }

  Future<void> _onFileDone(int xfer) async {
    final rx = _rx;
    if (rx == null || xfer != rx.xfer) return;
    if (rx.offset < rx.offer.size) {
      // DONE arrived but we have a hole — resync once more.
      await _safeSend(
          MspWinAck(rx.xfer, rx.offset, kMspDefaultWindow).encode());
      return;
    }
    final ok = delegate.bulkVerified(rx.offer.sha256);
    _rx = null;
    await _safeSend(ok
        ? MspXferSignal(MspType.fileOk, xfer).encode()
        : MspXferSignal(MspType.fileFail, xfer,
                reason: MspFileFailReason.hashMismatch)
            .encode());
    _log(ok
        ? 'bulk rx complete ${rx.offer.name} (${rx.offer.size} B)'
        : 'bulk rx HASH MISMATCH ${rx.offer.name}');
    delegate.bulkDone(peerCallsign, rx.offer.sha256, ok, toPeer: false);
  }

  void _onFileOk(int xfer) {
    final tx = _tx;
    if (tx == null || xfer != tx.xfer) return;
    _tx = null;
    delegate.bulkDone(peerCallsign, tx.item.sha256, true, toPeer: true);
    _maybeStartBulk();
  }

  void _onFileFail(int xfer, int reason) {
    final tx = _tx;
    if (tx != null && xfer == tx.xfer) {
      _tx = null;
      _log('bulk tx failed reason=$reason');
      delegate.bulkDone(peerCallsign, tx.item.sha256, false, toPeer: true);
      return;
    }
    final rx = _rx;
    if (rx != null && xfer == rx.xfer) {
      _rx = null;
      delegate.bulkDone(peerCallsign, rx.offer.sha256, false, toPeer: false);
    }
  }

  void _onReject(MspFileReject j) {
    final tx = _tx;
    if (tx == null || j.xfer != tx.xfer) return;
    _tx = null;
    _log('offer rejected reason=${j.reason}');
    delegate.bulkDone(peerCallsign, tx.item.sha256, false, toPeer: true);
  }

  // --- lifecycle ------------------------------------------------------------

  void _armStall() {
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (state != MeshSessionState.active) return;
      if (DateTime.now().difference(_lastRx) > stallTimeout &&
          (bulkActive || _outMsgs.isNotEmpty)) {
        _log('session stall — closing');
        close(clean: false);
      }
    });
  }

  /// Say goodbye and close (politeness cycle or done).
  Future<void> bye(int reason) async {
    if (_byeSent || state == MeshSessionState.closed) return;
    _byeSent = true;
    await _safeSend(MspBye(reason).encode());
    close(clean: true, notifyPeer: false);
  }

  /// How this session ended (valid once state == closed).
  bool closedClean = false;

  /// Tear the session down. [notifyPeer] has no wire effect here (BYE is
  /// explicit via [bye]); the owner drops the GATT link after this returns.
  void close({required bool clean, bool notifyPeer = true}) {
    if (state == MeshSessionState.closed) return;
    state = MeshSessionState.closed;
    closedClean = clean;
    _helloTimer?.cancel();
    _stallTimer?.cancel();
    _ackTimer?.cancel();
    final tx = _tx;
    if (tx != null) {
      delegate.bulkDone(peerCallsign, tx.item.sha256, false, toPeer: true);
    }
    final rx = _rx;
    if (rx != null) {
      // Spool keeps the bytes — next session resumes from the offset.
      delegate.bulkDone(peerCallsign, rx.offer.sha256, false, toPeer: false);
    }
    _tx = null;
    _rx = null;
    delegate.sessionClosed(peerCallsign, clean: clean);
  }

  Future<void> _safeSend(Uint8List frame) async {
    if (state == MeshSessionState.closed) return;
    try {
      await send(frame);
    } catch (e) {
      _log('send failed: $e');
      close(clean: false);
    }
  }

  void _log(String m) => log?.call('MSP${dialer ? ">" : "<"} $m');
}

class _BulkTx {
  final int xfer;
  final MeshBulkPending item;
  int offset = 0;
  _BulkTx({required this.xfer, required this.item});
}

class _BulkRx {
  final int xfer;
  final MspFileOffer offer;
  int offset;
  int sinceAck = 0;
  int badSince = 0;
  _BulkRx({required this.xfer, required this.offer, required this.offset});
}
