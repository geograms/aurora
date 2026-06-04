# Geogram LED component - WS2812 RGB LED driver

# Only build on targets with RMT peripheral
if("${IDF_TARGET}" STREQUAL "esp32" OR "${IDF_TARGET}" STREQUAL "esp32s2" OR "${IDF_TARGET}" STREQUAL "esp32s3" OR "${IDF_TARGET}" STREQUAL "esp32c3")
    idf_component_register(
        SRCS "led_bsp.c"
        INCLUDE_DIRS "include"
        REQUIRES driver freertos log
    )
else()
    # Stub for unsupported targets
    idf_component_register(
        INCLUDE_DIRS "include"
    )
endif()
