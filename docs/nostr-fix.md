# NOSTR All Refresh Fix Plan

## Objective

Fix only the frozen automatic refresh of Social's curated **All** timeline.
The solution must run through one Android background-owned NOSTR engine, use
one internet connection per configured relay, ignore duplicate refresh
requests, and complete one automatic refresh cycle every ten minutes.

Do not change Following semantics, profiles, feed layout, archive retention,
curation policy, or unrelated wapps as part of this work.

## Observed Failure

The failure was reproduced on the C61 with Aurora versionCode `36043`:

- An automatic batch completed at `12:02:29`, delivering seven notes. Its
  newest note was already 229 seconds old.
- Another automatic request started at `12:02:40` but never logged completion.
- No scheduled request ran near the following ten-minute deadline.
- At `12:11`, Social was still open on All and the `f4` subscription was still
  being drained, but the newest visible notes were 13 minutes old.
- The current code opens duplicate firehose WebSockets through `_fireClients`.
  C61 logs show the duplicate Primal connection repeatedly timing out.
- `WappPage.build()` calls `nostrResume()`. That method currently starts another
  automatic refresh every 20 seconds, so widget rebuilds compete with the
  ten-minute scheduler and repeatedly replace the firehose REQ.
- The current timer is a one-shot that creates its periodic successor only
  after a guarded callback. One skipped callback can permanently remove the
  automatic schedule.
- Several request exits are silent, making a lifecycle cancellation look like
  a request that remains in flight forever.

## Non-Negotiable Architecture

### One background singleton

- Keep `RnsService.instance` as the only application-level NOSTR owner.
- It owns exactly one `NostrClient`, one NOSTR engine isolate, one
  `NostrRelayHub`, and one WebSocket client per configured internet relay.
- Add an initialization future/lock around `NostrClient.spawn()` so concurrent
  boot paths await the same startup operation.
- Remove `_fireClients`. All, Following, launcher highlights, profiles,
  notifications, search, and publishing must use the same relay clients.
- Foreground pages and background wapps may register interest, subscribe, drain
  results, and send commands. They must never construct a relay connection.
- Opening or closing Social must not stop the singleton engine or disconnect
  relays needed by Following and notifications.

### Existing Android foreground service

- Reuse `AndroidForegroundService`; do not add another Android service.
- Acquire a dedicated `nostr` holder when the singleton NOSTR engine starts.
  This holder must not depend on Reticulum connecting successfully or on a wapp
  being configured for autostart.
- Release the holder only when the unified NOSTR engine is intentionally
  stopped.
- Register the NOSTR coordinator with the service's native `onTick` heartbeat.
  The heartbeat sends the current wall-clock time to the engine isolate.
- Android can throttle Dart timers in the background. Therefore the native
  heartbeat, not a Dart `Timer`, is authoritative for ten-minute deadlines.
- Persist scheduler timestamps so a process restart performs at most one
  overdue cycle rather than resetting the interval or issuing a request storm.

## Relay Multiplexing

One socket is not sufficient if the application still creates an unlimited
number of physical relay subscriptions. Preserve all existing logical
subscription APIs, but multiplex them locally onto at most three physical REQs
per internet relay:

1. `core`: Following, contact list, notifications, and standing subscriptions.
2. `all`: the single scheduled curated firehose window.
3. `lookup`: serialized profile, stats, search, and manual-backfill requests.

Use stable physical subscription IDs. Route received events to logical
subscribers locally with the existing filters.

- A scheduled All refresh replaces only the `all` REQ.
- Replacing `all` must not close the socket or disturb `core`.
- Serialize lookup work and reuse the `lookup` lane instead of accumulating
  profile/stat subscriptions.
- Publishing continues over the existing relay client.
- Apply multiplexing only to internet WebSockets. Preserve existing local and
  RNS transport behavior.
- Relay add, remove, enable, and disable must retain their existing behavior.
- Add an invariant warning if more than one WebSocket client exists for a relay
  URI or more than the three physical lanes are open.

## Strict Ten-Minute Coordinator

The coordinator lives entirely inside the NOSTR engine isolate and has three
states:

- `idle`
- `automaticInFlight`
- `manualInFlight`

Persist and expose these fields for diagnostics:

- `lastStartedAt`
- `lastCompletedAt`
- `lastSuccessfulAt`
- `nextDueAt`
- current state
- active All consumers
- last ignored-request reason
- last failure reason

### Automatic cycle

1. All interest is active when either launcher public highlights are needed or
   Social All is visible.
2. On the transition from no All consumers to at least one consumer, run an
   immediate cycle only when the previous successful batch is more than ten
   minutes old.
3. Otherwise wait for the persisted `nextDueAt`.
4. A native heartbeat starts a cycle only when `state == idle` and
   `now >= nextDueAt`.
5. When the cycle starts, set `state = automaticInFlight` and set the next
   deadline to exactly ten minutes after the scheduled start.
6. Reuse the existing relay sockets and replace only the stable `all` REQ.
7. Collect, verify, gate, rank, and archive on the NOSTR engine isolate.
8. Hand one completed curated batch to consumers.
9. Exit through one `finally` block that clears the in-flight state and
   preserves the next deadline, regardless of success, failure, empty output,
   lifecycle changes, or consumer changes.

