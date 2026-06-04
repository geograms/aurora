# FTP server component - only build for boards with SD card support
if(CONFIG_GEOGRAM_BOARD_EPAPER_1IN54)
    idf_component_register(
        SRCS "ftp_server.c"
        INCLUDE_DIRS "."
        REQUIRES log nvs_flash geogram_sdcard
    )
else()
    # Register empty component for boards without SD card
    idf_component_register()
endif()
