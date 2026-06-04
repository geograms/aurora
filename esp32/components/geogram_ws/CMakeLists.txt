idf_component_register(
    SRCS "ws_server.c"
    INCLUDE_DIRS "."
    REQUIRES log esp_http_server geogram_station geogram_json
)
