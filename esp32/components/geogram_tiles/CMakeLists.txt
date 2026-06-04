# Tiles component - only build for boards with SD card support
if("${IDF_TARGET}" STREQUAL "esp32s3")
    idf_component_register(
        SRCS "tiles.c"
        INCLUDE_DIRS "."
        REQUIRES log geogram_sdcard geogram_http_client esp_http_server
    )
else()
    # Register empty component for boards without SD card
    idf_component_register(
        INCLUDE_DIRS "."
    )
endif()
