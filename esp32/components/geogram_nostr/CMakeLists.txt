idf_component_register(
    SRCS "nostr_keys.c" "bech32.c"
    INCLUDE_DIRS "."
    REQUIRES log nvs_flash mbedtls
)
