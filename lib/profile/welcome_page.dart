/*
 * WelcomePage — first-run profile creation for iwi.
 *
 * Ported and slimmed down from geogram/lib/pages/welcome_page.dart.
 * The parent page ships a lot of extras (vanity generator, i18n,
 * station mode, permissions onboarding) that iwi doesn't need yet.
 * What's preserved: the callsign preview card, regenerate, import
 * nsec, and the "Continue" finalization handoff.
 *
 * The page does NOT write anything to disk until the user hits
 * Continue — [ProfileService.generatePreview] / [buildFromNsec] just
 * build an in-memory [IwiProfile], and [saveAndActivate] is only
 * called from [_finalize].
 */

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';

import 'iwi_profile.dart';
import 'identity_backup.dart';
import 'profile_service.dart';
import '../util/nostr_key_generator.dart';
import '../services/android_permissions_service.dart';
import '../services/preferences_service.dart';

/// Background isolate that brute-forces vanity callsigns. The main isolate
/// sends `{pattern, batchSize}`; we generate that many keypairs and reply with
/// `{keysGenerated, matches}` where each match's callsign contains the pattern.
/// Looping (one batch per reply) keeps the UI responsive and stoppable.
void _vanityIsolate(SendPort mainSendPort) {
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

class WelcomePage extends StatefulWidget {
  /// Fired once the profile has been persisted and activated. The
  /// caller (IwiApp) flips the root route from WelcomePage to the
  /// launcher in response.
  final VoidCallback onComplete;

  /// When true, show a Cancel button and allow the user to dismiss
  /// the page without creating a profile. Set this when pushing the
  /// welcome page as a modal on top of an existing profile (e.g. the
  /// "Add profile…" flow from the AppBar switcher). Leave it false
  /// for the first-run boot path where there is no going back.
  final bool canCancel;

  const WelcomePage({
    super.key,
    required this.onComplete,
    this.canCancel = false,
  });

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  final _nicknameController = TextEditingController();

  /// In-memory preview profile. Never persisted until [_finalize].
  IwiProfile _preview = ProfileService.instance.generatePreview();

  /// Previous preview — kept so "go back" can undo a regenerate.
  IwiProfile? _previous;

  bool _isFinalizing = false;
  String? _error;

  // ── Restore-from-backup (survives-uninstall identity) ──────────────────
  /// Identities found in the survives-uninstall backup, auto-loaded on init
  /// when the file is plaintext and reachable. Drives the restore card.
  List<RestorableIdentity> _restorable = const [];

  @override
  void initState() {
    super.initState();
    _loadRestorable();
  }

  /// Auto-detect a reachable, plaintext backup so we can offer one-tap restore.
  /// Encrypted or permission-gated backups are reached via [_restoreFromBackup].
  Future<void> _loadRestorable() async {
    try {
      if (!await IdentityBackup.instance.backupExists()) return;
      if (await IdentityBackup.instance.isEncrypted()) return;
      final list = await IdentityBackup.instance.readBackup();
      if (mounted && list.isNotEmpty) setState(() => _restorable = list);
    } catch (_) {
      // Best-effort — the manual "Restore from a backup" button still works.
    }
  }

  /// Save a restored identity and hand off to the launcher. Reuses
  /// [ProfileService.buildFromNsec] so the callsign/npub are re-derived.
  Future<void> _restore(RestorableIdentity id) async {
    if (_vanityRunning) _stopVanity();
    setState(() {
      _isFinalizing = true;
      _error = null;
    });
    try {
      final profile = ProfileService.instance.buildFromNsec(
        id.nsec,
        nickname: id.nickname,
      );
      await ProfileService.instance.saveAndActivate(profile);
      await _ensureBackupAccess();
      if (!mounted) return;
      widget.onComplete();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isFinalizing = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Manual restore: grant storage access if needed, unlock an encrypted backup
  /// with a passphrase, then restore (or pick when several identities exist).
  Future<void> _restoreFromBackup() async {
    if (_vanityRunning) _stopVanity();
    // Android: the backup lives on public storage behind all-files-access.
    if (!await AndroidPermissionsService.instance.hasAllFilesAccess()) {
      final ok =
          await AndroidPermissionsService.instance.requestAllFilesAccess();
      if (!ok) {
        if (mounted) {
          setState(() => _error =
              'Storage access is needed to read the backup on this phone.');
        }
        return;
      }
    }
    if (!await IdentityBackup.instance.backupExists()) {
      if (mounted) setState(() => _error = 'No backup found on this device.');
      return;
    }
    var passphrase = '';
    if (await IdentityBackup.instance.isEncrypted()) {
      final entered = await _promptPassphrase();
      if (entered == null || entered.isEmpty) return;
      passphrase = entered;
    }
    List<RestorableIdentity> list;
    try {
      list = await IdentityBackup.instance.readBackup(passphrase: passphrase);
    } on BadPassphrase catch (e) {
      if (mounted) setState(() => _error = e.message);
      return;
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
      return;
    }
    if (list.isEmpty) {
      if (mounted) setState(() => _error = 'Backup held no identities.');
      return;
    }
    // Keep encrypting future auto-backups with the same passphrase.
    if (passphrase.isNotEmpty) {
      PreferencesService.instanceSync?.identityBackupPassphrase = passphrase;
    }
    if (list.length == 1) {
      await _restore(list.first);
      return;
    }
    if (!mounted) return;
    final chosen = await showDialog<RestorableIdentity>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Restore which identity?'),
        children: [
          for (final id in list)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, id),
              child: Text(
                  '${id.callsign}${id.nickname.isNotEmpty ? '  (${id.nickname})' : ''}'),
            ),
        ],
      ),
    );
    if (chosen != null) await _restore(chosen);
  }

  Future<String?> _promptPassphrase() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlock backup'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
            hintText: 'Backup passphrase',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
  }

  Widget _restoreCard(ThemeData theme, ColorScheme cs) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.restore, color: cs.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Restore your previous identity',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: cs.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'A backup from a previous install was found on this phone.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: 12),
          for (final id in _restorable)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FilledButton.icon(
                onPressed: _isFinalizing ? null : () => _restore(id),
                icon: const Icon(Icons.badge),
                label: Text(
                  'Restore ${id.callsign}'
                  '${id.nickname.isNotEmpty ? '  (${id.nickname})' : ''}',
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Vanity callsign generator ──────────────────────────────────────
  final _patternController = TextEditingController();
  bool _vanityRunning = false;
  int _vanityTried = 0;
  Duration _vanityElapsed = Duration.zero;
  Timer? _vanityTimer;
  Stopwatch? _vanityWatch;
  final List<IwiProfile> _vanityMatches = [];
  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _sendPort;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _stopVanity();
    _nicknameController.dispose();
    _patternController.dispose();
    super.dispose();
  }

  Future<void> _startVanity() async {
    final pattern = _patternController.text.trim().toUpperCase();
    if (pattern.isEmpty || pattern.length > 4) return;
    setState(() {
      _vanityRunning = true;
      _vanityTried = 0;
      _vanityElapsed = Duration.zero;
      _vanityMatches.clear();
      _error = null;
    });
    _vanityWatch = Stopwatch()..start();
    _vanityTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() => _vanityElapsed = _vanityWatch!.elapsed);
    });
    _receivePort = ReceivePort();
    _isolate = await Isolate.spawn(_vanityIsolate, _receivePort!.sendPort);
    _receivePort!.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        _requestBatch(pattern);
      } else if (message is Map) {
        if (mounted) {
          setState(() {
            _vanityTried += message['keysGenerated'] as int;
            for (final m in (message['matches'] as List)) {
              final mm = (m as Map).cast<String, String>();
              final cs = mm['callsign']!;
              if (_vanityMatches.any((p) => p.callsign == cs)) continue;
              _vanityMatches.insert(
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
              if (_vanityMatches.length > 50) _vanityMatches.removeLast();
            }
          });
        }
        if (_vanityRunning && mounted) _requestBatch(pattern);
      }
    });
  }

  void _requestBatch(String pattern) =>
      _sendPort?.send({'pattern': pattern, 'batchSize': 1000});

  void _stopVanity() {
    _sendPort?.send('stop');
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    _sendPort = null;
    _vanityRunning = false;
    _vanityTimer?.cancel();
    _vanityTimer = null;
    _vanityWatch?.stop();
    if (mounted && !_disposed) setState(() {});
  }

  /// Use a found vanity match as the active preview (so Continue keeps it).
  void _selectVanity(IwiProfile match) {
    setState(() {
      _previous = _preview;
      _preview = match;
      _error = null;
    });
  }

  static String _fmtElapsed(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _regenerate() {
    if (_vanityRunning) _stopVanity();
    setState(() {
      _previous = _preview;
      _preview = ProfileService.instance.generatePreview(
        nickname: _nicknameController.text.trim(),
      );
      _error = null;
    });
  }

  void _goBack() {
    final prev = _previous;
    if (prev == null) return;
    setState(() {
      _preview = prev;
      _previous = null;
      _error = null;
    });
  }

  Future<void> _importNsec() async {
    if (_vanityRunning) _stopVanity();
    final controller = TextEditingController();
    final nsec = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import existing profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste a Nostr private key (nsec1…) below. The matching '
              'callsign and npub will be derived automatically.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'nsec1…',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (nsec == null || nsec.isEmpty) return;
    try {
      final profile = ProfileService.instance.buildFromNsec(
        nsec,
        nickname: _nicknameController.text.trim(),
      );
      setState(() {
        _previous = _preview;
        _preview = profile;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _finalize() async {
    if (_vanityRunning) _stopVanity();
    setState(() {
      _isFinalizing = true;
      _error = null;
    });
    try {
      final profile = _preview.copyWith(
        nickname: _nicknameController.text.trim(),
      );
      await ProfileService.instance.saveAndActivate(profile);
      await _ensureBackupAccess();
      if (!mounted) return;
      widget.onComplete();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isFinalizing = false;
          _error = e.toString();
        });
      }
    }
  }

  /// One-time nudge so the automatic identity backup can write to the
  /// survives-uninstall location. Android-only; no-op once access is granted
  /// (and on desktop). Skipping is fine — the profile editor can enable it
  /// later, and the auto-backup just stays idle until then.
  Future<void> _ensureBackupAccess() async {
    if (await AndroidPermissionsService.instance.hasAllFilesAccess()) {
      // Already granted (or desktop) — make sure the first backup is written.
      final pass =
          PreferencesService.instanceSync?.identityBackupPassphrase ?? '';
      await IdentityBackup.instance
          .backupAll(ProfileService.instance.profiles, passphrase: pass);
      return;
    }
    if (!mounted) return;
    final allow = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Protect your identity'),
        content: const Text(
          'Allow storage access so Aurora can keep a backup of your secret '
          'key on this phone. It lets you restore this identity if you '
          'reinstall the app or clear its data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    if (allow != true) return;
    final ok = await AndroidPermissionsService.instance.requestAllFilesAccess();
    if (ok) {
      final pass =
          PreferencesService.instanceSync?.identityBackupPassphrase ?? '';
      await IdentityBackup.instance
          .backupAll(ProfileService.instance.profiles, passphrase: pass);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return PopScope(
      canPop: widget.canCancel,
      child: Scaffold(
        appBar: widget.canCancel
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Cancel',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                title: const Text('Add profile'),
              )
            : null,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 48,
                    maxWidth: 560,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: cs.primaryContainer,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.waving_hand,
                              size: 36,
                              color: cs.primary,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Welcome to geogram',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Create a profile to sign the wapps you '
                                  'build and install. You can generate a '
                                  'fresh Nostr identity or import an '
                                  'existing nsec.',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),

                      // Restore-from-backup card (only when a backup was found).
                      if (_restorable.isNotEmpty) _restoreCard(theme, cs),

                      // Callsign card
                      Text(
                        'Your callsign',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          children: [
                            Icon(Icons.badge, size: 48, color: cs.primary),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (_previous != null)
                                  IconButton(
                                    onPressed:
                                        _isFinalizing ? null : _goBack,
                                    icon: const Icon(Icons.undo),
                                    tooltip: 'Revert to previous callsign',
                                    color: cs.primary,
                                  )
                                else
                                  const SizedBox(width: 48),
                                const SizedBox(width: 8),
                                AnimatedSwitcher(
                                  duration:
                                      const Duration(milliseconds: 200),
                                  child: Text(
                                    _preview.callsign,
                                    key: ValueKey(_preview.callsign),
                                    style: theme.textTheme.headlineMedium
                                        ?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: cs.primary,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const SizedBox(width: 48),
                              ],
                            ),
                            const SizedBox(height: 12),
                            SelectableText(
                              _preview.npub,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onPrimaryContainer,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: _isFinalizing ? null : _regenerate,
                                  icon: const Icon(Icons.refresh, size: 18),
                                  label: const Text('Generate new'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _isFinalizing ? null : _importNsec,
                                  icon: const Icon(Icons.key, size: 18),
                                  label: const Text('Import nsec'),
                                ),
                                OutlinedButton.icon(
                                  onPressed:
                                      _isFinalizing ? null : _restoreFromBackup,
                                  icon: const Icon(Icons.restore, size: 18),
                                  label: const Text('Restore from backup'),
                                ),
                                FilledButton.icon(
                                  onPressed: _isFinalizing ? null : _finalize,
                                  icon: _isFinalizing
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.check, size: 18),
                                  label: const Text('Continue'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),
                      // Vanity callsign generator — search for a callsign that
                      // contains letters the user likes (e.g. their initials).
                      Text(
                        'Custom callsign (optional)',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Search for a callsign containing letters you like — '
                        'it tries random identities until one matches. Longer '
                        'patterns take much longer to find.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _patternController,
                              enabled: !_vanityRunning && !_isFinalizing,
                              textCapitalization: TextCapitalization.characters,
                              maxLength: 4,
                              decoration: const InputDecoration(
                                labelText: 'Pattern (1–4 chars)',
                                hintText: 'e.g. CAT',
                                border: OutlineInputBorder(),
                                counterText: '',
                              ),
                              onChanged: (_) => setState(() {}),
                              onSubmitted: (_) {
                                if (!_vanityRunning &&
                                    _patternController.text.trim().isNotEmpty) {
                                  _startVanity();
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            onPressed: _isFinalizing
                                ? null
                                : (_vanityRunning
                                    ? _stopVanity
                                    : (_patternController.text.trim().isEmpty
                                        ? null
                                        : _startVanity)),
                            icon: Icon(
                                _vanityRunning ? Icons.stop : Icons.search,
                                size: 18),
                            label: Text(_vanityRunning ? 'Stop' : 'Search'),
                          ),
                        ],
                      ),
                      if (_vanityRunning || _vanityTried > 0) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            if (_vanityRunning) ...[
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Text(
                              'Tried $_vanityTried keys · '
                              '${_fmtElapsed(_vanityElapsed)}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (_vanityMatches.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Tap a match to use it:',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final m in _vanityMatches)
                              ChoiceChip(
                                label: Text(
                                  m.callsign,
                                  style:
                                      const TextStyle(fontFamily: 'monospace'),
                                ),
                                selected: _preview.callsign == m.callsign,
                                onSelected: (_) => _selectVanity(m),
                              ),
                          ],
                        ),
                      ],

                      const SizedBox(height: 20),
                      Text(
                        'Nickname (optional)',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _nicknameController,
                        decoration: const InputDecoration(
                          hintText: 'Your display name',
                          border: OutlineInputBorder(),
                        ),
                      ),

                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: cs.errorContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.error_outline,
                                  size: 20, color: cs.error),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: TextStyle(color: cs.onErrorContainer),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.secondaryContainer.withAlpha(128),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_outline,
                                size: 20, color: cs.secondary),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Your profile lives at '
                                '~/.local/share/aurora/devices/<id>/. '
                                'Back it up by copying the folder. Your '
                                'nsec is stored inside profiles.json — keep '
                                'it secret.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
