# Geogram Station component
# Base requirements for all boards
set(STATION_REQUIRES log esp_wifi esp_timer geogram_json geogram_nostr geogram_common)

# Add tiles and mesh for boards with support
if("${IDF_TARGET}" STREQUAL "esp32s3")
    list(APPEND STATION_REQUIRES geogram_tiles esp_http_server)
endif()

# Add mesh support for applicable targets
if("${IDF_TARGET}" STREQUAL "esp32" OR "${IDF_TARGET}" STREQUAL "esp32s2" OR "${IDF_TARGET}" STREQUAL "esp32s3" OR "${IDF_TARGET}" STREQUAL "esp32c3")
    list(APPEND STATION_REQUIRES geogram_mesh)
endif()

idf_component_register(
    SRCS "station.c"
    INCLUDE_DIRS "."
    REQUIRES ${STATION_REQUIRES}
)
