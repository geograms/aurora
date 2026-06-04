idf_component_register(
    SRCS "i2c_bsp.c"
    INCLUDE_DIRS "." "include"
    REQUIRES driver log
    PRIV_REQUIRES freertos
)
