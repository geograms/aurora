/*
 * Minimal MessagePack codec for LXMF payloads, compatible with the umsgpack
 * encoding RNS/LXMF use. Supports nil, bool, int (all widths), float64, str
 * (UTF-8), bin (bytes), array and map. Maps decode into insertion-ordered maps so
 * a decode/encode round-trip is byte-stable (needed when re-packing a payload to
 * verify a stamped message).
 *
 * Note: LXMF strings (title/content) are transmitted as bin (bytes), not str.
 */
import 'dart:convert';
import 'dart:typed_data';

Uint8List msgpackEncode(Object? o) {
  final b = BytesBuilder();
  _enc(b, o);
  return b.toBytes();
}

Object? msgpackDecode(Uint8List data) => _MsgpackReader(data).read();

void _enc(BytesBuilder b, Object? o) {
  if (o == null) {
    b.addByte(0xc0);
  } else if (o is bool) {
    b.addByte(o ? 0xc3 : 0xc2);
  } else if (o is int) {
    _encInt(b, o);
  } else if (o is double) {
    b.addByte(0xcb);
    final d = ByteData(8)..setFloat64(0, o, Endian.big);
    b.add(d.buffer.asUint8List());
  } else if (o is String) {
    _encStr(b, o);
  } else if (o is Uint8List) {
    _encBin(b, o);
  } else if (o is List) {
    _encArray(b, o);
  } else if (o is Map) {
    _encMap(b, o);
  } else {
    throw ArgumentError('msgpack: unsupported type ${o.runtimeType}');
  }
}

void _encInt(BytesBuilder b, int v) {
  if (v >= 0) {
    if (v <= 0x7f) {
      b.addByte(v);
    } else if (v <= 0xff) {
      b..addByte(0xcc)..addByte(v);
    } else if (v <= 0xffff) {
      b.addByte(0xcd);
      b.add(_be(2, v));
    } else if (v <= 0xffffffff) {
      b.addByte(0xce);
      b.add(_be(4, v));
    } else {
      b.addByte(0xcf);
      final d = ByteData(8)..setUint64(0, v, Endian.big);
      b.add(d.buffer.asUint8List());
    }
  } else {
    if (v >= -32) {
      b.addByte(0xe0 | (v & 0x1f));
    } else if (v >= -128) {
      b..addByte(0xd0)..addByte(v & 0xff);
    } else if (v >= -32768) {
      b.addByte(0xd1);
      final d = ByteData(2)..setInt16(0, v, Endian.big);
      b.add(d.buffer.asUint8List());
    } else if (v >= -2147483648) {
      b.addByte(0xd2);
      final d = ByteData(4)..setInt32(0, v, Endian.big);
      b.add(d.buffer.asUint8List());
    } else {
      b.addByte(0xd3);
      final d = ByteData(8)..setInt64(0, v, Endian.big);
      b.add(d.buffer.asUint8List());
    }
  }
}

void _encStr(BytesBuilder b, String s) {
  final bytes = utf8.encode(s);
  final n = bytes.length;
  if (n < 32) {
    b.addByte(0xa0 | n);
  } else if (n <= 0xff) {
    b..addByte(0xd9)..addByte(n);
  } else if (n <= 0xffff) {
    b.addByte(0xda);
    b.add(_be(2, n));
  } else {
    b.addByte(0xdb);
    b.add(_be(4, n));
  }
  b.add(bytes);
}

void _encBin(BytesBuilder b, Uint8List bytes) {
  final n = bytes.length;
  if (n <= 0xff) {
    b..addByte(0xc4)..addByte(n);
  } else if (n <= 0xffff) {
    b.addByte(0xc5);
    b.add(_be(2, n));
  } else {
    b.addByte(0xc6);
    b.add(_be(4, n));
  }
  b.add(bytes);
}

