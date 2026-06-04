idf_component_register(
    SRCS "dns_server.c"
    INCLUDE_DIRS "."
    REQUIRES log lwip
    PRIV_REQUIRES freertos
)
