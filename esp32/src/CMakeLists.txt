# This file was automatically generated for projects
# without default 'CMakeLists.txt' file.

FILE(GLOB_RECURSE app_sources ${CMAKE_SOURCE_DIR}/src/*.*)

set(APP_REQUIRES geogram_ble geogram_ble_aprs nvs_flash geogram_ble_hello)

# FTP only on ePaper board (has SD card)
if(CONFIG_GEOGRAM_BOARD_EPAPER_1IN54)
    list(APPEND APP_REQUIRES geogram_ftp)
endif()

# APRS-IS iGate + SD-backed message store only on the T-Dongle-S3
if(CONFIG_GEOGRAM_BOARD_TDONGLE_S3)
    list(APPEND APP_REQUIRES geogram_aprsis geogram_sdcard geogram_msgstore)
endif()

idf_component_register(
    SRCS ${app_sources}
    REQUIRES ${APP_REQUIRES}
)
