# Aurora architecture

This is the governing document. Where another document, a comment or a habit
disagrees with it, this document takes precedence.

It exists because two mistakes recur:

1. **Transport logic placed in a wapp.** Store-and-forward was first built
   inside `wapps/chat/main.c` as `bh_arm`, `bh_pump` and `best_hope_wire`. It
   functioned, but every other wapp had no offline delivery, and the wapp
   required HAL endpoints added solely so that it could estimate reachability.
2. **Work placed on the UI isolate.** Reticulum crypto and transport formerly
   ran on the main isolate and the application froze under load. They were moved
   out (see [performance.md](performance.md)); calling a service directly
   remains the shortest available patch, so the pressure to move them back is
   continuous.

Neither is visible in review, because the feature works in both cases. Both are
now checked mechanically: see section 5.

---

## 1. Layers

```
  +--------------------------------------------------------------+
  | wapps (.wapp, WASM)        chat, social, files, torrents      |
  |   presentation and domain rules for one application           |
  |   calls hal_* only; owns no radio, no key, no store           |
  +----------------^---------------------------+-----------------+
                   | events in                 | hal_* calls out
  +----------------+---------------------------v-----------------+
  | core (lib/)                                                   |
  |   identity and keys   profiles, nsec, signing, encryption     |
  |   transports          Reticulum, BLE5, LAN, WiFi-Direct, I2P  |
  |   delivery            LXMF, MeshCourier, custody, retries     |
  |   storage             sqlite, media archive, folders, spool   |
  +--------------------------------------------------------------+
```

A wapp is an event-driven consumer. It hands the core a message and is called
back when one arrives. It is not told which radio carried the message, whether
another station held it, or how many delivery attempts were made.

### Allocation of responsibility

| Question | Owner | Location |
|---|---|---|
| Should this message go over BLE, Reticulum, or both? | core | `lib/services/` |
| Is the recipient reachable? | core; a wapp does not ask | `RnsService`, `MeshService` |
| Who carries a message for an absent peer? | core | `MeshCourier`, `MeshStore` |
| What does a message mean (a like, a room post, a moderation rule)? | wapp | `wapps/<name>/` |
| How is a conversation rendered? | wapp | `wapps/<name>/` |
| Which key signs or encrypts? | core; a wapp requests, never holds | `hal_identity_sign`, `hal_encrypt` |

### Test for misplacement

> If a wapp requires a new `hal_*` endpoint in order to make a transport
> decision, the logic is on the wrong side of the boundary.

`hal_encrypt` is correct usage: the wapp asks the core to act with a key the
wapp does not hold. `hal_lxmf_pending` and `hal_rns_has_path` were added so that
a wapp could decide whether to transmit a redundant copy, which is the case that
prompted this document. They remain only as read-only diagnostics.

---

## 2. Isolates

Measured layout and rationale: [performance.md](performance.md).

| Isolate | Permitted | Not permitted |
|---|---|---|
| main / UI | widgets, `setState`, wapp page engines, MethodChannel calls | crypto over large buffers, sqlite scans, file hashing, blocking I/O, unbounded loops |
| rns-crypto | Reticulum sign, verify, encrypt | UI, platform channels |
| rns-transport | packet routing, links, resources | UI, platform channels |
| wapp background engines | `module_tick` for background wapps | anything requiring a UI |

Two rules are absolute.

**Platform channels are main-isolate only.** This covers `Ble5Bus`,
`MethodChannel` and plugin calls. A background isolate calling them fails
silently or throws. `MeshCourier` therefore transmits from the main isolate, and
its heavy work is encryption over payloads of about 200 bytes.

**Nothing blocking runs on the UI isolate.** No `*Sync` file I/O, no `sleep`, no
unbounded loop in a widget or in a service the UI awaits. Work that can exceed a
few milliseconds belongs in an isolate or a `compute` call.

---

## 3. Placing a new feature

Evaluate in order:

1. Does it move bytes between devices? Core, without exception. This covers
   transports, retries, custody, encryption in transit and addressing.
2. Does it require a key, the profile, or the databases? Core, exposed to wapps
   through a single narrow `hal_*` verb.
