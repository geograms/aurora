idf_component_register(
    SRCS "button_bsp.c"
    INCLUDE_DIRS "."
    REQUIRES driver log
    PRIV_REQUIRES freertos
)
