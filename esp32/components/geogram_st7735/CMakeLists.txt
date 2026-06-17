# Only the source is board-gated (the ST7735 LCD exists on the T-Dongle-S3 only).
# REQUIRES/PRIV_REQUIRES and INCLUDE_DIRS are UNCONDITIONAL: ESP-IDF expands
# component requirements BEFORE Kconfig is loaded, so requirements that sit behind
# an if(CONFIG_*) guard are silently dropped from the dependency graph (the
# component then can't find driver/spi_master.h). On non-TDongle boards this
# component just builds empty but still declares its (harmless) interface deps.
if(CONFIG_GEOGRAM_BOARD_TDONGLE_S3)
    set(srcs "st7735.c")
endif()
idf_component_register(
    SRCS ${srcs}
    INCLUDE_DIRS "."
    REQUIRES driver log
    PRIV_REQUIRES freertos
)
