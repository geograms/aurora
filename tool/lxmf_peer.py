#!/usr/bin/env python3
# A reference LXMF peer (markqvist/LXMF) connected to an rnsd over TCP, used to
# interop-test Aurora's Dart LXMF. It announces its delivery destination, prints
# PY_DEST, prints PY_RECV on every received message, and — once a Dart delivery
# hash appears in <cfg>/dart_dest.txt — sends a message to it (DIRECT).
#
#   lxmf_peer.py <cfg_dir> <rnsd_port>
import sys, os, time
sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)
import RNS
import LXMF

cfg = sys.argv[1]
port = int(sys.argv[2])
os.makedirs(cfg, exist_ok=True)
open(cfg + "/config", "w").write(f"""
[reticulum]
  enable_transport = False
  share_instance = No
  panic_on_interface_error = No
[logging]
  loglevel = 6
[interfaces]
  [[rnsd]]
    type = TCPClientInterface
    enabled = True
    target_host = 127.0.0.1
    target_port = {port}
""")

RNS.Reticulum(configdir=cfg)
router = LXMF.LXMRouter(storagepath=cfg + "/lxmf")
identity = RNS.Identity()
local = router.register_delivery_identity(identity, display_name="pypeer")

def delivery_cb(message):
    try:
        print("PY_RECV " + message.content.decode("utf-8", "replace"), flush=True)
    except Exception as e:
        print("PY_RECV_ERR " + str(e), flush=True)

router.register_delivery_callback(delivery_cb)
router.announce(local.hash)
print("PY_DEST " + RNS.hexrep(local.hash, delimit=False), flush=True)

sent = False
deadline = time.time() + 70
while time.time() < deadline:
    # Keep announcing so the Dart node learns us.
    router.announce(local.hash)
    if not sent and os.path.exists(cfg + "/dart_dest.txt"):
        try:
            dart_hex = open(cfg + "/dart_dest.txt").read().strip()
            dart_dest = bytes.fromhex(dart_hex)
            if not RNS.Identity.recall(dart_dest):
                RNS.Transport.request_path(dart_dest)
            dest_identity = RNS.Identity.recall(dart_dest)
            if dest_identity:
                dest = RNS.Destination(dest_identity, RNS.Destination.OUT,
                                       RNS.Destination.SINGLE, "lxmf", "delivery")
                m = LXMF.LXMessage(dest, local, "hello dart from python LXMF",
                                   "py-title", desired_method=LXMF.LXMessage.DIRECT)
                router.handle_outbound(m)
                print("PY_SENT", flush=True)
                sent = True
        except Exception as e:
            print("PY_SEND_ERR " + str(e), flush=True)
    time.sleep(2)
print("PY_DONE", flush=True)
