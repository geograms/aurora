# Only build for Heltec WiFi LoRa 32 V1
if(CONFIG_GEOGRAM_BOARD_HELTEC_V1)
    idf_component_register(
        SRCS "model_init.c"
        INCLUDE_DIRS "."
        REQUIRES driver log nvs_flash geogram_i2c geogram_ssd1306 geogram_sx1276
        PRIV_REQUIRES freertos
    )
else()
    idf_component_register()
endif()
