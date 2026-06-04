# Only build for Heltec WiFi LoRa 32 V2
if(CONFIG_GEOGRAM_BOARD_HELTEC_V2)
    idf_component_register(
        SRCS "model_init.c"
        INCLUDE_DIRS "."
        REQUIRES driver log nvs_flash geogram_i2c geogram_ssd1306 geogram_sx1276
        PRIV_REQUIRES freertos
    )
else()
    idf_component_register()
endif()
