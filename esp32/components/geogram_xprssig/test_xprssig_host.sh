#!/bin/sh
# Host test for the XPRS signer: built with OpenSSL for the curve and the hash,
# and checked against a signature reticulum-dart produced (tool/
# gen_sig_vectors.dart). See test_xprssig_host.c for why verification rather
# than reproduction is the assertion that matters.
set -e
cd "$(dirname "$0")"
gcc -Wall -Wextra -Werror -O1 -DXPRSSIG_HOST_TEST \
    -I. -o /tmp/test_xprssig xprssig.c test_xprssig_host.c -lcrypto
/tmp/test_xprssig
