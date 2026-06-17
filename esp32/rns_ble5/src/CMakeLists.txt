idf_component_register(
    SRCS "main.c" "tweetnacl.c"
    INCLUDE_DIRS "."
    REQUIRES bt nvs_flash log esp_timer mbedtls esp_hw_support
             esp_wifi esp_event esp_netif
             geogram_model_tdongle_s3 geogram_st7735 geogram_tdongle_ui
             geogram_wifi geogram_aprsis
)
