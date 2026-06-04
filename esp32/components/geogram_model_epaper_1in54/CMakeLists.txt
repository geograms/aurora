# Only build for ESP32-S3 ePaper board
if(CONFIG_GEOGRAM_BOARD_EPAPER_1IN54)
    idf_component_register(
        SRCS "model_init.c" "board_power.cpp"
        INCLUDE_DIRS "."
        REQUIRES driver log nvs_flash geogram_i2c geogram_epaper_1in54 geogram_pcf85063 geogram_shtc3 geogram_button geogram_sdcard
        PRIV_REQUIRES freertos
    )
else()
    idf_component_register()
endif()
