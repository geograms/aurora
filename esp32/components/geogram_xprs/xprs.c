/*
 * XPRS wire format — C mirror of lib/services/xprs (Dart). See xprs.h.
 *
 * The parse loop below reproduces XprsPacket.parse decision-for-decision.
 * Two rules are load-bearing and easy to lose in a rewrite:
 *   1. `m:` is recognised AT A TOKEN START and swallows the rest of the
 *      packet, spaces and colons included. Nothing after it is a field.
 *   2. A malformed token (no colon, colon first, bad key) is SKIPPED, never
 *      fatal — design rule 8. The only non-XPRS outcome is no leading `t:`.
 * Byte scanning is exact here: 0x20 and 0x3A never occur inside a multibyte
 * UTF-8 sequence, so byte offsets and Dart's string offsets agree, and the
 * identifier hashes the same UTF-8 bytes on both sides.
 */
#include "xprs.h"

#include <string.h>

static bool key_ok(const char *k, int n)
{
    if (n < 1 || n > 8) return false;
    if (!(k[0] >= 'a' && k[0] <= 'z')) return false;
    for (int i = 1; i < n; i++) {
        char c = k[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))) return false;
    }
    return true;
}

bool xprs_looks_like(const uint8_t *wire, int len)
{
    if (len < 2 || wire[0] != 't' || wire[1] != ':') return false;
    return memchr(wire, 0x1F, len) == NULL;
}

bool xprs_parse(const char *wire, int len, xprs_t *out)
{
    out->n = 0;
    if (len < 2 || len > XPRS_MAX_WIRE) return false;
    if (wire[0] != 't' || wire[1] != ':') return false;

    int i = 0;
    while (i < len) {
        /* m: at a token start: the value runs to the end of the packet. */
        if (i + 2 <= len && wire[i] == 'm' && wire[i + 1] == ':') {
            if (out->n >= XPRS_MAX_FIELDS) return false;
            xprs_field_t *f = &out->f[out->n++];
            f->key = wire + i; f->klen = 1;
            f->val = wire + i + 2; f->vlen = (uint16_t)(len - i - 2);
            break;
        }
        int end = i;
        while (end < len && wire[end] != ' ') end++;
        const char *tok = wire + i;
        int tlen = end - i;
        i = end + 1;

        int colon = -1;
        for (int k = 0; k < tlen; k++)
            if (tok[k] == ':') { colon = k; break; }
        if (colon <= 0) continue;              /* not a field; keep reading */
        if (!key_ok(tok, colon)) continue;
        if (out->n >= XPRS_MAX_FIELDS) return false;   /* see xprs.h */
        xprs_field_t *f = &out->f[out->n++];
        f->key = tok; f->klen = (uint16_t)colon;
        f->val = tok + colon + 1; f->vlen = (uint16_t)(tlen - colon - 1);
    }

    if (out->n == 0) return false;
    if (!(out->f[0].klen == 1 && out->f[0].key[0] == 't')) return false;
    return true;
}

static bool key_is(const xprs_field_t *f, const char *key)
{
    return f->klen == strlen(key) && memcmp(f->key, key, f->klen) == 0;
}

const char *xprs_get(const xprs_t *p, const char *key, int *vlen)
{
    for (int i = 0; i < p->n; i++) {
        if (key_is(&p->f[i], key)) {
            if (vlen) *vlen = p->f[i].vlen;
            return p->f[i].val;
        }
    }
    if (vlen) *vlen = 0;
    return NULL;
}

bool xprs_get_str(const xprs_t *p, const char *key, char *out, int cap)
{
    int vl = 0;
    const char *v = xprs_get(p, key, &vl);
    if (!v) { if (cap > 0) out[0] = 0; return false; }
    if (vl > cap - 1) vl = cap - 1;
    memcpy(out, v, vl);
    out[vl] = 0;
    return true;
}

void xprs_type(const xprs_t *p, char *out, int cap)
{
    int vl = p->f[0].vlen;
    if (vl > cap - 1) vl = cap - 1;
    memcpy(out, p->f[0].val, vl);
    out[vl] = 0;
}

