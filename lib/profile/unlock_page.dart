/*
 * UnlockPage — the gate in front of an encrypted profile, shown by the
 * launcher root whenever the active profile has a keyslot but no keys in
 * the keyring (docs/plan-encrypted-storage.md).
 *
 * Two shapes, depending on how the profile is locked:
 *
 *   device-key profiles (the default): no password exists. The page asks
 *     the phone — fingerprint, face, or the screen lock — and unlocks from
 *     the OS keychain. Nothing to type, nothing to forget.
 *   password profiles (the user added one): a password field. It may
 *     contain anything the keyboard can type, emoji included — it is
 *     NFC-normalized and mixed with the profile's nsec in ProfileCrypto.
 */

import 'dart:async';

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
  bool _remember = true;
  bool _busy = false;
  bool _ready = false; // which shape of the page we are
  bool _deviceKey = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _decideMode();
  }

  Future<void> _decideMode() async {
    final device = await ProfileEncryption.usesDeviceKey(widget.profile.id);
    if (!mounted) return;
    setState(() {
      _deviceKey = device;
      _ready = true;
    });
    // A device-key profile has nothing to ask the user for: go straight to
    // the phone's own prompt.
    if (device) unawaited(_biometricUnlock());
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    // Services that were held back by the lock can start now.
    await PermissionGate.startGatedServices();
    if (mounted) widget.onUnlocked();
  }

  Future<void> _biometricUnlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await ProfileEncryption.unlockWithBiometrics(
      widget.profile.id,
      reason: 'Unlock ${widget.profile.displayName}',
    );
    if (ok) {
      await _finish();
      return;
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _error = 'Not recognised — try again';
      });
    }
  }

  Future<void> _passwordUnlock() async {
    final pw = _password.text;
    if (pw.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ProfileEncryption.unlock(widget.profile.id, pw,
          remember: _remember);
      await _finish();
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
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
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
                  if (_deviceKey) ..._deviceKeyBody() else ..._passwordBody(),
                  if (_error != null && _deviceKey) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _deviceKeyBody() => [
        const Icon(Icons.fingerprint, size: 48, color: Colors.white54),
        const SizedBox(height: 12),
        const Text('This profile is encrypted',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text(
          'Unlock it with your fingerprint or screen lock.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _busy ? null : _biometricUnlock,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.fingerprint),
            label: const Text('Unlock'),
          ),
        ),
      ];

  List<Widget> _passwordBody() => [
        const Icon(Icons.lock_outline, size: 20, color: Colors.white54),
        const SizedBox(height: 8),
        const Text('This profile is encrypted'),
        const SizedBox(height: 16),
        TextField(
          controller: _password,
          obscureText: _obscure,
          enabled: !_busy,
          autofocus: true,
          onSubmitted: (_) => _passwordUnlock(),
          decoration: InputDecoration(
            labelText: 'Password',
            helperText: 'Emoji welcome 🔑',
            errorText: _error,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _remember,
          onChanged:
              _busy ? null : (v) => setState(() => _remember = v ?? false),
          title: const Text('Keep unlocked on this device'),
          subtitle: const Text(
            'Lets messages arrive in the background and skips this screen. '
            'The key is stored on this device.',
            style: TextStyle(fontSize: 12),
          ),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _busy ? null : _passwordUnlock,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Unlock'),
          ),
        ),
      ];
}
