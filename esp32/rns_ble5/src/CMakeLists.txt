idf_component_register(
    SRCS "main.c" "tweetnacl.c" "gatt_mesh.c"
    INCLUDE_DIRS "."
    REQUIRES bt nvs_flash log esp_timer mbedtls esp_hw_support
             esp_wifi esp_event esp_netif lwip driver
             geogram_model_tdongle_s3 geogram_st7735 geogram_tdongle_ui
             geogram_wifi geogram_aprsis geogram_blemesh geogram_sdcard
             geogram_lanwatch geogram_xprs geogram_xprsindex geogram_xprslan geogram_xprsbearer geogram_xprsnow geogram_xprsid geogram_xprschan geogram_rns geogram_xprssig geogram_nostr
             esp_http_server
)
