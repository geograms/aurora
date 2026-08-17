/**
 * @file rns.h
 * @brief Enough Reticulum for a station to reach an indexer.
 *
 * Wire-compatible with RNS 1.3.5 and with the `reticulum-dart` sibling package,
 * which is the implementation this one is tested against — the host harness
 * decrypts bytes that Dart produced and reproduces them byte for byte
 * (`test_rns_host.sh`). Crypto interop is where this kind of code fails
 * quietly, so it is pinned by vectors rather than by reading.
 *
 * ── What is here, and what deliberately is not ──────────────────────────────
 *
 * Here: identities and destination addressing, the HDLC framing a TCP
 * interface speaks, the packet header, and **encrypted single packets** —
 * ephemeral X25519 to the destination's public key, so a station can send to
 * another station without establishing anything first.
 *
 * Not here: LINK, ratchets, resources, transport/routing. A dongle that talks
 * to an indexer it already knows the address of needs none of them, and each
 * would cost memory this board does not have. If a link is ever needed, this
 * file is the layer it would sit on rather than something to unpick.
 *
 * ── The shapes ──────────────────────────────────────────────────────────────
 *
 *   private key   x25519_prv(32) || ed25519_prv(32)
 *   public key    x25519_pub(32) || ed25519_pub(32)
 *   identity hash SHA-256(public key)[:16]
 *   name hash     SHA-256("app.aspect1.aspect2")[:10]
 *   destination   SHA-256(name_hash || identity_hash)[:16]
 *   encrypted     eph_pub(32) || iv(16) || AES-256-CBC(PKCS7(plain)) || HMAC(32)
 */

#ifndef GEOGRAM_RNS_H
#define GEOGRAM_RNS_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RNS_KEY_HALF        32
#define RNS_PRV_LEN         64      /* x25519_prv || ed25519_prv */
#define RNS_PUB_LEN         64      /* x25519_pub || ed25519_pub */
#define RNS_HASH_LEN        16      /* identity and destination hashes */
#define RNS_NAME_HASH_LEN   10
#define RNS_IV_LEN          16
#define RNS_MAC_LEN         32
/** Smallest possible encrypted payload: eph pub + iv + one AES block + mac. */
#define RNS_ENC_OVERHEAD    (RNS_KEY_HALF + RNS_IV_LEN + RNS_MAC_LEN)

/** RNS default MTU (RNS/Reticulum.py). */
#define RNS_MTU             500

/* ── Primitives ─────────────────────────────────────────────────────────── */

void rns_sha256(const uint8_t *in, size_t len, uint8_t out[32]);
void rns_hmac_sha256(const uint8_t *key, size_t keylen,
                     const uint8_t *in, size_t len, uint8_t out[32]);

/**
 * @brief RNS's own HKDF (RNS/Cryptography/HKDF.py).
 *
 * Not RFC 5869: the expand step feeds back `block || context || counter` with
 * the counter taken modulo 256, and an absent salt is 32 zero bytes. Written
 * to match, because a key that is one byte different is a key that fails with
 * no message at the far end.
 */
bool rns_hkdf(uint8_t *out, size_t out_len,
              const uint8_t *ikm, size_t ikm_len,
              const uint8_t *salt, size_t salt_len);

/** X25519. [priv] is used as the scalar, as RNS does. */
void rns_x25519_base(const uint8_t priv[32], uint8_t pub_out[32]);
void rns_x25519_shared(const uint8_t priv[32], const uint8_t peer_pub[32],
                       uint8_t shared_out[32]);

/* ── Identity and addressing ────────────────────────────────────────────── */

typedef struct {
    uint8_t prv[RNS_PRV_LEN];       /* zeroed when this is a peer's identity */
    uint8_t pub[RNS_PUB_LEN];
    uint8_t hash[RNS_HASH_LEN];
    bool    have_private;
} rns_identity_t;

/**
 * @brief Set up an identity from the keys the caller already holds.
 *
 * @param prv 64 bytes, or NULL for a peer whose private key we do not have.
 *            The Ed25519 public half cannot be derived from a seed with the
 *            TweetNaCl this tree carries, so the full public key is passed in
 *            rather than half-derived and half-guessed.
 */
void rns_identity_init(const uint8_t *prv, const uint8_t pub[RNS_PUB_LEN],
                       rns_identity_t *out);
/** A peer, known only by its public key. */
void rns_identity_from_public(const uint8_t pub[RNS_PUB_LEN],
                              rns_identity_t *out);

/** SHA-256("app.aspect...")[:10]. Aspects are joined with '.'. */
void rns_name_hash(const char *app, const char *const *aspects, int naspects,
                   uint8_t out[RNS_NAME_HASH_LEN]);
/** SHA-256(name_hash || identity_hash)[:16] — what a packet is addressed to. */
void rns_destination_hash(const uint8_t name_hash[RNS_NAME_HASH_LEN],
                          const uint8_t identity_hash[RNS_HASH_LEN],
                          uint8_t out[RNS_HASH_LEN]);

