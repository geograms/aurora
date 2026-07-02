# BLE street-mesh core (aurora doc/mesh.md) — wire-compatible with the phones.
#
# Pure protocol logic: route-beacon codec (subtype 0x4D), neighbor + DV table,
# and the store-and-forward pending queue. NO radio, storage or UI code — the
# firmware wires those through callbacks/paths — so the same component runs on
# any ESP32 variant. (The BLE5 extended-advertising *transport* the mesh rides
# needs an S3/C3-class radio, but that dependency lives in the firmware.)
#
# Not to be confused with geogram_mesh (the old, disabled ESP-WIFI-MESH bridge).
idf_component_register(
    SRCS "blemesh_beacon.c" "blemesh_table.c" "blemesh_scf.c"
    INCLUDE_DIRS "."
    REQUIRES mbedtls log
)
