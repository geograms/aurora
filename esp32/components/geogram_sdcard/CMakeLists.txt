# SD card component for Geogram (1-bit SDMMC, FAT32, auto-format).
#
# Gated by IDF_TARGET (not CONFIG_*): component REQUIRES are resolved in an early
# expansion pass where CONFIG_* values are NOT yet available, so a CONFIG-guarded
# idf_component_register drops its REQUIRES from the dependency graph (dependents
# then fail to find sdcard.h). IDF_TARGET is available in that pass. SDMMC exists
# on esp32/s2/s3; on other targets register empty. The driver only runs where
# sdcard_init() is actually called (T-Dongle / ePaper); elsewhere it is dead code.
if(IDF_TARGET STREQUAL "esp32" OR IDF_TARGET STREQUAL "esp32s2" OR IDF_TARGET STREQUAL "esp32s3")
    idf_component_register(
        SRCS "sdcard.c"
        INCLUDE_DIRS "."
        REQUIRES fatfs vfs sdmmc log
    )
    # The ePaper board's SD pins match sdcard.c's #ifndef defaults (39/41/40);
    # the LilyGo T-Dongle-S3 TF slot is SDMMC 1-bit on CLK=12 / CMD=16 / D0=14.
    if(CONFIG_GEOGRAM_BOARD_TDONGLE_S3)
        target_compile_definitions(${COMPONENT_LIB} PRIVATE
            SDCARD_CLK_PIN=12 SDCARD_CMD_PIN=16 SDCARD_D0_PIN=14)
    endif()
else()
    idf_component_register()
endif()