/* ── Encrypted single packets ───────────────────────────────────────────── */

/**
 * @brief Encrypt to [peer], whose X25519 public half and destination hash are
 *        known. The hash is the HKDF salt, which is why it is a parameter and
 *        not derived here: it is the DESTINATION's hash, not the identity's.
 *
 * @param eph_priv  ephemeral X25519 private key — pass NULL for a random one.
 *                  Only tests pass it, and only so the bytes are reproducible.
 * @param iv        16 bytes, NULL for random. Same reasoning.
 * @return bytes written to @p out, or -1 if it would not fit.
 */
int rns_encrypt_to(const uint8_t peer_x25519_pub[32],
                   const uint8_t salt[RNS_HASH_LEN],
                   const uint8_t *plain, size_t plain_len,
                   const uint8_t *eph_priv, const uint8_t *iv,
                   uint8_t *out, size_t out_cap);

/**
 * @brief Decrypt what rns_encrypt_to() produced. Verifies the HMAC before
 *        touching the ciphertext, and refuses a bad one without explanation —
 *        there is nothing useful to say about a forgery.
 * @return plaintext length, or -1.
 */
int rns_decrypt_from(const uint8_t our_x25519_priv[32],
                     const uint8_t salt[RNS_HASH_LEN],
                     const uint8_t *in, size_t in_len,
                     uint8_t *out, size_t out_cap);

/* ── HDLC framing (what a TCP interface speaks) ─────────────────────────── */

#define RNS_HDLC_FLAG   0x7E
#define RNS_HDLC_ESC    0x7D
#define RNS_HDLC_MASK   0x20

/** Frame [in] as FLAG ... FLAG with escaping. Returns length or -1. */
int rns_hdlc_frame(const uint8_t *in, size_t len, uint8_t *out, size_t out_cap);

/**
 * @brief Feed received bytes; calls @p cb once per complete frame.
 *
 * A stream reassembler, because TCP gives no message boundaries: partial
 * frames are held across calls, and a frame longer than the buffer is dropped
 * rather than truncated into something that would parse as a shorter packet.
 */
typedef struct {
    uint8_t  buf[RNS_MTU + 64];
    size_t   len;
    bool     in_frame;
    bool     escaped;
    uint32_t dropped;          /* frames lost to overrun — worth logging */
} rns_hdlc_rx_t;

void rns_hdlc_rx_init(rns_hdlc_rx_t *rx);
void rns_hdlc_rx_feed(rns_hdlc_rx_t *rx, const uint8_t *in, size_t len,
                      void (*cb)(const uint8_t *frame, size_t len, void *ctx),
                      void *ctx);

/* ── Packet header ──────────────────────────────────────────────────────── */

#define RNS_PACKET_DATA        0x00
#define RNS_PACKET_ANNOUNCE    0x01
#define RNS_PACKET_LINKREQUEST 0x02
#define RNS_PACKET_PROOF       0x03

#define RNS_DEST_SINGLE        0x00
#define RNS_DEST_GROUP         0x01
#define RNS_DEST_PLAIN         0x02
#define RNS_DEST_LINK          0x03

#define RNS_HEADER_1           0x00
#define RNS_HEADER_2           0x01

#define RNS_TRANSPORT_BROADCAST 0x00
#define RNS_TRANSPORT_TRANSPORT 0x01

typedef struct {
    uint8_t  header_type;
    /* HEADER_2 only: the transport node that relayed it. Everything a hub
     * relays arrives this way, so a station that refuses HEADER_2 hears
     * nothing from the wider network — which is exactly what this one did
     * until a real hub was pointed at it. */
    uint8_t  transport_id[RNS_HASH_LEN];
    bool     have_transport_id;
    uint8_t  context_flag;
    uint8_t  transport_type;
    uint8_t  dest_type;
    uint8_t  packet_type;
    uint8_t  hops;
    uint8_t  dest[RNS_HASH_LEN];
    uint8_t  context;
    const uint8_t *data;
    size_t   data_len;
} rns_packet_t;

/**
 * @brief Build a HEADER_1 packet: flags(1) hops(1) dest(16) context(1) data.
 *
 * Only HEADER_1 is built: a leaf addresses a destination, it does not relay for
 * anybody, and HEADER_2 is what a transport node emits.
 * @return length, or -1.
 */
int rns_packet_build(const rns_packet_t *p, uint8_t *out, size_t out_cap);

/**
 * @brief Parse either header form. [out]->data points into [in].
 *
 * HEADER_2 carries a 16-byte transport id BEFORE the destination; read as
 * HEADER_1 its transport id would be taken for the address, which is a packet
 * silently attributed to the wrong destination.
 */
bool rns_packet_parse(const uint8_t *in, size_t len, rns_packet_t *out);

#ifdef __cplusplus
}
#endif
#endif /* GEOGRAM_RNS_H */
