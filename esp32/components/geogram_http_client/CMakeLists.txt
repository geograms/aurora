idf_component_register(
    SRCS "http_client_async.c"
    INCLUDE_DIRS "."
    REQUIRES log esp_http_client freertos
)
