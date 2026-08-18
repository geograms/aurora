#!/bin/sh
# Host-side test for the §23.7 rendezvous: builds xprschan.c against the real
# XPRS codec with no radio, so every branch of the choreography is checked
# without flashing two boards and watching serial for two minutes a build.
set -e
cd "$(dirname "$0")"

XPRS=../geogram_xprs
SHA=../geogram_xprsindex/test_sha256_host.c   # the codec's sha256 on the host

gcc -Wall -Wextra -Werror -O1 -DXPRSCHAN_HOST_TEST \
    -I. -I"$XPRS" \
    -o /tmp/test_xprschan \
    xprschan.c "$XPRS"/xprs.c test_xprschan_host.c "$SHA"

/tmp/test_xprschan
