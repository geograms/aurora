#!/bin/sh
# Host-side test for the XPRS LAN bearer: builds xprslan.c against the real XPRS
# codec and drives it with a fake clock and no sockets, so the relay rules, the
# random delay and the hear-it-first cancel are all checked without hardware.
set -e
cd "$(dirname "$0")"

XPRS=../geogram_xprs
SHA=../geogram_xprsindex/test_sha256_host.c   # the codec's sha256 on the host

gcc -Wall -Wextra -Werror -O1 -DXPRSLAN_HOST_TEST \
    -I. -I"$XPRS" \
    -o /tmp/test_xprslan \
    xprslan.c "$XPRS"/xprs.c test_xprslan_host.c "$SHA"

/tmp/test_xprslan
