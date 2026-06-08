# Persistent APRS message store (SD-backed).
#
# Gated by IDF_TARGET (not CONFIG_*) so its REQUIRES survive the early expansion
# pass — see geogram_sdcard/CMakeLists.txt for the rationale. Compiles on
# esp32/s2/s3 (where SDMMC + FAT exist); registers empty elsewhere. Only used at
# runtime where msgstore_init() is called (T-Dongle); dead code on other boards.
if(IDF_TARGET STREQUAL "esp32" OR IDF_TARGET STREQUAL "esp32s2" OR IDF_TARGET STREQUAL "esp32s3")
    idf_component_register(
        SRCS "msgstore.c"
        INCLUDE_DIRS "."
        REQUIRES geogram_sdcard fatfs vfs log
        PRIV_REQUIRES esp_hw_support
    )
else()
    idf_component_register()
endif()
