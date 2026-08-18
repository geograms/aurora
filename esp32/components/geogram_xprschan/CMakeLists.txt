# Meeting on a working channel (XPRS.md §23.7) — see xprschan.h.
#
# Depends on the WiFi driver because moving channel and switching to the
# long-range PHY is what it does; the packets themselves are geogram_xprs.
#
# test_xprschan_host.c is a HOST gcc harness (run test_xprschan_host.sh) and is
# deliberately not in SRCS — it builds xprschan.c with XPRSCHAN_HOST_TEST, which
# swaps the radio for counters.
idf_component_register(
    SRCS "xprschan.c"
    INCLUDE_DIRS "."
    REQUIRES geogram_xprs esp_wifi log)
