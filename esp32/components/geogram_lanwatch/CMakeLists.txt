# Passive listener for the Aurora LAN discovery broadcast (UDP 42671, one raw
# RNS announce per datagram). Registry of geogram devices on the local network.
# Pure observer (never transmits) — no radio/UI deps, reusable on any target.
idf_component_register(
    SRCS "lanwatch.c"
    INCLUDE_DIRS "."
    REQUIRES log esp_timer lwip freertos
)
