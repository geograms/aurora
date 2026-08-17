#!/bin/sh
# Host-side test for the XPRS LAN bearer: builds xprslan.c against the real XPRS
# codec and drives it with a fake clock and no sockets, so the relay rules, the
# random delay and the hear-it-first cancel are all checked without hardware.
set -e
cd "$(dirname "$0")"

XPRS=../geogram_xprs
BEARER=../geogram_xprsbearer                  # the queue, the rings, the cancel
SHA=../geogram_xprsindex/test_sha256_host.c   # the codec's sha256 on the host

# XB_HOST_TEST silences the shared core's ESP logging; XPRSLAN_HOST_TEST swaps
# this bearer's socket for the fake radio in xprslan.c.
gcc -Wall -Wextra -Werror -O1 -DXPRSLAN_HOST_TEST -DXB_HOST_TEST \
    -I. -I"$XPRS" -I"$BEARER" \
    -o /tmp/test_xprslan \
    xprslan.c "$BEARER"/xprsbearer.c "$XPRS"/xprs.c test_xprslan_host.c "$SHA"

/tmp/test_xprslan
