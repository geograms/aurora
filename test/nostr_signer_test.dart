/*
 * The regression that matters most.
 *
 * Every existing user is a local-key account. Introducing a signer interface is
 * only safe if routing their signatures through it changes NOTHING — same id,
 * same sig, byte for byte, and NIP-04 that still round-trips against the
 * implementation the rest of the app (and every peer) already uses.
 *
 * If these fail, existing accounts break. Nothing else in the signer work is
 * worth anything until they pass.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/reticulum.dart';
import 'package:aurora/services/nostr/nostr_signer.dart';

const _privHex =
    '00b1c3d5e7f9a1b3c5d7e9fb0d1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b';

NostrEvent _unsigned(String pub, {int kind = 1, String content = 'hello'}) =>
    NostrEvent(
      pubkey: pub,
      createdAt: 1752300000,
      kind: kind,
      tags: const [],
      content: content,
    );

void main() {
  final pub = NostrCrypto.derivePublicKey(_privHex);

  test('LocalSigner produces exactly what NostrEvent.sign produced', () async {
    // The old way, still used everywhere that has not been migrated yet.
    final direct = _unsigned(pub)..sign(_privHex);

    // The new way.
    final signer = LocalSigner(_privHex);
    final viaSigner = await signer.signEvent(_unsigned(pub));

    expect(viaSigner.id, direct.id);
    expect(viaSigner.sig, isNotNull);
    expect(viaSigner.verify(), isTrue);
    // Schnorr is randomised per BIP-340's aux-rand, so the sig BYTES may differ
    // between two signings of the same message — what must be identical is the
    // id (a pure hash) and the fact that both verify under the same pubkey.
    expect(direct.verify(), isTrue);
    expect(viaSigner.pubkey, direct.pubkey);
  });

  test('the public key is the one the profile already stores', () async {
    final signer = LocalSigner(_privHex);
    expect(await signer.publicKey(), pub);
    expect((await signer.publicKey()).length, 64);
  });

  test('fromNsec accepts what the user pastes today', () async {
    final nsec = NostrCrypto.encodeNsec(_privHex);
    final signer = LocalSigner.fromNsec(nsec);
    expect(await signer.publicKey(), pub);
  });

  test('NIP-04 round-trips against the implementation peers already use',
      () async {
    // A second party, as in a real DM.
    const peerPriv =
        '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff';
    final peerPub = NostrCrypto.derivePublicKey(peerPriv);

    final me = LocalSigner(_privHex);
    final them = LocalSigner(peerPriv);

    const message = 'the mesh went quiet for three days';
    final ct = await me.nip04Encrypt(peerPub, message);

    // The RECIPIENT decrypts with their key and OUR pubkey — this is the shape
    // rns_service.relayDmFetch uses, so a mismatch here is a broken inbox.
    expect(await them.nip04Decrypt(pub, ct), message);
  });

  test('NIP-04 handles a message with newlines and emoji', () async {
    const peerPriv =
        '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff';
    final peerPub = NostrCrypto.derivePublicKey(peerPriv);
    final me = LocalSigner(_privHex);
    final them = LocalSigner(peerPriv);

    const message = 'line one\nline two 😂\nsigned, X1A67X';
    final ct = await me.nip04Encrypt(peerPub, message);
    expect(await them.nip04Decrypt(pub, ct), message);
  });

  test('a local signer is always available — the whole app depends on it',
      () async {
    final signer = LocalSigner(_privHex);
    expect(signer.isLocal, isTrue);
    // Boot, background ticks and the launcher's startup wapp-signing all sign
    // with no user present. A local key must never claim it cannot.
    expect(signer.worksHeadless, isTrue);
  });

  test('garbage ciphertext fails loudly, not silently', () async {
    final me = LocalSigner(_privHex);
    await expectLater(
      me.nip04Decrypt(pub, 'not-a-nip04-payload'),
      throwsA(isA<SignerException>()),
    );
  });
}