void _encArray(BytesBuilder b, List<Object?> a) {
  final n = a.length;
  if (n < 16) {
    b.addByte(0x90 | n);
  } else if (n <= 0xffff) {
    b.addByte(0xdc);
    b.add(_be(2, n));
  } else {
    b.addByte(0xdd);
    b.add(_be(4, n));
  }
  for (final e in a) {
    _enc(b, e);
  }
}

void _encMap(BytesBuilder b, Map<Object?, Object?> m) {
  final n = m.length;
  if (n < 16) {
    b.addByte(0x80 | n);
  } else if (n <= 0xffff) {
    b.addByte(0xde);
    b.add(_be(2, n));
  } else {
    b.addByte(0xdf);
    b.add(_be(4, n));
  }
  m.forEach((k, v) {
    _enc(b, k);
    _enc(b, v);
  });
}

Uint8List _be(int n, int v) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[n - 1 - i] = (v >> (8 * i)) & 0xff;
  }
  return out;
}

class _MsgpackReader {
  final Uint8List _b;
  int _i = 0;
  _MsgpackReader(this._b);

  Object? read() {
    final c = _b[_i++];
    if (c <= 0x7f) return c; // positive fixint
    if (c >= 0xe0) return c - 256; // negative fixint
    if ((c & 0xe0) == 0xa0) return _str(c & 0x1f); // fixstr
    if ((c & 0xf0) == 0x90) return _array(c & 0x0f); // fixarray
    if ((c & 0xf0) == 0x80) return _map(c & 0x0f); // fixmap
    switch (c) {
      case 0xc0:
        return null;
      case 0xc2:
        return false;
      case 0xc3:
        return true;
      case 0xc4:
        return _bin(_u(1));
      case 0xc5:
        return _bin(_u(2));
      case 0xc6:
        return _bin(_u(4));
      case 0xca:
        final v = ByteData.sublistView(_b, _i, _i + 4).getFloat32(0, Endian.big);
        _i += 4;
        return v;
      case 0xcb:
        final v = ByteData.sublistView(_b, _i, _i + 8).getFloat64(0, Endian.big);
        _i += 8;
        return v;
      case 0xcc:
        return _u(1);
      case 0xcd:
        return _u(2);
      case 0xce:
        return _u(4);
      case 0xcf:
        final v = ByteData.sublistView(_b, _i, _i + 8).getUint64(0, Endian.big);
        _i += 8;
        return v;
      case 0xd0:
        return ByteData.sublistView(_b, _i, ++_i).getInt8(0);
      case 0xd1:
        final v = ByteData.sublistView(_b, _i, _i + 2).getInt16(0, Endian.big);
        _i += 2;
        return v;
      case 0xd2:
        final v = ByteData.sublistView(_b, _i, _i + 4).getInt32(0, Endian.big);
        _i += 4;
        return v;
      case 0xd3:
        final v = ByteData.sublistView(_b, _i, _i + 8).getInt64(0, Endian.big);
        _i += 8;
        return v;
      case 0xd9:
        return _str(_u(1));
      case 0xda:
        return _str(_u(2));
      case 0xdb:
        return _str(_u(4));
      case 0xdc:
        return _array(_u(2));
      case 0xdd:
        return _array(_u(4));
      case 0xde:
        return _map(_u(2));
      case 0xdf:
        return _map(_u(4));
      default:
        throw FormatException('msgpack: bad byte 0x${c.toRadixString(16)}');
    }
  }

  int _u(int n) {
    var v = 0;
    for (var k = 0; k < n; k++) {
      v = (v << 8) | _b[_i++];
    }
    return v;
  }

  String _str(int n) {
    final s = utf8.decode(_b.sublist(_i, _i + n));
    _i += n;
    return s;
  }

  Uint8List _bin(int n) {
    final out = Uint8List.fromList(_b.sublist(_i, _i + n));
    _i += n;
    return out;
  }

  List<Object?> _array(int n) =>
      List<Object?>.generate(n, (_) => read());

  Map<Object?, Object?> _map(int n) {
    final m = <Object?, Object?>{};
    for (var k = 0; k < n; k++) {
      final key = read();
      m[key] = read();
    }
    return m;
  }
}
