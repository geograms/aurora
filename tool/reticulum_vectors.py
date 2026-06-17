#!/usr/bin/env python3
"""
RNS Phase-0 interop vector generator/verifier (pinned to the installed `rns`).

Usage:
  python3 tool/reticulum_vectors.py gen > /tmp/rns_vectors.json
  python3 tool/reticulum_vectors.py verify /tmp/rns_dart_out.json

`gen` emits reference vectors (identity, destination hashes, a deterministic
Token vector, a Python-encrypted token for Dart to decrypt, and a Python
announce for Dart to validate). `verify` checks artifacts that the Dart test
produced (a Dart-encrypted token Python must decrypt, and a Dart signature
Python must validate) — proving both directions.
"""
import json
import os
import sys

import RNS
from RNS.Cryptography import HMAC
from RNS.Cryptography.AES import AES_256_CBC
from RNS.Cryptography import PKCS7

APP = "aurora"
ASPECTS = ["test"]
PLAINTEXT = b"Reticulum <-> Dart interop, hello!"


def h(b):
    return b.hex()


def unh(s):
    return bytes.fromhex(s)


def manual_token_encrypt(key64, iv, plaintext):
    signing_key, enc_key = key64[:32], key64[32:]
    ct = AES_256_CBC.encrypt(PKCS7.pad(plaintext), enc_key, iv)
    signed = iv + ct
    return signed + HMAC.new(signing_key, signed).digest()


def init_rns():
    """Bring up a minimal, no-interface Reticulum instance so Destination
    registration works, without touching the network."""
    import tempfile
    cfgdir = tempfile.mkdtemp(prefix="rns_vectors_")
    with open(os.path.join(cfgdir, "config"), "w") as f:
        f.write(
            "[reticulum]\n"
            "  enable_transport = No\n"
            "  share_instance = No\n"
            "  panic_on_interface_error = No\n\n"
            "[logging]\n"
            "  loglevel = 0\n\n"
            "[interfaces]\n"
        )
    return RNS.Reticulum(configdir=cfgdir)


def gen():
    init_rns()
    identity = RNS.Identity()
    dest = RNS.Destination(identity, RNS.Destination.IN, RNS.Destination.SINGLE, APP, *ASPECTS)

    # Deterministic Token vector (fixed key + iv) so Dart encrypt must match byte-for-byte.
    token_key = bytes(range(64))
    token_iv = bytes(range(16))
    token_ct = manual_token_encrypt(token_key, token_iv, PLAINTEXT)

    # A Python-encrypted Identity token Dart must decrypt (random eph + iv inside).
    py_identity_token = identity.encrypt(PLAINTEXT)

    # A Python announce for Dart to parse + validate (send=False returns the packet).
    ann = dest.announce(app_data=b"aurora-node", send=False)

    # AutoInterface discovery derivations (group address + peering token),
    # computed exactly as RNS/Interfaces/AutoInterface.py does.
    group_id = "reticulum".encode("utf-8")
    group_hash = RNS.Identity.full_hash(group_id)
    g = group_hash
    gt = "0"
    for pair in [(2, 3), (4, 5), (6, 7), (8, 9), (10, 11), (12, 13)]:
        hi, lo = pair
        gt += ":" + "{:02x}".format(g[lo] + (g[hi] << 8))
    mcast_addr = "ff" + "1" + "2" + ":" + gt  # temporary type, link scope
    sample_lla = "fe80::651b:8364:5ec6:9ac7"
    peering_token = RNS.Identity.full_hash(group_id + sample_lla.encode("utf-8"))

    out = {
        "rns_version": RNS.__version__,
        "app_name": APP,
        "aspects": ASPECTS,
        "identity_prv": h(identity.get_private_key()),
        "identity_pub": h(identity.get_public_key()),
        "identity_hash": h(identity.hash),
        "name_hash": h(dest.name_hash),
        "dest_hash": h(dest.hash),
        "token_key": h(token_key),
        "token_iv": h(token_iv),
        "token_plaintext": h(PLAINTEXT),
        "token_ciphertext": h(token_ct),
        "identity_token": h(py_identity_token),
        "announce_dest_hash": h(dest.hash),
        "announce_data": h(ann.data),
        "announce_context_flag": ann.context_flag,
        "auto_group_hash": h(group_hash),
        "auto_mcast_addr": mcast_addr,
        "auto_sample_lla": sample_lla,
        "auto_peering_token": h(peering_token),
    }
    print(json.dumps(out, indent=2))


def verify(path):
    with open(path) as f:
        d = json.load(f)
    ok = True

    # 1. Python decrypts a Dart-encrypted Identity token.
    identity = RNS.Identity(create_keys=False)
    identity.load_private_key(unh(d["ref_identity_prv"]))
    try:
        pt = identity.decrypt(unh(d["dart_identity_token"]))
        if pt == unh(d["expect_plaintext"]):
            print("  ok   python decrypts dart token")
        else:
            ok = False
            print(f"  FAIL python decrypt mismatch: {pt}")
    except Exception as e:
        ok = False
        print(f"  FAIL python decrypt raised: {e}")

    # 2. Python validates a Dart signature over known data.
    signer = RNS.Identity(create_keys=False)
    signer.load_public_key(unh(d["dart_signer_pub"]))
    if signer.validate(unh(d["dart_signature"]), unh(d["signed_message"])):
        print("  ok   python validates dart signature")
    else:
        ok = False
        print("  FAIL python rejects dart signature")

    print(">>> SUCCESS" if ok else ">>> FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "gen":
        gen()
        sys.stdout.flush()
        os._exit(0)  # RNS keeps non-daemon threads alive; force a clean exit
    elif len(sys.argv) >= 3 and sys.argv[1] == "verify":
        verify(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)
