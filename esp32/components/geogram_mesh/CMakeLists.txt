# Geogram ESP-MESH Networking Component
# Provides mesh networking with IP bridging for phone connectivity
# Note: ESP-MESH is supported on ESP32, ESP32-S2, ESP32-S3, and ESP32-C3

# Check if we're on a supported target for ESP-MESH
# Use IDF_TARGET which is set by the build system
if("${IDF_TARGET}" STREQUAL "esp32" OR "${IDF_TARGET}" STREQUAL "esp32s2" OR "${IDF_TARGET}" STREQUAL "esp32s3" OR "${IDF_TARGET}" STREQUAL "esp32c3")
    set(MESH_SUPPORTED ON)
else()
    set(MESH_SUPPORTED OFF)
endif()

if(MESH_SUPPORTED)
    set(MESH_SRCS
        "mesh_bsp.c"
        "mesh_bridge.c"
        "mesh_chat.c"
    )

    set(MESH_REQUIRES
        log
        esp_wifi
        esp_event
        esp_netif
        nvs_flash
        freertos
        lwip
        esp_timer
        json
        app_update
        espressif__iot_bridge
        espressif__mesh_lite
    )

    idf_component_register(
        SRCS ${MESH_SRCS}
        INCLUDE_DIRS "." "include"
        REQUIRES ${MESH_REQUIRES}
        PRIV_REQUIRES geogram_common geogram_led
    )
else()
    # For unsupported targets, register a stub component with just headers
    idf_component_register(
        INCLUDE_DIRS "." "include"
    )
endif()
