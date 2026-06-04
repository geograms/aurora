idf_component_register(
    SRCS "geoloc.c"
    INCLUDE_DIRS "."
    REQUIRES esp_http_client json log
)
