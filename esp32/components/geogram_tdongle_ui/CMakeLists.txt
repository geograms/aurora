# Only the source is board-gated. REQUIRES/INCLUDE_DIRS are UNCONDITIONAL because
# ESP-IDF expands component requirements before Kconfig is loaded; a guarded
# REQUIRES is dropped from the dependency graph (then tdongle_ui.c can't find
# st7735.h). See geogram_st7735/CMakeLists.txt for the full explanation.
if(CONFIG_GEOGRAM_BOARD_TDONGLE_S3)
    set(srcs "tdongle_ui.c")
endif()
idf_component_register(
    SRCS ${srcs}
    INCLUDE_DIRS "."
    REQUIRES log geogram_st7735 lvgl__lvgl esp_timer
)
