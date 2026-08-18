/**
 * @file xprschan.h
 * @brief Meeting on a working channel — `docs/XPRS.md` §23.7.
 *
 * Radio settled this long ago: everyone monitors a calling channel, and a pair
 * with real business moves off it. This is that move.
 *
 * A device listens to ONE channel at a time, which is the whole reason the
 * sequence is exact — a step out of order strands somebody on a channel nobody
 * else is tuned to. §23.7 numbers six of them and this file implements them
 * literally:
 *
 *   1. invite on the commons, and keep listening there
 *   2. accept on the commons — the acceptance is the commitment
 *   3. move: the inviter on HEARING the acceptance, the invitee on SENDING it
 *   4. the invitee re-airs the SAME signed acceptance on the working channel;
 *      hearing it there is proof it cannot fake from anywhere else
 *   5. work, then give the channel back at `until:` or when done
 *   6. nobody came: the inviter goes home and says nothing
 *
 * ── What moving costs, and why there is a watchdog ──────────────────────────
 *
 * On a station associated to an access point, changing channel ends that
 * association: the iGate, the Reticulum hub and the clock all stop. §23.7 says
 * that is fine and the network treats it as ordinary absence — but only because
 * the station COMES BACK. A bug that fails to return does not degrade the
 * station, it removes it until somebody power-cycles it.
 *
 * So the deadline is local, in milliseconds, taken at the moment of the move,
 * and it is not negotiable: `until:` informs it and can only ever shorten it.
 * A packet cannot talk this station into staying away, and a station with no
 * clock still comes home.
 *
 * ── Who is followed ─────────────────────────────────────────────────────────
 *
 * §23.7: "an unsigned invitation is not followed" — "meet me elsewhere" is the
 * cheapest lure there is, and it takes the recipient off the shared channel.
 * This goes one step further and follows only an invitation whose signature
 * VERIFIES against a key this station already holds. A stranger asking us to
 * leave the commons is ignored, because there is nothing to weigh their word
 * against.
 */

#ifndef GEOGRAM_XPRSCHAN_H
#define GEOGRAM_XPRSCHAN_H

#include <stdint.h>
#include <stdbool.h>

#include "xprs.h"

#ifdef XPRSCHAN_HOST_TEST
typedef int esp_err_t;
#else
#include "esp_err.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/** How long an invitation stays worth answering if nobody does (§23.7 step 2). */
#define XC_INVITE_FRESH_MS   20000u

/** The longest a station will ever be away, whatever `until:` claims. */
#define XC_MAX_AWAY_MS       45000u

/** Default stay when there is no usable clock to read `until:` against. */
#define XC_DEFAULT_AWAY_MS   30000u

/**
 * How long the inviter waits alone before concluding nobody came (step 6).
 *
 * Eight seconds was too tight to be a judgement about the far side. Both
 * stations reach the working channel by their own route, and the inviter's
 * route includes letting go of an access point on a schedule the WiFi driver
 * owns — measured, the proof arrived between one and five seconds after the
 * move when it arrived at all, so eight seconds was declaring absence on a
 * margin of three. Fifteen is comfortably inside XC_MAX_AWAY_MS and costs
 * nothing when the far side is prompt, because hearing the proof ends the wait
 * immediately.
 */
#define XC_PROOF_WAIT_MS     15000u

/** How often the invitee repeats its step-4 proof on the working channel.
 *  Once is not enough: both stations arrive by their own route and neither
 *  controls when the other is listening. */
#define XC_ANNOUNCE_EVERY_MS 1000u

/** The hurried cadence for the first moments on the working channel, and how
 *  long it lasts. The two stations do not arrive together — the inviter has an
 *  access point to let go of first — so a second of silence right after
 *  arriving is the most expensive second of the whole exchange. */
#define XC_ANNOUNCE_FAST_MS  300u
#define XC_ARRIVAL_HURRY_MS  6000u

/**
 * How often the inviter re-airs the SAME invitation while waiting (step 1).
 *
 * A single packet asking somebody to leave the commons either lands or the
 * whole exchange is over, and measured it landed about one time in four. The
 * bytes are identical every time, so the §5 identifier is too and an answer's
 * `r:` still names something we recognise — a repeat costs one small packet and
 * buys another independent chance at a moment when the far side is listening.
 */
#define XC_INVITE_RETRY_MS   2000u

typedef enum {
    XC_IDLE = 0,
    XC_INVITED,     /* we invited; listening on the commons for an answer */
    XC_WORKING,     /* on the working channel */
} xc_state_t;

