if(CONFIG_GEOGRAM_BOARD_HELTEC_V1 OR CONFIG_GEOGRAM_BOARD_HELTEC_V2)
    idf_component_register(
        SRCS "sx1276.c"
        INCLUDE_DIRS "."
        REQUIRES driver log
        PRIV_REQUIRES freertos
    )
else()
    idf_component_register()
endif()
