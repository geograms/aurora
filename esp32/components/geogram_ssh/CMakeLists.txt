idf_component_register(
    SRCS "geogram_ssh.c"
    INCLUDE_DIRS "."
    REQUIRES log nvs_flash mbedtls console jimmyw__ssh_cli_server
)
