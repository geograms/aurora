#!/bin/sh
# Host test for the RNS codec: rns.c built with OpenSSL for the primitives and
# the tree's TweetNaCl for X25519 (the same code the device runs), checked
# against vectors produced by reticulum-dart — see test_rns_host.c.
#
# TweetNaCl is upstream and is compiled on its own without -Werror; our warning
# policy is for our code, not for a vendored reference implementation.
set -e
cd "$(dirname "$0")"

NACL=../../rns_ble5/src/tweetnacl.c

gcc -O1 -c "$NACL" -o /tmp/tweetnacl_host.o
gcc -Wall -Wextra -Werror -O1 -DRNS_HOST_TEST \
    -I. -o /tmp/test_rns \
    rns.c test_rns_host.c /tmp/tweetnacl_host.o \
    -lcrypto

/tmp/test_rns
