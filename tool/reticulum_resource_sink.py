#!/usr/bin/env python3
"""
RNS Phase-3b reference: a destination that accepts Resources over a Link and
prints the SHA-256 of each received resource, so a Dart sender can be verified.

  python3 tool/reticulum_resource_sink.py [configdir] [listen_port]
"""
import hashlib
import os
import sys
import time

import RNS

APP = "aurora"
ASPECT = "resource"


def make_config(configdir, port):
    os.makedirs(configdir, exist_ok=True)
    # RNS reassembles received resources into this directory.
    os.makedirs(os.path.join(configdir, "storage", "resources"), exist_ok=True)
    with open(os.path.join(configdir, "config"), "w") as f:
        f.write(
            "[reticulum]\n"
            "  enable_transport = No\n"
            "  share_instance = No\n"
            "  panic_on_interface_error = No\n\n"
            "[logging]\n"
            "  loglevel = 4\n\n"
            "[interfaces]\n"
            "  [[TCP Server]]\n"
            "    type = TCPServerInterface\n"
            "    interface_enabled = Yes\n"
            "    listen_ip = 127.0.0.1\n"
            f"    listen_port = {port}\n"
        )


def resource_concluded(resource):
    data = resource.data
    if hasattr(data, "read"):
        data = data.read()
    digest = hashlib.sha256(data).hexdigest()
    RNS.log(f"sink: resource concluded, {len(data)} bytes, sha256={digest}",
            RNS.LOG_INFO)
    print(f"RECEIVED_SHA256 {digest}", flush=True)
    print(f"RECEIVED_LEN {len(data)}", flush=True)


def link_established(link):
    RNS.log("sink: link established", RNS.LOG_INFO)
    link.set_resource_strategy(RNS.Link.ACCEPT_ALL)
    link.set_resource_concluded_callback(resource_concluded)


def main():
    configdir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/rns_rsink_cfg"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 4242
    make_config(configdir, port)
    RNS.Reticulum(configdir)

    identity = RNS.Identity()
    destination = RNS.Destination(
        identity, RNS.Destination.IN, RNS.Destination.SINGLE, APP, ASPECT)
    destination.set_link_established_callback(link_established)

    print(f"DEST {destination.hash.hex()}", flush=True)
    RNS.log(f"sink: aurora.resource {destination.hash.hex()} up", RNS.LOG_INFO)

    while True:
        destination.announce()
        time.sleep(5)


if __name__ == "__main__":
    main()
