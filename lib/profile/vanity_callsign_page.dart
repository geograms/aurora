/*
 * VanityCallsignPage — a full screen for one job: finding a callsign you like.
 *
 * A callsign is the first thing a new user is asked to accept, and it is
 * random. Most people want their initials in it. Squeezed into the corner of
 * the welcome page, the generator was a text field, a button, some counters and
 * a wrap of chips competing for room with the preview card, the nickname field
 * and the Continue button — on a phone, all of it at once. So it gets its own
 * screen: type a pattern, watch it search, tap the one you want.
 *
 * The search itself is a brute force — generate keypairs until a callsign
 * contains the pattern — so it runs on its OWN ISOLATE. It must never be on the
 * main isolate: it burns a core flat out for as long as it runs, and it runs for
 * minutes on a 4-character pattern.
 *
 * Returns the chosen [IwiProfile] via Navigator.pop, or null if the user backs
 * out. Nothing is written to disk here — the welcome page still owns that.
 */

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'iwi_profile.dart';
import '../util/nostr_key_generator.dart';

/// The only characters a callsign can ever contain.
///
/// A callsign is `X1` + the first four characters of the npub, and an npub is
/// bech32 — whose alphabet is `qpzry9x8gf2tvdw0s3jn54khce6mua7l`. So **B, I, O
/// and 1 do not exist in any callsign**, and neither does any other character
/// outside this set.
///
/// This is not a detail: without it the search box happily accepts "AB" and then
/// grinds forever on a pattern that cannot occur. (It did exactly that — 17,000
/// keys, zero matches, no explanation.) The field is therefore restricted to
/// characters that can actually be found.
const String kCallsignAlphabet = 'QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L';

/// Brute-forces vanity callsigns off the main isolate. The main isolate sends
/// `{pattern, batchSize}`; we generate that many keypairs and reply with
/// `{keysGenerated, matches}` where each match's callsign contains the pattern.
/// One batch per reply keeps the UI responsive and the search stoppable.
void vanityIsolate(SendPort mainSendPort) {
  final port = ReceivePort();
  mainSendPort.send(port.sendPort);
  port.listen((message) {
    if (message == 'stop') {
      port.close();
      return;
    }
    if (message is Map) {
      final pattern = message['pattern'] as String;
      final batchSize = message['batchSize'] as int;
      var generated = 0;
      final matches = <Map<String, String>>[];
      for (var i = 0; i < batchSize; i++) {
        final keys = NostrKeyGenerator.generateKeyPair();
        generated++;
        if (keys.callsign.contains(pattern)) {
          matches.add({
            'npub': keys.npub,
            'nsec': keys.nsec,
            'callsign': keys.callsign,
          });
        }
      }
      mainSendPort.send({'keysGenerated': generated, 'matches': matches});
    }
  });
}

class VanityCallsignPage extends StatefulWidget {
  /// The callsign currently on the welcome page, so it can be shown as the one
  /// in play and the user knows what they are replacing.
  final String currentCallsign;

  const VanityCallsignPage({super.key, required this.currentCallsign});

  @override
  State<VanityCallsignPage> createState() => _VanityCallsignPageState();
}

class _VanityCallsignPageState extends State<VanityCallsignPage> {
  final TextEditingController _pattern = TextEditingController();

  bool _running = false;
  int _tried = 0;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  Stopwatch? _watch;
  final List<IwiProfile> _matches = [];

  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _sendPort;