/** What the firmware lends this component. */
typedef struct {
    /** Sign in place (§9.1). Returns the new length, or the old one. */
    int  (*sign)(char *wire, int len, int cap);
    /** Verify against a key we hold. False for unsigned, unknown or forged. */
    bool (*verified)(const xprs_t *p);
    /** Put one packet on the bearer in use — the same one either side of the
     *  move, because the working channel is still ESP-NOW. */
    bool (*air)(const char *wire, int len);
    uint32_t (*now_ms)(void);
    /** `ts:...` or `epoch:...` for a station with no clock (§4.3). */
    void (*time_field)(char *out, int cap);
    /** Wall clock as epoch seconds, or 0 when this station has no idea. */
    uint32_t (*epoch)(void);
    /** Hold or release the station's automatic WiFi reconnect. Leaving the
     *  access point's channel looks exactly like a dropped link, and a station
     *  that reconnects on its own is back home before the far side arrives —
     *  measured doing exactly that. NULL when nothing reconnects. */
    void (*hold_reconnect)(bool hold);
    /** Air this station's `t:identity` (§9.3) right now, if it has a key.
     *
     * Called immediately before an invitation. §23.7 follows only a signed
     * invitation, and this one goes further and wants it VERIFIED — so an
     * invitation to a station that has not yet heard our key is an invitation
     * nobody can act on. A station that has just booted would otherwise wait a
     * whole identity period to be invitable. Introduce yourself first. */
    void (*announce_identity)(void);
    /** Is this station willing to leave the commons at all? An indexer that is
     *  somebody's only uplink may reasonably answer no. */
    bool (*may_move)(void);
    /** Block until the bearer has actually transmitted everything handed to it.
     *
     * Airing is asynchronous on every bearer worth having, and this component
     * retunes the radio — so "sent" has to be a fact and not a delay somebody
     * guessed. False means the bearer is stuck, which is worth logging but not
     * worth abandoning the exchange over. NULL when the bearer cannot say. */
    bool (*settle)(uint32_t timeout_ms);
    /** Put this station's Bluetooth on or off the air.
     *
     * NOT an optimisation, and not optional on ESP32. Measured with one
     * variable at a time (esp32/espnow_probe, and the table in docs/espnow.md):
     * with the BLE controller running, a WiFi station that is NOT ASSOCIATED
     * receives nothing at all, while transmitting perfectly. Cancelling the
     * scan does not give the radio back and neither does the coexistence
     * preference; only taking the controller down does. An associated station
     * with the same controller up is fine, because association is what keeps
     * the WiFi side scheduled -- it has beacons it may not miss.
     *
     * Moving to a working channel means leaving the access point, so for the
     * length of the move this station cannot also be a Bluetooth station. The
     * absence is bounded by the same local deadline that guarantees the return.
     * NULL on a station with no Bluetooth to lose. */
    void (*bluetooth)(bool on);
    /** Ask the bearer to log every packet it hears, for the duration.
     *
     * The rendezvous is the one place where "the radio never heard it" and "it
     * was heard and refused" look identical from every counter this component
     * owns, and they need opposite fixes. On while an exchange is in hand, off
     * the rest of the time. NULL when the bearer has nothing to say. */
    void (*trace)(bool on);
    /** The channel is ours and the far side has proved it is here. */
    void (*on_working)(const char *peer, uint8_t channel, bool lr);
    /** Back on the calling channel, for whatever reason. */
    void (*on_home)(const char *peer, bool worked);
} xc_ops_t;

void xprschan_init(const char *callsign, const xc_ops_t *ops);

/**
 * @brief Ask to invite @p peer to a working channel (step 1).
 *
 * QUEUED, NOT DONE HERE. Composing an invitation signs it twice — the identity
 * that introduces us and the invitation itself — and a secp256k1 signature
 * wants several kilobytes of stack. Doing that on the caller's task overflowed
 * a 4 KB console and rebooted the board; the same mistake had already cost a
 * boot-time key reload on the 3.5 KB main task. So the work happens on whatever
 * task calls xprschan_tick(), which on this firmware is the one that signs
 * everything else and is sized for it.
 *
 * Returns false only for the reasons that can be judged instantly: busy, or
 * this station does not leave the commons. The airing itself is reported in the
 * log a moment later.
 *
 * @param seconds how long to hold the channel; clamped to XC_MAX_AWAY_MS
 * @param lr      use the long-range PHY there (250 kbps, ESP32-to-ESP32 only)
 * @return false when busy, or when this station will not move
 */
bool xprschan_invite(const char *peer, uint8_t channel, uint32_t seconds,
                     bool lr);

/**
 * @brief Offer every heard packet. Returns true when it was consumed as part
 *        of the choreography and the caller need do nothing else with it.
 */
bool xprschan_on_packet(const xprs_t *p, const char *wire, int len);

/** Drive the timers. Cheap; call it often. */
void xprschan_tick(void);

xc_state_t xprschan_state(void);
bool       xprschan_busy(void);

/** Come home now, whatever was happening. */
void xprschan_abort(const char *why);

#ifdef __cplusplus
}
#endif
#endif /* GEOGRAM_XPRSCHAN_H */
