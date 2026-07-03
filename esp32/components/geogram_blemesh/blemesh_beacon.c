/* Route-beacon codec — wire-compatible with aurora mesh_beacon.dart. */
#include "blemesh.h"

#include <ctype.h>
#include <string.h>

#include "mbedtls/sha256.h"

uint8_t blemesh_uptime_bucket(uint32_t s)
{
    uint32_t m = s / 60;
    if (m < 10) return 0;
    if (m < 30) return 1;
    if (m < 60) return 2;
    if (m < 180) return 3;
    if (m < 720) return 4;
    if (m < 1440) return 5;
    if (m < 4320) return 6;
    return 7;
}

void blemesh_hash(const char *callsign, uint8_t out[3])
{
    char up[BLEMESH_CALLSIGN_MAX + 1];
    int n = 0;
    /* UPPERCASE + trim, exactly like the phone's meshHash(). */
    while (callsign[n] && n < BLEMESH_CALLSIGN_MAX) {
        up[n] = (char)toupper((unsigned char)callsign[n]);
        n++;
    }
    up[n] = 0;
    uint8_t d[32];
    mbedtls_sha256((const unsigned char *)up, (size_t)n, d, 0);
    memcpy(out, d, 3);
}

static uint8_t cond_byte(const blemesh_beacon_t *b)
{
    return (uint8_t)((b->powered ? 1 : 0) |
                     ((b->uptime_bucket & 7) << 1) |
                     ((b->mobility & 3) << 4) |
                     ((b->storage_bucket & 3) << 6));
}

int blemesh_beacon_encode(const blemesh_beacon_t *b, uint8_t *out, int cap)
{
    int cs = (int)strlen(b->callsign);
    if (cs > BLEMESH_CALLSIGN_MAX) cs = BLEMESH_CALLSIGN_MAX;
    /* Header + callsign + count + bloom-len + pending trailer must fit;
     * dv entries fill the rest. */
    int fixed = 4 + cs + 1 + 1 + 2;
    if (cap < fixed) return 0;
    int room = (cap - fixed) / 4;
    int k = b->dv_count;
    if (k > room) k = room;               /* trim (freshest were placed first) */
    if (k > (int)(sizeof(b->dv) / sizeof(b->dv[0]))) k = sizeof(b->dv) / sizeof(b->dv[0]);

    int n = 0;
    out[n++] = BLEMESH_VER;
    out[n++] = b->dev_class;
    out[n++] = cond_byte(b);
    out[n++] = (uint8_t)cs;
    for (int i = 0; i < cs; i++) out[n++] = (uint8_t)toupper((unsigned char)b->callsign[i]);
    out[n++] = (uint8_t)k;
    for (int i = 0; i < k; i++) {
        memcpy(out + n, b->dv[i].hash, 3); n += 3;
        uint8_t c = b->dv[i].cost;
        out[n++] = (c < 1) ? 1 : (c > BLEMESH_MAX_COST ? BLEMESH_MAX_COST : c);
    }
    out[n++] = 0;                          /* have-digest bloom: none (carrier) */
    out[n++] = b->pending_msgs;            /* M2 trailer: parked mail count */
    out[n++] = b->pending_bulk;            /* M2 trailer: spooled files count */
    return n;
}

bool blemesh_beacon_decode(const uint8_t *d, int len, blemesh_beacon_t *out)
{
    memset(out, 0, sizeof(*out));
    if (len < 6 || d[0] != BLEMESH_VER) return false;
    out->dev_class = d[1];
    uint8_t cond = d[2];
    out->powered = (cond & 1) != 0;
    out->uptime_bucket = (cond >> 1) & 7;
    out->mobility = (cond >> 4) & 3;
    out->storage_bucket = (cond >> 6) & 3;
    int cs = d[3];
    if (cs > BLEMESH_CALLSIGN_MAX || len < 4 + cs + 1) return false;
    memcpy(out->callsign, d + 4, cs);
    out->callsign[cs] = 0;
    int o = 4 + cs;
    int k = d[o++];
    if (len < o + k * 4 + 1) return false;
    int stored = 0;
    for (int i = 0; i < k; i++) {
        uint8_t cost = d[o + 3];
        if (cost >= 1 && cost <= BLEMESH_MAX_COST &&
            stored < (int)(sizeof(out->dv) / sizeof(out->dv[0]))) {
            memcpy(out->dv[stored].hash, d + o, 3);
            out->dv[stored].cost = cost;
            stored++;
        }
        o += 4;
    }
    out->dv_count = (uint8_t)stored;
    /* bloom (d[o] length + bytes) intentionally ignored for now */
    return true;
}
