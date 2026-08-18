# Making and checking an XPRS signature (§9.1) — see xprsid.h. Pure: the keys
# come from the caller, so nothing here knows whose they are.
idf_component_register(
    SRCS "xprsid.c"
    INCLUDE_DIRS "."
    REQUIRES geogram_xprs geogram_xprssig mbedtls log)
