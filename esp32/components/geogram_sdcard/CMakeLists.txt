# SD card component for Geogram
# Only build for ESP32-S3 targets that have SD card support

if(CONFIG_GEOGRAM_BOARD_EPAPER_1IN54)
    idf_component_register(
        SRCS "sdcard.c"
        INCLUDE_DIRS "."
        REQUIRES fatfs vfs sdmmc log
    )
else()
    # Register empty component for non-ESP32S3 targets
    idf_component_register()
endif()
