# XPRS over ESP-NOW — see xprsnow.h and docs/espnow.md.
#
# The queue, the rings and the §13.2.1 cancel are geogram_xprsbearer, shared
# with the LAN bearer; this component is the radio and nothing else.
idf_component_register(
    SRCS "xprsnow.c"
    INCLUDE_DIRS "."
    REQUIRES geogram_xprs geogram_xprsbearer esp_wifi esp_timer esp_hw_support log)
