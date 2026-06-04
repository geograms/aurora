# Geogram UI component
# Only build for ESP32-S3 targets with e-paper display

if(CONFIG_GEOGRAM_BOARD_EPAPER_1IN54)
    idf_component_register(
        SRCS "geogram_ui.c"
        INCLUDE_DIRS "."
        REQUIRES lvgl geogram_lvgl geogram_shtc3 log
        PRIV_REQUIRES freertos
    )
else()
    # Register empty component for non-ESP32S3 targets
    idf_component_register()
endif()
