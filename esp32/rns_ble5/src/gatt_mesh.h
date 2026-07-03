/*
 * gatt_mesh — MSP-over-GATT for the T-Dongle (mesh M2 data plane).
 *
 * The dongle becomes a GATT SERVER speaking the Mesh Session Protocol
 * (blemesh_session.h) on the same FFE0/FFF1/FFF2 channel the phones use:
 * a phone dials in (discovering us via a legacy connectable advert on
 * ext-adv instance 1), and the session moves message custody both ways
 * plus bulk files chunk-by-chunk, streamed to/from the SD card.
 *
 * Bulk spool on SD: /sdcard/mesh/bulk/<8-hex>.meta (key=value lines) +
 * .part (payload). Origin entries created by the console `sendfile` read
 * straight from their source path; inbound relay copies live as .part.
 */
#ifndef GATT_MESH_H
#define GATT_MESH_H

#include <stdbool.h>
#include <stdint.h>

/* Register the GATT service. MUST run before nimble_port_freertos_init. */
void gatt_mesh_svcs_init(void);

/* Start the connectable advert + session machinery (call from on_sync,
 * after the ext-adv address type is known). */
void gatt_mesh_start(const char *callsign, uint8_t own_addr_type);

/* Periodic drive (timeouts). Call ~1/s from any task. */
void gatt_mesh_tick(void);

/* Files waiting in the bulk spool (beacon pending trailer). */
int gatt_mesh_bulk_pending(void);

/* Console: queue a file for mesh delivery. Returns 0 on success. */
int gatt_mesh_sendfile(const char *to, const char *path);

/* Console: print spool + session status to stdout. */
void gatt_mesh_print_status(void);

#endif /* GATT_MESH_H */
