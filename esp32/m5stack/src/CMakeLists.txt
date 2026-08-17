idf_component_register(
    SRCS "main.c"
    INCLUDE_DIRS "."
    REQUIRES nvs_flash log esp_timer esp_hw_support esp_wifi esp_event
             esp_netif lwip
             geogram_xprs geogram_xprsbearer geogram_xprsnow geogram_xprslan)
