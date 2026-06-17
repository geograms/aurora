#!/usr/bin/env python3
"""
RNS Phase-2 reference: an echo destination served over a TCPServerInterface, so
a Dart initiator can connect, establish a Link, and exchange encrypted data.

  python3 tool/reticulum_echo.py [configdir] [listen_port]

It announces aurora.echo every few seconds (so a freshly-connected client hears
it) and echoes any data received over an established link back to the sender.
"""
import os
import sys
import time

import RNS

APP = "aurora"
ASPECT = "echo"


def make_config(configdir, port):
    os.makedirs(configdir, exist_ok=True)
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


def packet_received(message, packet):
    RNS.log(f"echo: received {len(message)} bytes, echoing back", RNS.LOG_INFO)
    RNS.Packet(packet.link, message).send()


def link_established(link):
    RNS.log("echo: link established", RNS.LOG_INFO)
    link.set_packet_callback(packet_received)


def main():
    configdir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/rns_echo_cfg"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 4242
    make_config(configdir, port)
    RNS.Reticulum(configdir)

    identity = RNS.Identity()
    destination = RNS.Destination(
        identity, RNS.Destination.IN, RNS.Destination.SINGLE, APP, ASPECT)
    destination.set_link_established_callback(link_established)

    RNS.log(f"echo: destination {destination.hash.hex()} up", RNS.LOG_INFO)
    print(f"DEST {destination.hash.hex()}", flush=True)
    print(f"IDENTITY {identity.hash.hex()}", flush=True)

    while True:
        destination.announce()
        time.sleep(5)


if __name__ == "__main__":
    main()
