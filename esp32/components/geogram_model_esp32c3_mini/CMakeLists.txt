# Only build for ESP32-C3 Mini
if("${IDF_TARGET}" STREQUAL "esp32c3")
    idf_component_register(
        SRCS "model_init.c"
        INCLUDE_DIRS "."
        REQUIRES driver log nvs_flash geogram_led
    )
else()
    idf_component_register()
endif()
