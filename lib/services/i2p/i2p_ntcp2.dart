/*
 * NTCP2 transport, pure Dart.
 *
 * Implements the NTCP2 Noise pattern "Noise_XKaesobfse+hs2+hs3_25519_
 * ChaChaPoly_SHA256": SessionRequest (msg1), SessionCreated (msg2),
 * SessionConfirmed (msg3), then the SipHash-length-obfuscated, ChaCha20-
 * Poly1305 data phase carrying I2NP messages.
 *
 * We are always the initiator (Alice). The responder (Bob) is identified by
 * its RouterInfo: rs = Bob's NTCP2 static key 's', and the X/Y ephemeral keys
 * are obfuscated with AES-256-CBC keyed by Bob's router identity hash (RH_B)
 * with IV = Bob's published 'i'.
 *
 * Crypto-state notes that are easy to get wrong and must match the spec:
 *  - MixHash uses the RAW (cleartext) ephemeral keys, never the AES wire bytes.
 *  - The unencrypted padding of msg1/msg2 IS mixed into h (before the next
 *    message's ephemeral) so it is authenticated.
 *  - AEAD nonce = 4 zero bytes + 8-byte little-endian counter, per direction.
 *  - msg3 part 1 reuses k from msg2 with counter=1.
 */
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'i2p_crypto.dart';
import 'i2p_i2np.dart';
import 'i2p_router.dart';
import 'i2p_structures.dart';

const _protocolName =
    'Noise_XKaesobfse+hs2+hs3_25519_ChaChaPoly_SHA256';

class _SockReader {
  final Socket _sock;
  final _buf = BytesBuilder();
  final _waiters = <(int, Completer<Uint8List>)>[];
  Object? _error;
  bool _done = false;

  _SockReader(this._sock) {
    _sock.listen((d) {
      _buf.add(d);
      _drain();
    }, onError: (e) {
      _error = e;
      _failAll();
    }, onDone: () {
      _done = true;
      _failAll();
    });
  }

  void _drain() {
    while (_waiters.isNotEmpty && _buf.length >= _waiters.first.$1) {
      final (n, c) = _waiters.removeAt(0);
      final all = _buf.takeBytes();
      c.complete(Uint8List.fromList(all.sublist(0, n)));
      _buf.add(all.sublist(n));
    }
  }

  void _failAll() {
    for (final (_, c) in _waiters) {
      if (!c.isCompleted) {
        c.completeError(_error ?? const SocketException('closed'));
      }
    }
    _waiters.clear();
  }

  Future<Uint8List> readExactly(int n) {
    if (_buf.length >= n && _waiters.isEmpty) {
      final all = _buf.takeBytes();
      final out = Uint8List.fromList(all.sublist(0, n));
      _buf.add(all.sublist(n));
      return Future.value(out);
    }
    if (_done || _error != null) {
      return Future.error(_error ?? const SocketException('closed'));
    }
    final c = Completer<Uint8List>();
    _waiters.add((n, c));
    return c.future;
  }
}