/* Encode [p], skipping fields for which skip() says so, optionally replacing
 * the first [rep_key] field's value with [rep_val] (or inserting a new field
 * before m: when [rep_key] is absent). The single writer under encode, id and
 * append_via, so there is exactly one canonical form. Returns length or -1. */
static int encode_ex(const xprs_t *p, bool skip_sig_via,
                     const char *rep_key, const char *rep_val,
                     char *out, int cap)
{
    int n = 0;
    bool replaced = false;
    int rep_klen = rep_key ? (int)strlen(rep_key) : 0;
    int rep_vlen = rep_val ? (int)strlen(rep_val) : 0;

    for (int i = 0; i < p->n; i++) {
        const xprs_field_t *f = &p->f[i];
        if (skip_sig_via && (key_is(f, "sig") || key_is(f, "via"))) continue;

        /* A new field is inserted BEFORE m:, which must stay last or
         * everything after it reads as message text (XprsPacket.with_). */
        if (rep_key && !replaced && key_is(f, "m") &&
            !(f->klen == (uint16_t)rep_klen &&
              memcmp(f->key, rep_key, rep_klen) == 0)) {
            bool present = false;
            for (int j = i; j < p->n; j++)
                if (key_is(&p->f[j], rep_key)) { present = true; break; }
            if (!present) {
                if (n + (n ? 1 : 0) + rep_klen + 1 + rep_vlen > cap - 1) return -1;
                if (n) out[n++] = ' ';
                memcpy(out + n, rep_key, rep_klen); n += rep_klen;
                out[n++] = ':';
                memcpy(out + n, rep_val, rep_vlen); n += rep_vlen;
                replaced = true;
            }
        }

        const char *v = f->val;
        int vl = f->vlen;
        if (rep_key && !replaced && f->klen == (uint16_t)rep_klen &&
            memcmp(f->key, rep_key, rep_klen) == 0) {
            v = rep_val; vl = rep_vlen;
            replaced = true;
        }
        if (n + (n ? 1 : 0) + f->klen + 1 + vl > cap - 1) return -1;
        if (n) out[n++] = ' ';
        memcpy(out + n, f->key, f->klen); n += f->klen;
        out[n++] = ':';
        memcpy(out + n, v, vl); n += vl;
    }
    /* No m: and the key was new: append at the end (with_'s at<0 branch). */
    if (rep_key && !replaced) {
        if (n + (n ? 1 : 0) + rep_klen + 1 + rep_vlen > cap - 1) return -1;
        if (n) out[n++] = ' ';
        memcpy(out + n, rep_key, rep_klen); n += rep_klen;
        out[n++] = ':';
        memcpy(out + n, rep_val, rep_vlen); n += rep_vlen;
    }
    out[n] = 0;
    return n;
}

int xprs_encode(const xprs_t *p, char *out, int cap)
{
    return encode_ex(p, false, NULL, NULL, out, cap);
}

void xprs_id(const xprs_t *p, char id[XPRS_ID_LEN])
{
    /* sig: and via: come out before hashing (section 5): one is applied after
     * the packet exists, the other grows at every hop, and the identity must
     * survive both. */
    char buf[XPRS_MAX_WIRE + 1];
    int n = encode_ex(p, true, NULL, NULL, buf, sizeof buf);
    if (n < 0) n = 0;                     /* cannot happen: strip only shrinks */
    uint8_t h[32];
    xprs_sha256((const uint8_t *)buf, (size_t)n, h);
    static const char *hex = "0123456789abcdef";
    for (int i = 0; i < 3; i++) {
        id[i * 2]     = hex[h[i] >> 4];
        id[i * 2 + 1] = hex[h[i] & 0xF];
    }
    id[6] = 0;
}

int xprs_signed_text(const xprs_t *p, char *out, int cap)
{
    return encode_ex(p, true, NULL, NULL, out, cap);
}

