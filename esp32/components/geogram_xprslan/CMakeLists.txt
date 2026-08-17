# XPRS over the LAN (UDP broadcast) — see xprslan.h and docs/lan.md.
#
# Registered on every target: it is lwip and freertos only, like geogram_lanwatch,
# and stays dead code where xprslan_start() is never called.
#
# test_xprslan_host.c is a HOST gcc harness (run test_xprslan_host.sh) and is
# deliberately not in SRCS — same arrangement as geogram_xprs/test_xprs_host.c.
idf_component_register(
    SRCS "xprslan.c"
    INCLUDE_DIRS "."
    REQUIRES geogram_xprs geogram_xprsbearer lwip log esp_timer esp_hw_support)
