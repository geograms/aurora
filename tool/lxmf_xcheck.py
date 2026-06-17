#!/usr/bin/env python3
# Cross-check helper for Aurora's Dart LXMF against the reference markqvist/LXMF.
#   verify_dart <packed_file> <src_pubkey_file>  -> validate a Dart-made message
#   make_py     <out_packed>  <out_src_pubkey> [cfg]  -> make a real LXMF message
import sys, os
import RNS
import RNS.vendor.umsgpack as umsgpack


def verify_packed(data, srcpub):
    dest = data[:16]; src = data[16:32]; sig = data[32:96]; pp = data[96:]
    payload = umsgpack.unpackb(pp)
    if len(payload) > 4:
        pp = umsgpack.packb(payload[:4])
    hashed = dest + src + pp
    h = RNS.Identity.full_hash(hashed)
    signed = hashed + h
    idn = RNS.Identity(create_keys=False)
    idn.load_public_key(srcpub)
    return idn.validate(sig, signed), payload


def main():
    mode = sys.argv[1]
    if mode == "verify_dart":
        data = open(sys.argv[2], "rb").read()
        srcpub = open(sys.argv[3], "rb").read()
        ok, payload = verify_packed(data, srcpub)
        print("SIG", bool(ok))
        print("TITLE", payload[1].decode("utf-8", "replace"))
        print("CONTENT", payload[2].decode("utf-8", "replace"))
        print("FIELDS", dict(payload[3]) if isinstance(payload[3], dict) else payload[3])
    elif mode == "make_py":
        import LXMF
        cfg = sys.argv[4] if len(sys.argv) > 4 else "/tmp/rns_xcheck_cfg"
        os.makedirs(cfg, exist_ok=True)
        open(cfg + "/config", "w").write(
            "[reticulum]\n  enable_transport = False\n  share_instance = No\n[interfaces]\n")
        RNS.Reticulum(configdir=cfg)
        src_id = RNS.Identity()
        dst_id = RNS.Identity()
        src_dest = RNS.Destination(src_id, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
        dst_dest = RNS.Destination(dst_id, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
        m = LXMF.LXMessage(dst_dest, src_dest, "hello from python LXMF",
                           "py-title", fields={0x05: [[b"a.txt", b"hi"]]})
        m.pack()
        open(sys.argv[2], "wb").write(m.packed)
        open(sys.argv[3], "wb").write(src_id.get_public_key())
        print("MADE", len(m.packed))


main()
