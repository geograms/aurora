import 'package:flutter/material.dart';

import '../services/reticulum/rns_service.dart';

/// Settings → Muted accounts.
///
/// A mute is keyed on the **account key** — a callsign, or the first 12 hex
/// chars of a NOSTR pubkey — and never on a display name. That distinction is
/// the whole point: the feed was carrying the same scam paragraph from a
/// handful of DIFFERENT keys all wearing one name and one avatar, and a rule
/// written against the name would have muted the innocent and missed every one
/// of them.
///
/// So each key is muted on its own, and this page is where the user sees what
/// they have refused to carry and takes it back if they were wrong. Muting is
/// not a display filter: the feed gate drops a muted author's posts before they
/// are ever stored.
///
/// A list of the user's OWN decisions is one of the few lists in this app that
/// is safe to render in full — it is as long as the user made it, not as long
/// as the network is.
class MutedPage extends StatefulWidget {
  const MutedPage({super.key});

  @override
  State<MutedPage> createState() => _MutedPageState();
}

class _MutedPageState extends State<MutedPage> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = RnsService.instance.mutedCallsigns.toList()..sort();

    return Scaffold(
      appBar: AppBar(title: const Text('Muted accounts')),
      body: muted.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Nobody is muted.\n\n'
                  'Mute an account from the ⋯ menu on any of its posts. '
                  'Its posts stop being shown — and stop being stored.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant, height: 1.5),
                ),
              ),
            )
          : ListView.separated(
              itemCount: muted.length + 1,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      '${muted.length} muted. Each key is muted on its own — a '
                      'name and an avatar are free to copy, an account key is '
                      'not.',
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 13, height: 1.4),
                    ),
                  );
                }
                final key = muted[i - 1];
                final prof = RnsService.instance
                    .nostrProfileByShort12(key.toLowerCase());
                final name = (prof['name'] ?? '').toString();
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: cs.surfaceContainerHighest,
                    child: Icon(Icons.volume_off, size: 18, color: cs.outline),
                  ),
                  title: Text(name.isNotEmpty ? name : key,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  // The key is what is actually muted, so the key is what we
                  // show — a name here would suggest we muted a person.
                  subtitle: Text(key,
                      style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                  trailing: TextButton(
                    onPressed: () {
                      RnsService.instance.setMutedCallsign(key, false);
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Unmuted $key')),
                      );
                    },
                    child: const Text('Unmute'),
                  ),
                );
              },
            ),
    );
  }
}
