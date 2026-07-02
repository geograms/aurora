/* Neighbor + distance-vector table — mirrors aurora mesh_table.dart:
 * bidirectional-confirmed next-hops, 6-hop cap, aging, DV export. */
#include "blemesh.h"

#include <string.h>

static char    s_self[BLEMESH_CALLSIGN_MAX + 1];
static uint8_t s_self_hash[3];

static blemesh_neighbor_t s_neigh[BLEMESH_NEIGH_MAX];
static int s_neigh_n;

/* Each neighbor's advertised digest, kept to answer the bidirectional check
 * and to learn routes. Parallel to s_neigh by index. */
typedef struct { blemesh_dv_t dv[48]; uint8_t n; } digest_t;
static digest_t s_digest[BLEMESH_NEIGH_MAX];

static blemesh_route_t s_route[BLEMESH_ROUTE_MAX];
static int s_route_n;

void blemesh_table_init(const char *self_callsign)
{
    memset(s_neigh, 0, sizeof(s_neigh));
    memset(s_route, 0, sizeof(s_route));
    s_neigh_n = s_route_n = 0;
    strncpy(s_self, self_callsign, BLEMESH_CALLSIGN_MAX);
    s_self[BLEMESH_CALLSIGN_MAX] = 0;
    blemesh_hash(s_self, s_self_hash);
}

static int neigh_find(const char *cs)
{
    for (int i = 0; i < s_neigh_n; i++)
        if (strcmp(s_neigh[i].callsign, cs) == 0) return i;
    return -1;
}

static int route_find(const uint8_t hash[3])
{
    for (int i = 0; i < s_route_n; i++)
        if (memcmp(s_route[i].hash, hash, 3) == 0) return i;
    return -1;
}

bool blemesh_table_ingest(const blemesh_beacon_t *b, int rssi, uint32_t now)
{
    if (!b->callsign[0] || strcmp(b->callsign, s_self) == 0) return false;
    bool changed = false;

    int i = neigh_find(b->callsign);
    if (i < 0) {
        /* New neighbor: take a free slot or evict the stalest. */
        if (s_neigh_n < BLEMESH_NEIGH_MAX) {
            i = s_neigh_n++;
        } else {
            i = 0;
            for (int k = 1; k < s_neigh_n; k++)
                if (s_neigh[k].last_heard < s_neigh[i].last_heard) i = k;
        }
        memset(&s_neigh[i], 0, sizeof(s_neigh[i]));
        memset(&s_digest[i], 0, sizeof(s_digest[i]));
        strncpy(s_neigh[i].callsign, b->callsign, BLEMESH_CALLSIGN_MAX);
        blemesh_hash(b->callsign, s_neigh[i].hash);
        changed = true;
    }
    blemesh_neighbor_t *n = &s_neigh[i];
    n->dev_class = b->dev_class;
    n->cond = (uint8_t)((b->powered ? 1 : 0) | ((b->uptime_bucket & 7) << 1) |
                        ((b->mobility & 3) << 4) | ((b->storage_bucket & 3) << 6));
    n->rssi = (int8_t)rssi;
    n->last_heard = now;
    n->beacons++;
    n->reach = b->dv_count;

    /* Its digest: does it list US at cost 1 (bidirectional confirmation)? */
    bool sees_us = false;
    digest_t *dg = &s_digest[i];
    dg->n = 0;
    for (int k = 0; k < b->dv_count && dg->n < 48; k++) {
        dg->dv[dg->n++] = b->dv[k];
        if (b->dv[k].cost == 1 && memcmp(b->dv[k].hash, s_self_hash, 3) == 0)
            sees_us = true;
    }
    if (n->bidirectional != sees_us) { n->bidirectional = sees_us; changed = true; }

    /* DV learn — only through a bidirectionally-confirmed neighbor. */
    if (sees_us) {
        for (int k = 0; k < dg->n; k++) {
            if (memcmp(dg->dv[k].hash, s_self_hash, 3) == 0) continue;
            int cost = dg->dv[k].cost + 1;
            if (cost > BLEMESH_MAX_COST) continue;
            int r = route_find(dg->dv[k].hash);
            if (r < 0) {
                if (s_route_n < BLEMESH_ROUTE_MAX) r = s_route_n++;
                else {
                    r = 0;
                    for (int m = 1; m < s_route_n; m++)
                        if (s_route[m].updated < s_route[r].updated) r = m;
                }
                memcpy(s_route[r].hash, dg->dv[k].hash, 3);
                s_route[r].cost = 0xff;
            }
            if (cost < s_route[r].cost ||
                strcmp(s_route[r].via, b->callsign) == 0) {
                if (cost < s_route[r].cost) changed = true;
                s_route[r].cost = (uint8_t)cost;
                strncpy(s_route[r].via, b->callsign, BLEMESH_CALLSIGN_MAX);
                s_route[r].updated = now;
            }
        }
    }
    return changed;
}

void blemesh_table_sweep(uint32_t now)
{
    for (int i = 0; i < s_neigh_n;) {
        if (now - s_neigh[i].last_heard > BLEMESH_NEIGH_TTL) {
            s_neigh[i] = s_neigh[s_neigh_n - 1];
            s_digest[i] = s_digest[s_neigh_n - 1];
            s_neigh_n--;
        } else i++;
    }
    for (int i = 0; i < s_route_n;) {
        bool via_alive = neigh_find(s_route[i].via) >= 0;
        if (!via_alive || now - s_route[i].updated > BLEMESH_NEIGH_TTL) {
            s_route[i] = s_route[s_route_n - 1];
            s_route_n--;
        } else i++;
    }
}

int blemesh_table_export(blemesh_dv_t *out, int max)
{
    int n = 0;
    /* Direct neighbors at cost 1 first — they carry the bidirectional signal. */
    for (int i = 0; i < s_neigh_n && n < max; i++) {
        memcpy(out[n].hash, s_neigh[i].hash, 3);
        out[n].cost = 1;
        n++;
    }
    /* Then learned routes (skip anything already present / over the cap). */
    for (int i = 0; i < s_route_n && n < max; i++) {
        if (s_route[i].cost >= BLEMESH_MAX_COST) continue;
        bool dup = false;
        for (int k = 0; k < n && !dup; k++)
            if (memcmp(out[k].hash, s_route[i].hash, 3) == 0) dup = true;
        if (dup) continue;
        memcpy(out[n].hash, s_route[i].hash, 3);
        out[n].cost = s_route[i].cost;
        n++;
    }
    return n;
}

int blemesh_neighbor_count(void) { return s_neigh_n; }
const blemesh_neighbor_t *blemesh_neighbor_at(int i)
{
    return (i >= 0 && i < s_neigh_n) ? &s_neigh[i] : 0;
}
int blemesh_route_count(void) { return s_route_n; }

bool blemesh_reachable(const char *callsign)
{
    if (neigh_find(callsign) >= 0) return true;
    uint8_t h[3];
    blemesh_hash(callsign, h);
    return route_find(h) >= 0;
}
