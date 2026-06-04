# Only build for Generic ESP32
if(CONFIG_GEOGRAM_BOARD_GENERIC)
    idf_component_register(
        SRCS "model_init.c"
        INCLUDE_DIRS "."
        REQUIRES driver log
    )
else()
    idf_component_register()
endif()
