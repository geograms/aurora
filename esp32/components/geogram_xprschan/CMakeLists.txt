# Meeting on a working channel (XPRS.md §23.7) — see xprschan.h.
#
# Depends on the WiFi driver because moving channel and switching to the
# long-range PHY is what it does; the packets themselves are geogram_xprs.
idf_component_register(
    SRCS "xprschan.c"
    INCLUDE_DIRS "."
    REQUIRES geogram_xprs esp_wifi log)
