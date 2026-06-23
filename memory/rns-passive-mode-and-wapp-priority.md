---
name: rns-passive-mode-and-wapp-priority
description: Phones drop to RNS passive/leaf mode under announce-flood CPU load; wapp announces are flood-exempt
metadata:
  type: project
---

Two RNS-stack fixes made 2026-06-21 so circles datagrams cross device-to-device
over the public internet (found while testing two phones on different networks):

1. **Wapp announces must be flood-exempt.** `RnsTransport` caps verification of
   announces from *new* destinations (~20/s) so the public-hub flood can't peg
   the CPU, exempting `priorityAnnounceNames`. The `geogram/wapp` aspect was
   missing, so a peer's wapp-datagram announce got shed on busy hubs. Fix: add
   `RnsDestination.nameHash(_app, _aspectsWapp)` to the priority set in
   `rns_service.dart` start().

2. **Automatic passive (leaf) mode under CPU pressure.** Every Aurora node ran as
   a transport node (`transportId = own id`), rebroadcasting the whole public
   mesh's announces to all hub interfaces → 100% CPU / ANR on a phone (esp. after
   a network change). Added passive mode to `reticulum-dart`
   `RnsTransport`: sampled inbound announce rate (>50/s 3s → passive; <12/s 10s →
   active, hysteresis) gates `_rebroadcast` + `_maybeForward`. Passive still
   keeps hub uplinks, ingests (learns paths, receives own datagrams), and
   announces its own dests — it only stops relaying OTHER nodes' traffic. The
   hubs do the relaying, so meshing/discovery/circles all keep working. Surfaced
   in `/api/rns/status` as `passive` + `annRate`; manual override
   `transport.setPassive(bool)`.

**Why:** real-world answer to "the CPU can't take it" is shed relay duty, not
connectivity — never disconnect from the hubs. **How to apply:** the path dep
`../reticulum-dart` is shared; rebuild the APK after editing it. See
[[circles-wapp]] and [[c61-budget-phone-release-only]].
