/* xprs_sha256 on the target: mbedTLS, the same primitive the RNS side of the
 * firmware already links. The host test harness (test_xprs_host.c) supplies
 * its own implementation instead, so xprs.c itself stays IDF-free. */
#include "xprs.h"

#include "mbedtls/sha256.h"

void xprs_sha256(const uint8_t *in, size_t len, uint8_t out[32])
{
    mbedtls_sha256(in, len, out, 0);
}
