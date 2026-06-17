/*
 * HDLC framing for the RNS TCP/serial interfaces (RNS 1.3.5 — TCPInterface.py).
 *
 *   FLAG=0x7E delimits frames; ESC=0x7D with ESC_MASK=0x20 byte-stuffs any FLAG
 *   or ESC inside the payload. On the wire each packet is FLAG + escape(p) + FLAG.
 *
 * [RnsHdlcDeframer] is a stateful byte-stream consumer: a single RNS packet can
 * arrive split across several TCP reads, and several packets can arrive in one
 * read, so framing must be tracked incrementally.
 */
import 'dart:typed_data';

const int kHdlcFlag = 0x7E;
const int kHdlcEsc = 0x7D;
const int kHdlcEscMask = 0x20;

/// Wrap a raw packet for the wire: FLAG + escaped(payload) + FLAG.
Uint8List hdlcFrame(Uint8List payload) {
  final out = BytesBuilder();
  out.addByte(kHdlcFlag);
  for (final b in payload) {
    if (b == kHdlcEsc || b == kHdlcFlag) {
      out.addByte(kHdlcEsc);
      out.addByte(b ^ kHdlcEscMask);
    } else {
      out.addByte(b);
    }
  }
  out.addByte(kHdlcFlag);
  return out.toBytes();
}

/// Incremental HDLC deframer. Feed it bytes; it returns any completed frames.
class RnsHdlcDeframer {
  final int maxFrameBytes;
  bool _inFrame = false;
  bool _escaping = false;
  final BytesBuilder _buf = BytesBuilder();

  RnsHdlcDeframer({this.maxFrameBytes = 262144});

  /// Consume [chunk]; return zero or more complete, de-escaped frames.
  List<Uint8List> feed(List<int> chunk) {
    final frames = <Uint8List>[];
    for (final byte in chunk) {
      if (byte == kHdlcFlag) {
        if (_inFrame && _buf.length > 0) {
          frames.add(_buf.toBytes());
        }
        _buf.clear();
        _inFrame = true;
        _escaping = false;
      } else if (_inFrame) {
        if (_buf.length >= maxFrameBytes) {
          // Overlong frame: abandon it and resync on the next FLAG.
          _inFrame = false;
          _escaping = false;
          _buf.clear();
          continue;
        }
        if (_escaping) {
          _buf.addByte(byte ^ kHdlcEscMask);
          _escaping = false;
        } else if (byte == kHdlcEsc) {
          _escaping = true;
        } else {
          _buf.addByte(byte);
        }
      }
    }
    return frames;
  }
}
