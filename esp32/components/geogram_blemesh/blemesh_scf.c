/* Store-and-forward custody queue (doc/mesh.md §6, dongle-sized).
 *
 * Parks heard 1:1 frames (raw 0x41 payloads) keyed by their am: receipt id,
 * purges them when an "?ACK <am>" receipt is overheard, and hands them back
 * for re-air when the target reappears. Optionally persists to a file (stdio,
 * so an SD card mounted on VFS works) and reloads on boot — a powered dongle
 * survives reboots without losing parked mail.
 *
 * File format: [u8 ver=1] then per entry
 *   [u8 target_len][target][u8 am_len][am][u32 ts][u16 frame_len][frame]
 * Rewritten whole on every mutation (small: <= 24 entries * ~260 B).
 */
#include "blemesh.h"

#include <stdio.h>
#include <string.h>

typedef struct {
    char     target[BLEMESH_CALLSIGN_MAX + 1];
    char     am[8];
    uint8_t  frame[BLEMESH_SCF_FRAME_MAX];
    uint16_t len;
    uint32_t ts;          /* park time (monotonic seconds) */
    uint32_t last_reair;  /* 0 = never re-aired */
    uint32_t chash;       /* content dedup when no am id */
} scf_t;

static scf_t s_scf[BLEMESH_SCF_MAX];
static int   s_scf_n;
static char  s_path[96];

static uint32_t fnv1a(const uint8_t *d, int n)
{
    uint32_t h = 2166136261u;
    for (int i = 0; i < n; i++) { h ^= d[i]; h *= 16777619u; }
    return h;
}

static void persist(void)
{
    if (!s_path[0]) return;
    FILE *f = fopen(s_path, "wb");
    if (!f) return;
    uint8_t ver = 1;
    fwrite(&ver, 1, 1, f);
    for (int i = 0; i < s_scf_n; i++) {
        scf_t *e = &s_scf[i];
        uint8_t tl = (uint8_t)strlen(e->target), al = (uint8_t)strlen(e->am);
        fwrite(&tl, 1, 1, f); fwrite(e->target, 1, tl, f);
        fwrite(&al, 1, 1, f); fwrite(e->am, 1, al, f);
        fwrite(&e->ts, 4, 1, f);
        uint16_t ln = e->len;
        fwrite(&ln, 2, 1, f);
        fwrite(e->frame, 1, ln, f);
    }
    fclose(f);
}

static void load(void)
{
    if (!s_path[0]) return;
    FILE *f = fopen(s_path, "rb");
    if (!f) return;
    uint8_t ver = 0;
    if (fread(&ver, 1, 1, f) != 1 || ver != 1) { fclose(f); return; }
    while (s_scf_n < BLEMESH_SCF_MAX) {
        scf_t *e = &s_scf[s_scf_n];
        memset(e, 0, sizeof(*e));
        uint8_t tl, al; uint16_t ln;
        if (fread(&tl, 1, 1, f) != 1 || tl > BLEMESH_CALLSIGN_MAX) break;
        if (fread(e->target, 1, tl, f) != tl) break;
        if (fread(&al, 1, 1, f) != 1 || al > 7) break;
        if (fread(e->am, 1, al, f) != al) break;
        if (fread(&e->ts, 4, 1, f) != 1) break;
        if (fread(&ln, 2, 1, f) != 1 || ln > BLEMESH_SCF_FRAME_MAX) break;
        if (fread(e->frame, 1, ln, f) != ln) break;
        e->len = ln;
        e->ts = 0;               /* clock restarted: age from boot */
        e->chash = fnv1a(e->frame, ln);
        s_scf_n++;
    }
    fclose(f);
}

void blemesh_scf_init(const char *persist_path)
{
    memset(s_scf, 0, sizeof(s_scf));
    s_scf_n = 0;
    s_path[0] = 0;
    if (persist_path && persist_path[0]) {
        strncpy(s_path, persist_path, sizeof(s_path) - 1);
        s_path[sizeof(s_path) - 1] = 0;
        load();
    }
}

bool blemesh_scf_offer(const char *target, const char *am,
                       const uint8_t *frame, int len, uint32_t now)
{
    if (!target || !target[0] || len <= 0 || len > BLEMESH_SCF_FRAME_MAX)
        return false;
    uint32_t ch = fnv1a(frame, len);
    for (int i = 0; i < s_scf_n; i++) {
        if (am && am[0] && strcmp(s_scf[i].am, am) == 0) return false;
        if (s_scf[i].chash == ch && s_scf[i].len == len) return false;
    }
    int slot;
    if (s_scf_n < BLEMESH_SCF_MAX) slot = s_scf_n++;
    else {
        slot = 0;                     /* evict oldest */
        for (int i = 1; i < s_scf_n; i++)
            if (s_scf[i].ts < s_scf[slot].ts) slot = i;
    }
    scf_t *e = &s_scf[slot];
    memset(e, 0, sizeof(*e));
    strncpy(e->target, target, BLEMESH_CALLSIGN_MAX);
    if (am) strncpy(e->am, am, 7);
    memcpy(e->frame, frame, len);
    e->len = (uint16_t)len;
    e->ts = now;
    e->chash = ch;
    persist();
    return true;
}

int blemesh_scf_ack(const char *am)
{
    if (!am || !am[0]) return 0;
    int purged = 0;
    for (int i = 0; i < s_scf_n;) {
        if (strcmp(s_scf[i].am, am) == 0) {
            s_scf[i] = s_scf[s_scf_n - 1];
            s_scf_n--;
            purged++;
        } else i++;
    }
    if (purged) persist();
    return purged;
}

int blemesh_scf_pop_for(const char *target, uint32_t now,
                        uint8_t out[][BLEMESH_SCF_FRAME_MAX], int *out_len,
                        int max)
{
    int n = 0;
    for (int i = 0; i < s_scf_n && n < max; i++) {
        scf_t *e = &s_scf[i];
        if (strcmp(e->target, target) != 0) continue;
        if (e->last_reair && now - e->last_reair < BLEMESH_SCF_REAIR_MIN_SEC)
            continue;
        memcpy(out[n], e->frame, e->len);
        out_len[n] = e->len;
        e->last_reair = now;
        n++;
    }
    return n;
}

void blemesh_scf_sweep(uint32_t now)
{
    bool changed = false;
    for (int i = 0; i < s_scf_n;) {
        if (now - s_scf[i].ts > BLEMESH_SCF_TTL_SEC) {
            s_scf[i] = s_scf[s_scf_n - 1];
            s_scf_n--;
            changed = true;
        } else i++;
    }
    if (changed) persist();
}

int blemesh_scf_count(void) { return s_scf_n; }
