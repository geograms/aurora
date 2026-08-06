# Aurora architecture — what belongs where

This is the governing document. When another doc, a comment or a habit
disagrees with this one, this one wins.

It exists because the same two mistakes keep being made, by people and by
assistants, months apart:

1. **Transport logic drifting into a wapp.** Store-and-forward was first built
   inside `wapps/chat/main.c` (`bh_arm`/`bh_pump`/`best_hope_wire`). It worked,
   and it was still wrong: every other wapp had no offline delivery at all, and
   the wapp needed HAL endpoints invented purely so it could guess at
   reachability.
2. **Work landing on the UI isolate.** Reticulum crypto and transport used to
   run on the main isolate; the app froze under load. They were moved out (see
   [performance.md](performance.md)), and the pull to move them back is
   constant, because calling a service directly is always the shortest patch.

Both are invisible in review — the feature works — and expensive later. So they
are now **machine-checked**: see [§5](#5-enforcement).

---

## 1. The layers

```
   ┌────────────────────────────────────────────────────────────────┐
   │ wapps (.wapp, WASM)          chat · social · files · torrents  │
   │   presentation + domain rules for ONE application               │
   │   talks only to hal_* ; owns no radio, no key, no store         │
   └───────────────▲───────────────────────────┬────────────────────┘
                   │ events in                 │ hal_* calls out
   ┌───────────────┴───────────────────────────▼────────────────────┐
   │ core (lib/)                                                    │
   │   identity + keys      profiles, nsec, signing, encryption      │
   │   transports           Reticulum, BLE5, LAN, WiFi-Direct, I2P   │
   │   delivery             LXMF, MeshCourier, custody, retries      │
   │   storage              sqlite, media archive, folders, spool    │
   └────────────────────────────────────────────────────────────────┘
```

**A wapp is an event-driven consumer.** It hands the core a message and is
called back when one arrives. It never learns which radio carried it, whether a
stranger held it for ten minutes, or how many times it was retried.

### What this means in practice

| Question | Answer | Lives in |
|---|---|---|
| Should this message go over BLE, Reticulum, or both? | core decides | `lib/services/` |
| Is the recipient reachable? | core knows; a wapp must not ask | `RnsService`, `MeshService` |
| Who carries a message for an absent peer? | core | `MeshCourier`, `MeshStore` |
| What does a message *mean* (a like, a room post, a room's moderation rules)? | wapp | `wapps/<name>/` |
| How is a conversation drawn? | wapp | `wapps/<name>/` |
| Which key signs/encrypts? | core (a wapp asks, never holds) | `hal_identity_sign`, `hal_encrypt` |

### The smell test

> If a wapp needs a new `hal_*` endpoint in order to make a *transport
> decision*, the logic is on the wrong side of the line.

`hal_encrypt` is fine — the wapp asks the core to do a thing with a key it does
not hold. `hal_lxmf_pending` + `hal_rns_has_path`, added so a wapp could decide
whether to air a copy, were the symptom that led to this document. They survive
only as read-only diagnostics.

---

## 2. Isolates: what may run where

Measured layout and rationale: [performance.md](performance.md).

| Isolate | Runs | Never runs |
|---|---|---|
| **main / UI** | widgets, `setState`, wapp page engines, MethodChannel calls | crypto over big buffers, sqlite scans, file hashing, blocking I/O, busy loops |
| **rns-crypto** | Reticulum sign/verify/encrypt | UI, platform channels |
| **rns-transport** | packet routing, links, resources | UI, platform channels |
| **wapp background engines** | `module_tick` for background wapps | anything expecting a UI |

Two hard rules:

- **Platform channels are main-isolate only.** `Ble5Bus`, `MethodChannel`,
  plugin calls. A background isolate calling them fails silently or throws —
  which is why `MeshCourier` airs from the main isolate and does its heavy work
  (encryption) on payloads that are ~200 bytes.
- **Nothing blocking on the UI isolate.** No `*Sync` file I/O, no `sleep`, no
  unbounded loop in a widget or a service the UI awaits. If a job can take more
  than a few milliseconds, it belongs in an isolate or a `compute`.

---

## 3. Where a new feature goes

Ask in this order:

1. **Does it move bytes between devices?** → core. Always. Transports,
   retries, custody, encryption in transit, addressing.
2. **Does it need a key, the profile, or the databases?** → core, exposed to
   wapps through a narrow `hal_*` verb.
3. **Is it about what a message *means* to one application?** → wapp.
4. **Is it a screen?** → wapp (or `lib/ui/` when it is a core surface like
   Settings, the launcher, or the profile).

A generic core service must not know a wapp exists. If `lib/` grows a special
case for chat, that is the wrong shape: give the core a generic capability and
let the wapp use it. (`keep-host-generic`, and it is why `MeshCourier` carries
*payloads*, not "chat messages".)

---

## 4. Transports, concretely

Read [ble5.md](ble5.md) for how bytes actually leave the device, and
[store-and-forward.md](store-and-forward.md) for what happens when nobody is
listening. Short version:

- **Reticulum** is the primary transport everywhere. LXMF is the message layer.
- **BLE5 connectionless advertising** is the off-grid broadcast plane: small
  frames, one-to-many, no pairing.
- **GATT/MSP** is the bulk and custody plane: a transient link for things too
  big for an advert, and for handing parked mail to the peer it belongs to.
- **Store-and-forward** is a core service (`MeshCourier`), armed by the core on
  every 1:1 send, and it hands arrivals back through the ordinary LXMF inbox.

---

## 5. Enforcement

`tool/arch_guard.dart` checks the rules above on every push (`.github/workflows/
arch.yml`) and, if installed, on every commit.

```sh
dart tool/arch_guard.dart            # check (exit 1 on a new violation)
dart tool/arch_guard.dart --list     # every violation, including the baseline
dart tool/arch_guard.dart --baseline # re-record the baseline (deliberate act)
./tool/install-hooks.sh              # run it as a pre-commit hook
```

It is a **baseline** checker: the violations that already exist are recorded in
`tool/arch_baseline.txt` and do not fail the build; anything *new* does. That
keeps it honest — a guard that fails on day one gets disabled on day two.

The baseline is keyed on the **offending line**, not on the file: forgiving a
whole file also forgives the next violation added to it, which is how a guard
quietly stops guarding. It was caught doing exactly that during its own
self-test, before it shipped. There are 23 entries today; the file is meant to
shrink.

Rules it enforces (each with the reason it exists):

| Rule | What it catches |
|---|---|
| `no-blocking-io-on-ui` | `*Sync` file I/O, `sleep()` on the UI isolate |
| `no-transport-in-wapp-layer` | `lib/wapp/**` reaching into radios/transport internals instead of a service facade |
| `no-app-logic-in-core` | `lib/services/**` and `lib/connections/**` naming a specific wapp |
| `no-transport-logic-in-wapps-repo` | a wapp's C source reimplementing custody/retry/reachability |
| `no-platform-channel-off-main` | `MethodChannel`/`Ble5Bus` from isolate entrypoints |
| `hal-budget` | a new `hal_*` endpoint whose NAME describes a transport decision (reach/path/pending/custody/forward) rather than a capability |

To add a rule, add it to the table in `tool/arch_guard.dart` — it is one Dart
file with no dependencies, deliberately, so it keeps working.

### When the guard is wrong

It will be, sometimes. Two escapes, both of which leave a trace:

```dart
// arch-ignore: no-blocking-io-on-ui reading a 40-byte flag at startup, before the first frame
```

or re-baseline with `--baseline` and say why in the commit message. What you
must not do is delete the rule because it is inconvenient — the rules encode
bugs that already cost days.