3. Is it about what a message means to one application? Wapp.
4. Is it a screen? Wapp, or `lib/ui/` for a core surface such as Settings, the
   launcher or the profile.

A core service does not know that any particular wapp exists. A special case for
chat in `lib/` indicates the wrong shape: the core should provide a generic
capability that the wapp uses. `MeshCourier` therefore carries payloads, not
chat messages.

---

## 4. Transports

See [ble5.md](ble5.md) for transmission budgets and
[store-and-forward.md](store-and-forward.md) for delivery to absent stations.

- Reticulum is the primary transport on every platform. LXMF is the message
  layer.
- BLE5 connectionless advertising is the off-grid broadcast plane: small frames,
  one-to-many, no pairing.
- GATT and MSP form the bulk and custody plane: a transient link for payloads
  too large for an advertisement, and for transferring parked mail to its
  recipient.
- Store-and-forward is a core service, `MeshCourier`, armed by the core on every
  direct send. Arrivals are returned through the ordinary LXMF inbox.

---

## 5. Enforcement

`tool/arch_guard.dart` checks the rules above on every push, via
`.github/workflows/arch.yml`, and on every commit once the hook is installed.

```sh
dart tool/arch_guard.dart            # check; exit 1 on a new violation
dart tool/arch_guard.dart --list     # all violations, including the baseline
dart tool/arch_guard.dart --baseline # re-record the baseline
./tool/install-hooks.sh              # install the pre-commit + pre-push hooks
```

The guard is a baseline checker. Violations recorded in
`tool/arch_baseline.txt` do not fail the build; new violations do. A guard that
fails on first use is disabled shortly afterwards, so the baseline exists to
keep it in service.

The baseline is keyed on the offending line rather than the file. Keying on the
file would also forgive the next violation added to that file, which was
observed during the guard's own self-test before release.

The baseline is currently empty. Every violation it originally recorded has been
fixed or annotated, so any new violation fails the build immediately.

### What the pre-push hook refuses, and why

`./tool/install-hooks.sh` also installs a **pre-push** hook, and it enforces
something the architecture rules cannot: that CI is compiling the same code you
compiled.

It refuses a push while anything under `lib/`, `test/` or `assets/` is
uncommitted, and warns (without refusing) when the `../reticulum-dart` sibling
has uncommitted work or sits ahead of its remote.

The reason is a failure that has happened repeatedly and always looks the same:
a commit names a symbol whose definition is still unstaged, `flutter test`
passes here because this machine has both halves, and the build is the first
thing to find out. The sibling is the sharper version — aurora depends on
reticulum-dart by path, so it resolves to your working tree locally and to
`geograms/reticulum-dart@main` in CI, which means an uncommitted change there is
invisible to every local check at the same time as it is invisible to CI.

Both checks are pure git, so the hook costs milliseconds and says nothing at all
when the tree is clean. Skip it with `git push --no-verify` when you mean to.

Rules enforced:

| Rule | Detects |
|---|---|
| `no-blocking-io-on-ui` | `*Sync` file I/O and `sleep()` on the UI isolate |
| `no-transport-in-wapp-layer` | `lib/wapp/**` reaching into radio or transport internals instead of a service facade |
| `no-app-logic-in-core` | `lib/services/**` and `lib/connections/**` naming a specific wapp |
| `no-transport-logic-in-wapps-repo` | wapp C source reimplementing custody, retry or reachability |
| `no-platform-channel-off-main` | `MethodChannel` or `Ble5Bus` in isolate entry points |
| `hal-budget` | a `hal_*` endpoint whose name describes a transport decision (reach, path, pending, custody, forward) rather than a capability |

To add a rule, extend the table in `tool/arch_guard.dart`. It is a single Dart
file with no dependencies, which is deliberate.

### Exceptions

Two mechanisms exist, both leaving a record.

An inline annotation, which requires a stated reason:

```dart
// arch-ignore: no-blocking-io-on-ui reads a 40-byte flag at startup, before the first frame
```

Or re-recording the baseline with `--baseline`, with the reason given in the
commit message.

Deleting a rule is not an accepted response to it firing. Each rule encodes a
defect that has already occurred.
