/// Which kind of interface an announce arrived on, from the transport's own
/// `via` label.
///
/// ONE rule, two consumers: the Reticulum graph colours a node by it, and the
/// Chat wapp decides "is this device in the room with me" by it. They used to
/// answer that question through different code in different layers, which is
/// how a device ended up drawn on the graph and missing from the nearby list.
/// Anything that needs to know what a `via` means asks here.
///
/// Kinds: `ble`, `lan`, `lora`, `radio`, `internet`, or `''` when the label is
/// empty and the caller has no relayer to fall back on.
library;

/// The interface labels the transport writes: `lan`, `ble`/`ble5`,
/// `wfd:<ip>:<port>`, `tcp:<host>:<port>`, `tcps#<n>:<ip>:<port>`, `udp`, and
/// (forward-looking) `lora*`, `radio`/`aprs`/`kiss`.
String rnsIfaceKind(String via) {
  final v = via.trim().toLowerCase();
  if (v.isEmpty) return '';
  if (v.startsWith('ble')) return 'ble';
  if (v.startsWith('lan') || v.startsWith('wfd') || v.startsWith('wifi')) {
    return 'lan';
  }
  if (v.startsWith('lora')) return 'lora';
  if (v.startsWith('radio') || v.startsWith('aprs') || v.startsWith('kiss') ||
      v.startsWith('vhf') || v.startsWith('uhf') || v.startsWith('hf') ||
      v.startsWith('cb') || v.startsWith('pmr')) {
    return 'radio';
  }
  // A TCP link is usually a bootstrap hub out on the internet — but two devices
  // on one LAN, where one runs the TCP server, see each other as
  // `tcps#3:192.168.1.42:51234` / `tcp:192.168.1.7:4965`. That is as local as
  // it gets, and calling it "internet" would hide a neighbour standing next to
  // you (and paint it the wrong colour on the graph).
  if (v.startsWith('tcp') || v.startsWith('udp')) {
    return _isPrivateHost(v) ? 'lan' : 'internet';
  }
  return 'internet';
}

/// True when [kind] is a way of reaching someone WITHOUT the internet.
/// The definition of "nearby": not who is on the mesh, but who is in the room.
bool rnsIfaceIsLocal(String kind) =>
    kind == 'lan' || kind == 'ble' || kind == 'lora' || kind == 'radio';

/// True when a `tcp…`/`udp…` label carries an RFC1918 / link-local / loopback
/// address. Parsed out of the label rather than the socket, because the label
/// is all the observed registry keeps.
bool _isPrivateHost(String via) {
  // `tcp:host:port`, `tcps#7:host:port`, `udp:host:port` → take the host.
  final colon = via.indexOf(':');
  if (colon < 0) return false;
  var rest = via.substring(colon + 1);
  // IPv6 in brackets: `tcp:[fe80::1]:4242`.
  if (rest.startsWith('[')) {
    final end = rest.indexOf(']');
    if (end > 1) rest = rest.substring(1, end);
  } else {
    final last = rest.lastIndexOf(':');
    if (last > 0) rest = rest.substring(0, last);
  }
  final h = rest.trim();
  if (h.isEmpty) return false;
  if (h == 'localhost') return true;
  if (h.startsWith('10.') ||
      h.startsWith('192.168.') ||
      h.startsWith('127.') ||
      h.startsWith('169.254.')) {
    return true;
  }
  if (h.startsWith('172.')) {
    final second = int.tryParse(h.split('.').elementAtOrNull(1) ?? '');
    if (second != null && second >= 16 && second <= 31) return true;
  }
  // IPv6 link-local (fe80::/10) and unique-local (fc00::/7).
  if (h.startsWith('fe80:') || h.startsWith('fc') || h.startsWith('fd')) {
    return true;
  }
  return false;
}
