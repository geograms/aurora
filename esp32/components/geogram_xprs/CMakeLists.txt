# test_xprs_host.c is a HOST-side gcc harness (run test_xprs_host.sh), never
# compiled into the firmware — same arrangement as geogram_blemesh's
# test_msp_host.c.
idf_component_register(
    SRCS "xprs.c" "xprs_sha256_idf.c"
    INCLUDE_DIRS "."
    REQUIRES mbedtls)