bool xprs_id_of(const char *wire, int len, char id[XPRS_ID_LEN])
{
    xprs_t p;
    if (!xprs_parse(wire, len, &p)) return false;
    xprs_id(&p, id);
    return true;
}

/* ---- transport vocabulary ------------------------------------------------ */

int xprs_urg(const xprs_t *p)
{
    int vl = 0;
    const char *v = xprs_get(p, "urg", &vl);
    if (!v) return XPRS_URG_NORMAL;
    if (vl == 3 && memcmp(v, "low", 3) == 0) return XPRS_URG_LOW;
    if (vl == 4 && memcmp(v, "high", 4) == 0) return XPRS_URG_HIGH;
    if (vl == 6 && memcmp(v, "urgent", 6) == 0) return XPRS_URG_URGENT;
    return XPRS_URG_NORMAL;   /* unknown word: skip, don't fail (rule 8) */
}

int xprs_relay_limit(const xprs_t *p)
{
    const xprs_field_t *t = &p->f[0];
    if ((t->vlen == 3 && memcmp(t->val, "sos", 3) == 0) ||
        (t->vlen == 7 && memcmp(t->val, "warning", 7) == 0))
        return 9;
    return 3;
}

int xprs_via_count(const xprs_t *p)
{
    int vl = 0;
    const char *v = xprs_get(p, "via", &vl);
    if (!v || vl == 0) return 0;
    /* Count non-empty comma-separated entries (xprsVia filters empties). */
    int n = 0, run = 0;
    for (int i = 0; i < vl; i++) {
        if (v[i] == ',') { if (run) n++; run = 0; }
        else run++;
    }
    if (run) n++;
    return n;
}

static char upc(char c) { return (c >= 'a' && c <= 'z') ? (char)(c - 32) : c; }

bool xprs_via_contains(const xprs_t *p, const char *self)
{
    int vl = 0;
    const char *v = xprs_get(p, "via", &vl);
    if (!v || !self || !self[0]) return false;
    int slen = (int)strlen(self);
    int start = 0;
    for (int i = 0; i <= vl; i++) {
        if (i == vl || v[i] == ',') {
            int n = i - start;
            if (n == slen) {
                bool eq = true;
                for (int k = 0; k < n; k++)
                    if (upc(v[start + k]) != upc(self[k])) { eq = false; break; }
                if (eq) return true;
            }
            start = i + 1;
        }
    }
    return false;
}

bool xprs_scope_local(const xprs_t *p)
{
    int vl = 0;
    const char *v = xprs_get(p, "scope", &vl);
    return v && vl == 5 && memcmp(v, "local", 5) == 0;
}

bool xprs_is_station(const char *addr, int len)
{
    if (len <= 0) return false;
    if (len >= 2 && upc(addr[0]) == 'X' && addr[1] == '5') return false;
    for (int i = 0; i < len; i++)
        if (addr[i] >= '0' && addr[i] <= '9') return true;
    return false;
}

int xprs_append_via(const char *wire, int len, const char *self,
                    char *out, int cap)
{
    xprs_t p;
    if (!xprs_parse(wire, len, &p)) return -1;
    if (xprs_via_contains(&p, self)) return -1;          /* loop (13.2) */
    if (xprs_via_count(&p) >= xprs_relay_limit(&p)) return -1; /* spent (13.1) */

    /* New via value: old path + ",SELF" (uppercased), or SELF alone. A path
     * is at most 9 callsigns of <=9 chars, so 128 covers it with slack. */
    char nv[128];
    int vl = 0;
    const char *v = xprs_get(&p, "via", &vl);
    int n = 0;
    if (v && vl > 0) {
        if (vl > (int)sizeof(nv) - 2) return -1;
        memcpy(nv, v, vl); n = vl;
        nv[n++] = ',';
    }
    for (const char *s = self; *s && n < (int)sizeof(nv) - 1; s++)
        nv[n++] = upc(*s);
    nv[n] = 0;

    return encode_ex(&p, false, "via", nv, out, cap);
}