  @override
  void dispose() {
    _stop();
    _pattern.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final pattern = _pattern.text.trim().toUpperCase();
    if (pattern.isEmpty || pattern.length > 4) return;
    // Belt and braces: the field already filters, but a pattern containing a
    // character no callsign can hold would search until the battery died.
    if (pattern.split('').any((c) => !kCallsignAlphabet.contains(c))) return;
    setState(() {
      _running = true;
      _tried = 0;
      _elapsed = Duration.zero;
      _matches.clear();
    });
    _watch = Stopwatch()..start();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() => _elapsed = _watch!.elapsed);
    });
    _receivePort = ReceivePort();
    _isolate = await Isolate.spawn(vanityIsolate, _receivePort!.sendPort);
    _receivePort!.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        _requestBatch(pattern);
      } else if (message is Map && mounted) {
        setState(() {
          _tried += message['keysGenerated'] as int;
          for (final m in (message['matches'] as List)) {
            final mm = (m as Map).cast<String, String>();
            final cs = mm['callsign']!;
            if (_matches.any((p) => p.callsign == cs)) continue;
            _matches.insert(
              0,
              IwiProfile(
                id: cs,
                nickname: '',
                callsign: cs,
                npub: mm['npub']!,
                nsec: mm['nsec']!,
                createdAt: DateTime.now().millisecondsSinceEpoch,
              ),
            );
            if (_matches.length > 50) _matches.removeLast();
          }
        });
        if (_running && mounted) _requestBatch(pattern);
      }
    });
  }

  void _requestBatch(String pattern) =>
      _sendPort?.send({'pattern': pattern, 'batchSize': 1000});

  void _stop() {
    _sendPort?.send('stop');
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    _sendPort = null;
    _running = false;
    _timer?.cancel();
    _timer = null;
    _watch?.stop();
    if (mounted) setState(() {});
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Hand the chosen identity back to the welcome page. Stop the search first —
  /// it is a core at 100% and nobody is watching it any more.
  void _use(IwiProfile p) {
    _stop();
    Navigator.of(context).pop(p);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final canSearch = _pattern.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Custom callsign'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            _stop();
            Navigator.of(context).pop();
          },
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Type a few letters you want in your callsign — your initials, '
                'a word, anything. Random identities are generated until one '
                'contains them.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              Text(
                'Every extra character makes it far rarer: 1–2 letters land in '
                'seconds, 4 can take many minutes.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              Text(
                'Callsigns cannot contain B, I, O or 1 — those characters do '
                'not exist in the alphabet a callsign is built from, so they '
                'are not accepted here.',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.tertiary),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pattern,
                      enabled: !_running,
                      autofocus: true,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 4,
                      // Only characters a callsign can actually contain — a
                      // pattern with a B in it would never, ever match.
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp('[$kCallsignAlphabet'
                              '${kCallsignAlphabet.toLowerCase()}]'),
                        ),
                        _UpperCaseFormatter(),
                      ],
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 20),
                      decoration: const InputDecoration(
                        labelText: 'Pattern (1–4 characters)',
                        hintText: 'e.g. CAT',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) {
                        if (!_running && canSearch) _start();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: _running
                          ? _stop
                          : (canSearch ? _start : null),
                      icon: Icon(_running ? Icons.stop : Icons.search),
                      label: Text(_running ? 'Stop' : 'Search'),
                    ),
                  ),
                ],
              ),
              if (_running || _tried > 0) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (_running) ...[
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Text(
                      'Tried $_tried keys · ${_fmt(_elapsed)}'
                      '${_matches.isEmpty && _running ? ' · still looking…' : ''}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Expanded(
                child: _matches.isEmpty
                    ? Center(
                        child: Text(
                          _running
                              ? 'Searching…'
                              : 'Matches will appear here.\nYour callsign stays '
                                  '${widget.currentCallsign} until you pick one.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _matches.length,
                        separatorBuilder: (context, i) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final m = _matches[i];
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: cs.primaryContainer,
                              child: Icon(Icons.badge_outlined,
                                  color: cs.onPrimaryContainer, size: 20),
                            ),
                            title: Text(
                              m.callsign,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(
                              '${m.npub.substring(0, 20)}…',
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 11),
                            ),
                            trailing: FilledButton(
                              onPressed: () => _use(m),
                              child: const Text('Use'),
                            ),
                            onTap: () => _use(m),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Uppercase as the user types, so the pattern always matches the callsign's own
/// casing (callsigns are uppercase; the npub they come from is not).
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}