There must be no one-minute automatic retry loop. An empty or failed cycle
keeps the existing feed and waits for the next normal ten-minute deadline.

### Duplicate requests

If an automatic, resume, launcher, rebuild, or duplicate request arrives while
a cycle is active or before `nextDueAt`, ignore it completely:

- do not open another request;
- do not reconnect a healthy socket;
- do not replace a physical REQ;
- do not clear a buffer;
- do not modify `nextDueAt`.

Log the ignored source and either `inFlight` or `beforeDeadline`.

Android resume may reconnect a genuinely disconnected singleton socket. The
client then replays the current physical lanes. Resume must not itself request
an All refresh unless the coordinator says the ten-minute deadline is due.

### Manual refresh

Preserve pull-to-refresh without allowing it to disrupt the automatic cycle:

- Ignore a manual request while either request type is in flight.
- When idle, run manual backfill through the serialized `lookup` lane.
- Do not replace the standing `all` lane.
- Do not change the automatic `nextDueAt`.
- Ignore repeated manual requests until the active manual request completes.

## Consumer Lifetime

- Track All consumers in an idempotent set keyed by stable consumer ID, not a
  numeric reference count.
- Registering the same consumer twice does nothing.
- Removing one consumer cannot stop All while another consumer remains.
- Switching Social to Following removes only Social's All interest. It does not
  stop the singleton, close relay sockets, or affect Following subscriptions.
- Following and notification processing remain active in the background even
  when no All consumer exists.
- Remove network activity from widget `build()` methods. Page entry, filter
  transitions, and Android lifecycle transitions must produce explicit,
  idempotent commands instead.

## Required Diagnostics

Each automatic cycle must produce enough information to prove its lifecycle:

- scheduled deadline;
- actual start time;
- request source;
- physical relay and lane count;
- events received per relay;
- candidates accepted and curated;
- batch size and newest event age;
- completion or failure;
- next deadline.

Also log:

- singleton engine creation and reuse;
- one connection per relay;
- consumer registration/removal;
- ignored duplicate requests;
- Android heartbeat reaching the NOSTR isolate;
- process-restart deadline restoration.

Do not log every two-second heartbeat. Log only deadline transitions, ignored
requests, failures, and periodic health summaries.

## Regression Tests

### Singleton and connections

- Concurrent startup paths produce one `NostrClient` and one engine isolate.
- All, Following, hero, profiles, search, and notifications use one WebSocket
  client per relay URI.
- Hundreds of logical subscriptions result in at most three physical REQs per
  internet relay.
- Relay enable/disable and reconnect replay the three current lanes once.

### Scheduling

- Rebuild, resume, hero, and duplicate-request storms produce exactly one
  automatic request per ten-minute interval.
- Requests before the deadline are ignored without changing the deadline.
- Requests during `automaticInFlight` or `manualInFlight` are ignored.
- Empty, failed, and lifecycle-invalid cycles still leave the next deadline
  scheduled exactly once.
- A process restart restores the deadline and runs no more than one overdue
  cycle.
- Native heartbeat starts an overdue cycle while Dart timers are suspended.

### Existing behavior

- Following continues receiving every direct-follow publication during an All
  cycle.
- Notifications continue receiving replies, reactions, and mentions.
- Publishing, profiles, search, relay settings, local transport, and RNS
  transport remain functional.
- Manual pull returns its backfill batch and does not change the automatic
  deadline.
- All archiving and older-page pagination remain unchanged.

## C61 Acceptance Test

This test is mandatory. Passing unit tests or seeing one successful refresh is
not sufficient.

1. Build and install one APK on the C61.
2. Force-stop the previous process and launch cleanly.
3. Record versionCode and PID.
4. Confirm logs show one NOSTR engine, one WebSocket client per relay, and no
   more than three physical lanes per internet relay.
5. Open Social All and wait for a successful scheduled batch.
6. Record the newest visible publication ID and age, then take screenshot one.
7. Leave the same APK, PID, and All screen untouched. Do not tap, pull,
   reinstall, restart, switch filters, or invoke a debug refresh.
8. Wait at least 15 full minutes.
9. Take screenshot two.
10. Screenshot two must show a different newer publication whose visible age
    is no more than ten minutes.
11. Logs must show exactly one intervening scheduled automatic cycle, with any
    duplicate requests ignored.
12. Confirm Following and notification subscriptions remained active during
    the cycle.

Do not declare the task complete if any of these conditions fail:

- the two screenshots are from different builds or processes;
- no scheduled cycle occurred between them;
- a duplicate request executed;
- any relay had multiple WebSocket clients;
- Following or notifications stopped;
- the newest publication in screenshot two is older than ten minutes.

## Implementation Boundary

The implementation must remain limited to:

- singleton NOSTR startup and Android heartbeat ownership;
- internet relay connection/subscription multiplexing;
- automatic/manual request serialization;
- All consumer registration;
- diagnostics and tests required to prove the ten-minute refresh.

Do not use this task to alter curation rules, redesign Social, change profile
UI, change Following membership, rewrite archives, or refactor unrelated
services.
