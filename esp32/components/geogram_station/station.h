#ifndef GEOGRAM_STATION_H
#define GEOGRAM_STATION_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define STATION_VERSION "1.0.0"
#define STATION_MAX_CLIENTS 8
#define STATION_CALLSIGN_LEN 16
#define STATION_NICKNAME_LEN 32
#define STATION_PLATFORM_LEN 16
#define STATION_NAME_LEN 32
#define STATION_LOCATION_LEN 64
#define STATION_TIMEZONE_LEN 48

// Connected WebSocket client
typedef struct {
    int fd;                                 // Socket file descriptor (-1 if unused)
    char callsign[STATION_CALLSIGN_LEN];    // Client callsign
    char nickname[STATION_NICKNAME_LEN];    // Client nickname
    char platform[STATION_PLATFORM_LEN];    // Client platform (Android, iOS, Linux, etc.)
    uint32_t connected_at;                  // Connection timestamp (epoch seconds)
    uint32_t last_activity;                 // Last message timestamp
    bool authenticated;                     // True if HELLO completed
} station_client_t;

// Station state
typedef struct {
    char callsign[STATION_CALLSIGN_LEN];    // Station callsign (X3 + npub derived)
    char name[STATION_NAME_LEN];            // Station name
    char location[STATION_LOCATION_LEN];    // City, Country from geolocation
    char timezone[STATION_TIMEZONE_LEN];    // IANA timezone string
    double latitude;                        // GPS latitude from geolocation
    double longitude;                       // GPS longitude from geolocation
    uint32_t start_time;                    // Boot timestamp (epoch seconds)
    station_client_t clients[STATION_MAX_CLIENTS];
    uint8_t client_count;                   // Active client count
    bool initialized;
    bool has_location;                      // True if geolocation data is available
} station_state_t;

// Initialize station (generates NOSTR keys and X3 callsign)
void station_init(void);

// Get station state (singleton)
station_state_t *station_get_state(void);

// Get station callsign
const char *station_get_callsign(void);

// Get station uptime in seconds
uint32_t station_get_uptime(void);

// Get connected client count
uint8_t station_get_client_count(void);

// Update station location from geolocation data
void station_set_location(double latitude, double longitude,
                          const char *city, const char *country,
                          const char *timezone);

// Add a new client connection (returns client index or -1 if full)
int station_add_client(int fd);

// Remove a client by file descriptor
void station_remove_client(int fd);

// Find client by file descriptor (returns NULL if not found)
station_client_t *station_find_client(int fd);

// Find client by callsign (returns NULL if not found)
station_client_t *station_find_client_by_callsign(const char *callsign);

// Update client info after HELLO
void station_client_set_info(station_client_t *client, const char *callsign,
                             const char *nickname, const char *platform);

// Update client activity timestamp
void station_client_activity(station_client_t *client);

// Build status JSON into buffer
size_t station_build_status_json(char *buffer, size_t size);

// Build hello_ack JSON into buffer
size_t station_build_hello_ack_json(char *buffer, size_t size, bool success, const char *message);

// Build PONG JSON into buffer
size_t station_build_pong_json(char *buffer, size_t size);

// Iterate over authenticated clients (for broadcasting)
typedef void (*station_client_callback_t)(station_client_t *client, void *ctx);
void station_foreach_client(station_client_callback_t callback, void *ctx);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_STATION_H
