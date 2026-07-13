/*
 * NostrSigner — the seam between "this app can sign as you" and "this app holds
 * your secret key". Until now those were the same sentence.
 *
 * A user with a real NOSTR identity keeps it in Amber or a bunker precisely so
 * that applications never see it, and Aurora currently demands the opposite: the
 * only way in is to paste an nsec, which then sits in clear text in
 * profiles.json. This interface is what lets the key live somewhere else.
 *
 * Everything here is ASYNC, because a signer is: an Amber signature is an Android
 * intent the user has to approve, and a bunker signature is a websocket round
 * trip to another machine. Code that signs must be able to wait, or to queue (see
 * signing_outbox.dart). [LocalSigner] is the exception in practice — it answers
 * immediately — but it implements the same async contract so that no caller has
 * to care which kind it is holding.
 *
 * What a signer CANNOT do, and why the app still holds a key:
 *
 *   A signer signs NOSTR events and does NIP-04. It cannot produce the 48-byte
 *   truncated Schnorr the chat wapp puts on every frame (AprxSign.sign), nor the
 *   custom ECDH+AES envelope Circles uses, nor hand raw scalar material to the
 *   coin wallet. Those keep using a locally-generated DEVICE key, which the
 *   signer cross-certifies once. See the plan (docs/plan-nostr-signer.md) and
 *   IwiProfile.devicePriv.
 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart' show NostrEvent, NostrCrypto, AprxSign;

/// Why a signature did not happen. Callers must distinguish these: a REFUSAL is
/// the user saying no and must be shown; UNAVAILABLE is "not now" and belongs in
/// the outbox to be retried.
enum SignerFailure {
  /// The user (or the signer app) declined.
  refused,

  /// The signer cannot be reached right now — Amber needs a foreground Activity
  /// and we are in a background service, or the bunker's relay is down.
  unavailable,

  /// The signer answered, but with something we could not use.
  malformed,
}

class SignerException implements Exception {
  final SignerFailure reason;
  final String message;
  const SignerException(this.reason, this.message);

  @override
  String toString() => 'SignerException(${reason.name}): $message';
}

/// How this profile signs. Persisted on the profile, because it decides what the
/// app is allowed to assume about latency, availability and whether an nsec even
/// exists on disk.
enum SignerKind {
  /// The key is ours: in profiles.json, as it has always been.
  local,

  /// Amber (or another NIP-55 app) on Android, over an intent.
  nip55,

  /// A remote bunker over a websocket (NIP-46). The only signer that works with
  /// no Activity — i.e. the only one that can sign while the app is headless.
  nip46,
}

abstract class NostrSigner {
  /// Our public key, hex (x-only, 64 chars). Cheap and cached — this is asked on
  /// nearly every code path and must never trigger a user prompt.
  Future<String> publicKey();

  /// Fill in [unsigned]'s id and sig. The event comes back signed; on failure a
  /// [SignerException] is thrown rather than a half-signed event returned.
  Future<NostrEvent> signEvent(NostrEvent unsigned);

  Future<String> nip04Encrypt(String peerPubHex, String plaintext);
  Future<String> nip04Decrypt(String peerPubHex, String ciphertext);

  /// True when the key is on this device. Local signers can answer synchronously
  /// and never fail, which is what the legacy synchronous HAL relies on.
  bool get isLocal;

  /// True when this signer can be used with no Activity and no user present —
  /// i.e. from a background wapp tick, at boot, from the foreground service.
  ///
  /// Local: yes. Bunker: yes (it is a socket). Amber: NO for the intent API — it
  /// needs a foreground Activity — so background signing must go to the outbox.
  bool get worksHeadless;

  /// A human name for the UI ("this device", "Amber", "bunker.example.com").
  String get label;

  /// Release sockets/listeners. Safe to call twice.
  Future<void> dispose() async {}
}

/// The key is ours: today's behaviour, behind the new interface.
///
/// This exists so that the ~30 call sites that used to reach for
/// `activeProfile.nsec` can be rewritten ONCE against the interface, without the
/// existing users — every one of whom is a local-key account — noticing anything
/// at all. Its output must stay byte-identical to `NostrEvent.sign(privHex)`,
/// and there is a test that says so.
class LocalSigner implements NostrSigner {
  LocalSigner(this.privHex)
      : assert(privHex.length == 64, 'expected 32-byte hex private key');

  final String privHex;

  String? _pubCache;

  factory LocalSigner.fromNsec(String nsec) =>
      LocalSigner(NostrCrypto.decodeNsec(nsec));

  @override
  Future<String> publicKey() async =>
      _pubCache ??= NostrCrypto.derivePublicKey(privHex);

  @override
  Future<NostrEvent> signEvent(NostrEvent unsigned) async {
    // NostrEvent.sign computes the id and the Schnorr signature in place. Same
    // call the whole app made before this interface existed.
    unsigned.sign(privHex);
    return unsigned;
  }

  @override
  Future<String> nip04Encrypt(String peerPubHex, String plaintext) async {
    final out = AprxSign.nip04Encrypt(
      scalarFromHex(privHex),
      bytesFromHex(peerPubHex),
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    if (out == null) {
      throw const SignerException(
          SignerFailure.malformed, 'nip04 encrypt failed');
    }
    return out;
  }

  @override
  Future<String> nip04Decrypt(String peerPubHex, String ciphertext) async {
    final out = AprxSign.nip04Decrypt(
      scalarFromHex(privHex),
      bytesFromHex(peerPubHex),
      ciphertext,
    );
    if (out == null) {
      throw const SignerException(
          SignerFailure.malformed, 'nip04 decrypt failed');
    }
    return utf8.decode(out, allowMalformed: true);
  }

  @override
  bool get isLocal => true;

  @override
  bool get worksHeadless => true;

  @override
  String get label => 'this device';

  @override
  Future<void> dispose() async {}
}

// ── Hex helpers ─────────────────────────────────────────────────────────────
//
// AprxSign takes the private key as a BigInt scalar and the peer key as x-only
// bytes. Both conversions are duplicated in rns_service (_scalarFromHex,
// _hexToBytes) and wapp_engine; they live here too so a signer implementation is
// self-contained rather than reaching into a service.

Uint8List bytesFromHex(String hex) {
  final clean = hex.length.isOdd ? '0$hex' : hex;
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

BigInt scalarFromHex(String hex) {
  var d = BigInt.zero;
  for (final b in bytesFromHex(hex)) {
    d = (d << 8) | BigInt.from(b);
  }
  return d;
}
