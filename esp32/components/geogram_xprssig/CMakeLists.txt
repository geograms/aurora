# XPRS signatures (docs/XPRS.md §9.1). secp256k1 and SHA-256 come from mbedtls
# on the device; test_xprssig_host.* are a HOST gcc harness (OpenSSL) run by
# test_xprssig_host.sh and never compiled into the firmware.
idf_component_register(
    SRCS "xprssig.c"
    INCLUDE_DIRS "."
    REQUIRES mbedtls esp_hw_support log)
