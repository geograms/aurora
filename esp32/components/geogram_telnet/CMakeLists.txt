idf_component_register(
    SRCS "telnet_server.c"
    INCLUDE_DIRS "."
    REQUIRES log console lwip freertos
)