Uint8List _concat(List<List<int>> parts) {
  final b = BytesBuilder();
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

class Ntcp2Session {
  final RouterInfo bob;
  final OurRouter us;
  final void Function(String)? log;
  final String? hostOverride;
  final int? portOverride;
  final Uint8List? ivOverride;
  final int netId;

  late Socket _socket;
  late _SockReader _reader;

  // Noise state
  late Uint8List _ck;
  late Uint8List _h;

  // data phase
  late Uint8List _kAB; // our send key
  late Uint8List _kBA; // our recv key
  late Uint8List _sipKeyAB; // 16-byte siphash key (send)
  late Uint8List _sipKeyBA; // 16-byte siphash key (recv)
  late Uint8List _sipIvAB; // 8-byte siphash IV (send)
  late Uint8List _sipIvBA; // 8-byte siphash IV (recv)
  int _sendCounter = 0;
  int _recvCounter = 0;
  // Serializes outbound frames: each frame mutates _sendCounter (the ChaCha
  // nonce) and the SipHash length-mask chain and must be written to the socket
  // in that exact order. Concurrent sendI2np calls (e.g. parallel swarm piece
  // requests) would otherwise interleave their awaits and corrupt the stream.
  Future<void> _sendLock = Future<void>.value();

  Ntcp2Session(this.bob, this.us,
      {this.log,
      this.hostOverride,
      this.portOverride,
      this.ivOverride,
      this.netId = 2});

  // ---- Noise helpers ----
  void _mixHash(List<int> data) => _h = I2pCrypto.sha256(_concat([_h, data]));

  Uint8List _mixKey(Uint8List ikm) {
    final outs = I2pCrypto.noiseHkdf(_ck, ikm, 2);
    _ck = outs[0];
    return outs[1]; // k
  }

  static Uint8List _nonce(int counter) {
    final n = Uint8List(12);
    n.setRange(4, 12, I2pCrypto.u64LE(counter));
    return n;
  }

  Future<void> handshake() async {
    final addr = bob.ntcp2!;
    final rs = addr.staticKey!; // Bob's static X25519
    final rhB = bob.identityHash; // AES key
    final bobIv = ivOverride ?? addr.iv!; // AES IV for X

    final host = hostOverride ?? addr.host!;
    final port = portOverride ?? addr.port!;
    log?.call('ntcp2: connecting $host:$port');
    _socket = await Socket.connect(host, port,
        timeout: const Duration(seconds: 15));
    _socket.setOption(SocketOption.tcpNoDelay, true);
    _reader = _SockReader(_socket);

    // Init: h = SHA256(name); ck = h; h = SHA256(h||prologue=empty);
    //       h = SHA256(h || rs)
    _h = I2pCrypto.sha256(Uint8List.fromList(_protocolName.codeUnits));
    _ck = _h;
    _h = I2pCrypto.sha256(_h);
    _mixHash(rs);

    // ===== Message 1: SessionRequest (Alice -> Bob) =====
    final e = await I2pCrypto.x25519Generate();
    _mixHash(e.pub); // raw ephemeral
    final k1 = _mixKey(await I2pCrypto.x25519Shared(e.priv, rs)); // es

    // Build our RouterInfo block now to know m3p2Len.
    final riBlock = _buildRouterInfoBlock();
    final m3p2Len = riBlock.length + 16; // + AEAD tag

    final rnd = Random.secure();
    final padLen1 = 16 + rnd.nextInt(16);
    final opts1 = Uint8List(16);
    opts1[0] = netId; // network id
    opts1[1] = 2; // version
    opts1[2] = (padLen1 >> 8) & 0xff;
    opts1[3] = padLen1 & 0xff;
    opts1[4] = (m3p2Len >> 8) & 0xff;
    opts1[5] = m3p2Len & 0xff;
    final tsA = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    opts1[8] = (tsA >> 24) & 0xff;
    opts1[9] = (tsA >> 16) & 0xff;
    opts1[10] = (tsA >> 8) & 0xff;
    opts1[11] = tsA & 0xff;

    final ct1 = await I2pCrypto.chachaEncrypt(k1, _nonce(0), opts1, _h);
    _mixHash(ct1);

    final pad1 = Uint8List(padLen1);
    for (var i = 0; i < padLen1; i++) {
      pad1[i] = rnd.nextInt(256);
    }

    final xObf = I2pCrypto.aesCbc(rhB, bobIv, e.pub, true); // 32 bytes
    _socket.add(_concat([xObf, ct1, pad1]));
    await _socket.flush();
    log?.call('ntcp2: sent SessionRequest (X+opts+${padLen1}b pad, m3p2Len=$m3p2Len)');

    // After msg1, mix our padding before processing msg2.
    _mixHash(pad1);

    // ===== Message 2: SessionCreated (Bob -> Alice) =====
    final head2 = await _reader.readExactly(64); // Y_obf(32) + opts_aead(32)
    final yObf = head2.sublist(0, 32);
    final ct2 = head2.sublist(32, 64);
    // Decrypt Y: AES-CBC continuation, IV = last 16 bytes of our sent X cipher.
    final contIv = Uint8List.fromList(xObf.sublist(16, 32));
    final y = I2pCrypto.aesCbc(rhB, contIv, yObf, false);
    _mixHash(y); // raw ephemeral

    final k2 = _mixKey(await I2pCrypto.x25519Shared(e.priv, y)); // ee
    final opts2 = await I2pCrypto.chachaDecrypt(k2, _nonce(0), ct2, _h);
    _mixHash(ct2);
    final padLen2 = (opts2[2] << 8) | opts2[3];
    log?.call('ntcp2: got SessionCreated (padLen=$padLen2)');
    if (padLen2 > 0) {
      final pad2 = await _reader.readExactly(padLen2);
      _mixHash(pad2);
    }

    // ===== Message 3: SessionConfirmed (Alice -> Bob) =====
    // Part 1: encrypt our static key with k from msg2, counter=1.
    final ct3p1 = await I2pCrypto.chachaEncrypt(k2, _nonce(1), us.staticPub, _h);
    _mixHash(ct3p1);
    // Part 2: MixKey(se) then encrypt our RouterInfo block.
    final k3 = _mixKey(await I2pCrypto.x25519Shared(us.staticPriv, y)); // se
    final ct3p2 = await I2pCrypto.chachaEncrypt(k3, _nonce(0), riBlock, _h);
    _mixHash(ct3p2);

    _socket.add(_concat([ct3p1, ct3p2]));
    await _socket.flush();
    log?.call('ntcp2: sent SessionConfirmed (RI ${us.routerInfo.length}b)');

    _deriveDataKeys();
    log?.call('ntcp2: handshake complete, data phase ready');
  }

  /// RouterInfo block for msg3 part2: [type=2][size BE][flag=0][RI].
  Uint8List _buildRouterInfoBlock() {
    final ri = us.routerInfo;
    final size = 1 + ri.length; // flag + RI
    final b = BytesBuilder();
    b.addByte(2); // block type RouterInfo
    b.addByte((size >> 8) & 0xff);
    b.addByte(size & 0xff);
    b.addByte(0); // flag: local store
    b.add(ri);
    return b.toBytes();
  }

  void _deriveDataKeys() {
    final tempKey = I2pCrypto.hmacSha256(_ck, Uint8List(0));
    _kAB = I2pCrypto.hmacSha256(tempKey, [0x01]);
    _kBA = I2pCrypto.hmacSha256(tempKey, _concat([_kAB, [0x02]]));

    // ask_master = HKDF(ck, info="ask")  -> HMAC(tempKey, "ask"||0x01)
    final askMaster =
        I2pCrypto.hmacSha256(tempKey, _concat(['ask'.codeUnits, [0x01]]));
    // sip_master = HKDF(ask_master, ikm=h||"siphash") -> the T(1) chunk
    final tempKey2 =
        I2pCrypto.hmacSha256(askMaster, _concat([_h, 'siphash'.codeUnits]));
    final sipMaster = I2pCrypto.hmacSha256(tempKey2, [0x01]);
    // sipkeys = HKDF(sip_master, info="") which re-expands: PRK=HMAC(sip_master,
    // empty), then T(1)=sipkeys_ab, T(2)=sipkeys_ba. (This intermediate PRK is
    // the layer easy to miss — without it the SipHash chain diverges.)
    final sipPrk = I2pCrypto.hmacSha256(sipMaster, Uint8List(0));
    final sipAB = I2pCrypto.hmacSha256(sipPrk, [0x01]);
    final sipBA = I2pCrypto.hmacSha256(sipPrk, _concat([sipAB, [0x02]]));

    _sipKeyAB = Uint8List.fromList(sipAB.sublist(0, 16));
    _sipIvAB = Uint8List.fromList(sipAB.sublist(16, 24));
    _sipKeyBA = Uint8List.fromList(sipBA.sublist(0, 16));
    _sipIvBA = Uint8List.fromList(sipBA.sublist(16, 24));
  }

  // ---- data phase framing ----
  Uint8List _nextMask(bool send) {
    final key = send ? _sipKeyAB : _sipKeyBA;
    final iv = send ? _sipIvAB : _sipIvBA;
    final hv = I2pCrypto.sipHash24(key, iv);
    final next = I2pCrypto.u64LE(hv);
    if (send) {
      _sipIvAB = next;
    } else {
      _sipIvBA = next;
    }
    return next; // first two bytes are the mask
  }

  /// Send one data-phase frame containing a single I2NP message body. Serialized
  /// per session so concurrent callers can't interleave frame state.
  Future<void> sendI2np(int msgType, Uint8List body) {
    final done = _sendLock.then((_) => _rawSendI2np(msgType, body));
    _sendLock = done.catchError((_) {}); // keep the chain alive past failures
    return done;
  }

  Future<void> _rawSendI2np(int msgType, Uint8List body) async {
    final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120;
    final msgId = randomMsgId();
    final inner = BytesBuilder();
    inner.addByte(3); // block type: I2NP
    final blockSize = 9 + body.length;
    inner.addByte((blockSize >> 8) & 0xff);
    inner.addByte(blockSize & 0xff);
    inner.addByte(msgType);
    inner.add([(msgId >> 24) & 0xff, (msgId >> 16) & 0xff, (msgId >> 8) & 0xff, msgId & 0xff]);
    inner.add([(exp >> 24) & 0xff, (exp >> 16) & 0xff, (exp >> 8) & 0xff, exp & 0xff]);
    inner.add(body);
    await _sendFramePlain(inner.toBytes());
  }

  /// Send a padding-only data-phase frame (block type 254). Routers accept and
  /// ignore it; we use it as a NAT/connection keepalive so a gateway can keep
  /// pushing inbound tunnel data over our outbound-initiated connection (a
  /// firewalled node has no other way to receive). Serialized via [_sendLock]
  /// like real frames (it advances the ChaCha nonce + SipHash length mask).
  Future<void> sendKeepAlive() {
    final done = _sendLock.then((_) => _rawSendPadding());
    _sendLock = done.catchError((_) {});
    return done;
  }

  Future<void> _rawSendPadding() async {
    const padLen = 12;
    final inner = BytesBuilder();
    inner.addByte(254); // block type: Padding
    inner.addByte((padLen >> 8) & 0xff);
    inner.addByte(padLen & 0xff);
    inner.add(Uint8List(padLen));
    await _sendFramePlain(inner.toBytes());
  }

  /// AEAD-encrypt one data-phase frame and write it with the obfuscated length.
  /// Length is big-endian on the wire; the mask is the SipHash IV's first two
  /// bytes read little-endian (mask16 = b0 | b1<<8), so the high length byte XORs
  /// with b1 and the low byte with b0 (matches i2pd le16toh(IV)).
  Future<void> _sendFramePlain(Uint8List plain) async {
    final ct =
        await I2pCrypto.chachaEncrypt(_kAB, _nonce(_sendCounter++), plain, []);
    final len = ct.length;
    final mask = _nextMask(true);
    final framed = BytesBuilder();
    framed.addByte(((len >> 8) & 0xff) ^ mask[1]);
    framed.addByte((len & 0xff) ^ mask[0]);
    framed.add(ct);
    _socket.add(framed.toBytes());
    await _socket.flush();
  }

  /// Read one data-phase frame and return its decrypted block bytes.
  Future<Uint8List> _readFrame() async {
    final lenObf = await _reader.readExactly(2);
    final mask = _nextMask(false);
    final len = ((lenObf[0] ^ mask[1]) << 8) | (lenObf[1] ^ mask[0]);
    final ct = await _reader.readExactly(len);
    return I2pCrypto.chachaDecrypt(_kBA, _nonce(_recvCounter++), ct, []);
  }

  /// Read frames until an I2NP reply we recognise arrives, or timeout.
  /// Logs every block so we can see exactly what the peer sends back.
  Future<I2npReply?> awaitI2npReply(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      Uint8List frame;
      try {
        frame = await _readFrame().timeout(remaining);
      } on TimeoutException {
        return null;
      } catch (e) {
        log?.call('ntcp2: frame read error: $e');
        return null;
      }
      // parse blocks
      var p = 0;
      while (p + 3 <= frame.length) {
        final type = frame[p];
        final size = (frame[p + 1] << 8) | frame[p + 2];
        p += 3;
        if (p + size > frame.length) {
          log?.call('ntcp2: <- truncated block type=$type size=$size (frame=${frame.length})');
          break;
        }
        final data = frame.sublist(p, p + size);
        p += size;
        switch (type) {
          case 0:
            log?.call('ntcp2: <- DateTime block');
            break;
          case 1:
            log?.call('ntcp2: <- Options block ($size b)');
            break;
          case 2:
            log?.call('ntcp2: <- RouterInfo block ($size b)');
            break;
          case 3:
            final msgType = data[0];
            final body = data.sublist(9);
            final r = parseReply(msgType, body);
            log?.call('ntcp2: <- I2NP block type=$msgType ${r?.summary ?? "($size b)"}');
            if (msgType == I2npType.databaseStore ||
                msgType == I2npType.databaseSearchReply) {
              return r;
            }
            break;
          case 4:
            final rsn = data.length > 8 ? data[8] : -1;
            log?.call('ntcp2: <- Termination block rsn=$rsn ($size b)');
            return null;
          case 254:
            log?.call('ntcp2: <- Padding block ($size b)');
            break;
          default:
            log?.call('ntcp2: <- block type=$type ($size b)');
        }
      }
    }
    return null;
  }

  /// Await the next I2NP message of any type, returning (i2npType, body), or
  /// null on timeout. Non-I2NP blocks are logged and skipped. Returns as soon
  /// as one I2NP message arrives.
  Future<(int, Uint8List)?> nextI2np(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      Uint8List frame;
      try {
        frame = await _readFrame().timeout(remaining);
      } on TimeoutException {
        return null;
      } catch (e) {
        log?.call('ntcp2: frame read error: $e');
        return null;
      }
      var p = 0;
      while (p + 3 <= frame.length) {
        final type = frame[p];
        final size = (frame[p + 1] << 8) | frame[p + 2];
        p += 3;
        if (p + size > frame.length) break;
        final data = frame.sublist(p, p + size);
        p += size;
        if (type == 3) {
          return (data[0], data.sublist(9));
        } else if (type == 4) {
          log?.call('ntcp2: <- Termination rsn=${data.length > 8 ? data[8] : -1}');
          return null;
        } else {
          log?.call('ntcp2: <- block type=$type ($size b)');
        }
      }
    }
    return null;
  }

  /// Read data-phase frames for [timeout], invoking [onI2np] for every I2NP
  /// block (i2npType, body) and logging other block types. Returns when the
  /// timeout elapses or the peer closes.
  Future<void> pumpI2np(
      Duration timeout, void Function(int i2npType, Uint8List body) onI2np) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      Uint8List frame;
      try {
        frame = await _readFrame().timeout(remaining);
      } on TimeoutException {
        return;
      } catch (e) {
        log?.call('ntcp2: frame read error: $e');
        return;
      }
      var p = 0;
      while (p + 3 <= frame.length) {
        final type = frame[p];
        final size = (frame[p + 1] << 8) | frame[p + 2];
        p += 3;
        if (p + size > frame.length) break;
        final data = frame.sublist(p, p + size);
        p += size;
        if (type == 3) {
          onI2np(data[0], data.sublist(9));
        } else if (type == 4) {
          final rsn = data.length > 8 ? data[8] : -1;
          log?.call('ntcp2: <- Termination rsn=$rsn');
          return;
        } else {
          log?.call('ntcp2: <- block type=$type ($size b)');
        }
      }
    }
  }

  void close() {
    try {
      _socket.destroy();
    } catch (_) {}
  }
}
