# Reticulum codec — see rns.h. TweetNaCl (X25519) comes from the firmware that
# links this: rns_ble5/src/tweetnacl.c. test_rns_host.* are a HOST gcc harness
# (run test_rns_host.sh) and are never compiled into the firmware.
idf_component_register(
    SRCS "rns.c" "rns_tcp.c"
    INCLUDE_DIRS "."
    REQUIRES mbedtls esp_hw_support log lwip esp_timer)
