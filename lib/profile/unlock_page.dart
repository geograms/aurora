/*
 * UnlockPage — password gate for an encrypted profile, shown by the
 * launcher root before LauncherPage whenever the active profile has a
 * keyslot but no keys in the keyring (docs/plan-encrypted-storage.md,
 * Phase 4).
 *
 * The password may contain anything the keyboard can type, emoji
 * included — it is NFC-normalized and mixed with the profile's nsec in
 * ProfileCrypto. "Keep unlocked on this device" stores the derived keys
 * app-private so background services and the next launch skip this page.
 */

import 'package:flutter/material.dart';

import '../services/permission_gate.dart';
import 'iwi_profile.dart';
import 'profile_avatar.dart';
import 'profile_crypto.dart';
import 'profile_encryption.dart';

class UnlockPage extends StatefulWidget {
  final IwiProfile profile;
  final VoidCallback onUnlocked;
  const UnlockPage(
      {super.key, required this.profile, required this.onUnlocked});

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  final _password = TextEditingController();
  bool _obscure = true;
  bool _remember = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final pw = _password.text;
    if (pw.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ProfileEncryption.unlock(widget.profile.id, pw,
          remember: _remember);
      // Services that were held back by the lock can start now.
      await PermissionGate.startGatedServices();
      if (mounted) widget.onUnlocked();
    } on WrongProfilePassword {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Wrong password';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Unlock failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ProfileAvatar(profile: p, size: 80),
                const SizedBox(height: 16),
                Text(p.displayName,
                    style: Theme.of(context).textTheme.titleLarge),
                Text(p.callsign,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.white54)),
                const SizedBox(height: 24),
                const Icon(Icons.lock_outline, size: 20, color: Colors.white54),
                const SizedBox(height: 8),
                const Text('This profile is encrypted'),
                const SizedBox(height: 16),
                TextField(
                  controller: _password,
                  obscureText: _obscure,
                  enabled: !_busy,
                  autofocus: true,
                  onSubmitted: (_) => _unlock(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    helperText: 'Emoji welcome 🔑',
                    errorText: _error,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: _remember,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _remember = v ?? false),
                  title: const Text('Keep unlocked on this device'),
                  subtitle: const Text(
                    'Lets messages arrive in the background and skips '
                    'this screen. The key is stored on this device.',
                    style: TextStyle(fontSize: 12),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _unlock,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Unlock'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
