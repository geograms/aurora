/*
 * ProfileEditPage — customise an identity.
 *
 * Lets the user change the editable parts of a profile (nickname, description,
 * avatar colour and avatar image) and shows the read-only identity (callsign +
 * npub, with copy) plus a reveal/copy of the secret key for backup. Also
 * deletes the profile. Ported in spirit from geogram/lib/pages/profile_page.dart
 * but adapted to Aurora's [IwiProfile] + [ProfileService].
 */

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'iwi_profile.dart';
import 'identity_backup.dart';
import 'profile_avatar.dart';
import 'profile_service.dart';
import '../services/android_permissions_service.dart';
import '../services/preferences_service.dart';

class ProfileEditPage extends StatefulWidget {
  final IwiProfile profile;
  const ProfileEditPage({super.key, required this.profile});

  @override
  State<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends State<ProfileEditPage> {
  late IwiProfile _p;
  late final TextEditingController _nickname;
  late final TextEditingController _description;
  bool _revealKey = false;
  bool _saving = false;

  // Survives-uninstall identity backup status.
  String? _backupPath;
  bool _backupExists = false;
  bool _backupEncrypted = false;
  bool _backupBusy = false;

  @override
  void initState() {
    super.initState();
    _p = widget.profile;
    _nickname = TextEditingController(text: _p.nickname);
    _description = TextEditingController(text: _p.description);
    _refreshBackupStatus();
  }

  Future<void> _refreshBackupStatus() async {
    final path = await IdentityBackup.instance.backupPath();
    final exists = await IdentityBackup.instance.backupExists();
    final enc = exists ? await IdentityBackup.instance.isEncrypted() : false;
    if (!mounted) return;
    setState(() {
      _backupPath = path;
      _backupExists = exists;
      _backupEncrypted = enc;
    });
  }

  Future<void> _backupNow() async {
    setState(() => _backupBusy = true);
    if (!await AndroidPermissionsService.instance.hasAllFilesAccess()) {
      final ok =
          await AndroidPermissionsService.instance.requestAllFilesAccess();
      if (!ok) {
        if (mounted) {
          setState(() => _backupBusy = false);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Storage access is needed to save the backup.')));
        }
        return;
      }
    }
    final pass =
        PreferencesService.instanceSync?.identityBackupPassphrase ?? '';
    await IdentityBackup.instance
        .backupAll(ProfileService.instance.profiles, passphrase: pass);
    await _refreshBackupStatus();
    if (!mounted) return;
    setState(() => _backupBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Identity backed up')));
  }

  /// Set/clear the backup passphrase, then re-write the backup. An empty
  /// passphrase removes encryption (plaintext backup).
  Future<void> _changePassphrase() async {
    final prefs = PreferencesService.instanceSync;
    final controller =
        TextEditingController(text: prefs?.identityBackupPassphrase ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backup passphrase'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Encrypt the backup with a passphrase. Leave blank for a '
              'plaintext backup. If you forget it, the backup cannot be '
              'restored — there is no recovery.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'Passphrase (blank = none)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return; // cancelled
    prefs?.identityBackupPassphrase = result;
    await _backupNow();
  }

  @override
  void dispose() {
    _nickname.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    const group = XTypeGroup(
      label: 'images',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return;
    // Store inside the profile's own folder so it travels with the identity.
    await ProfileService.instance
        .storageForProfile(_p.id)
        .writeBytes('avatar.png', bytes);
    setState(() => _p = _p.copyWith(avatar: 'avatar.png'));
  }

  void _removeAvatar() => setState(() => _p = _p.copyWith(avatar: ''));

  Future<void> _save() async {
    setState(() => _saving = true);
    final edited = _p.copyWith(
      nickname: _nickname.text.trim(),
      description: _description.text.trim(),
    );
    await ProfileService.instance.update(edited);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Profile saved')));
    Navigator.of(context).pop(true);
  }


  void _copy(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$label copied')));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit profile'),
        actions: [
          IconButton(
            tooltip: 'Save',
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Avatar + change/remove.
          Center(
            child: Column(
              children: [
                ProfileAvatar(profile: _p, size: 96),
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.photo_camera_outlined, size: 18),
                      label: const Text('Change photo'),
                      onPressed: _pickAvatar,
                    ),
                    if (_p.avatar.isNotEmpty)
                      TextButton.icon(
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('Remove'),
                        onPressed: _removeAvatar,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nickname,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Nickname',
              hintText: _p.callsign,
              helperText: 'Shown instead of your callsign. Leave blank to use '
                  'the callsign.',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _description,
            maxLines: 3,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: 'About',
              hintText: 'A short bio or status (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text('Avatar colour', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final name in kProfileColors)
                _ColorDot(
                  color: profileColor(_p.copyWith(color: name)),
                  selected: _p.color == name,
                  onTap: () => setState(() => _p = _p.copyWith(color: name)),
                ),
              _ColorDot(
                color: profileColor(_p.copyWith(color: '')),
                selected: _p.color.isEmpty,
                label: 'auto',
                onTap: () => setState(() => _p = _p.copyWith(color: '')),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Read-only identity.
          _IdentityRow(
            label: 'Callsign',
            value: _p.callsign,
            mono: true,
            onCopy: () => _copy('Callsign', _p.callsign),
          ),
          _IdentityRow(
            label: 'Public key (npub)',
            value: _p.npub,
            mono: true,
            onCopy: () => _copy('npub', _p.npub),
          ),
          const SizedBox(height: 8),
          // Secret key — hidden behind a reveal, for backup/export only.
          Card(
            color: cs.errorContainer.withValues(alpha: 0.3),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.key, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Secret key (nsec)',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      TextButton(
                        onPressed: () =>
                            setState(() => _revealKey = !_revealKey),
                        child: Text(_revealKey ? 'Hide' : 'Reveal'),
                      ),
                    ],
                  ),
                  if (_revealKey) ...[
                    SelectableText(
                      _p.nsec,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy secret key'),
                          onPressed: () => _copy('Secret key', _p.nsec),
                        ),
                      ],
                    ),
                  ],
                  const Text(
                    'Anyone with this key controls this identity. Back it up '
                    'somewhere safe and never share it.',
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Survives-uninstall backup: keeps the nsec on phone storage so a
          // reinstall / data wipe can restore the identity.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.backup_outlined, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Identity backup',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      Text(
                        _backupExists
                            ? (_backupEncrypted ? 'Encrypted' : 'Plaintext')
                            : 'Not yet saved',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _backupPath == null
                        ? 'Grant storage access to keep a copy that survives '
                            'uninstalling the app.'
                        : 'Saved to:\n$_backupPath',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _backupBusy ? null : _backupNow,
                        icon: _backupBusy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.save_alt, size: 16),
                        label: const Text('Back up now'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _backupBusy ? null : _changePassphrase,
                        icon: const Icon(Icons.lock_outline, size: 16),
                        label: Text(_backupEncrypted
                            ? 'Change passphrase'
                            : 'Add passphrase'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'A plaintext backup holds your secret key in the clear — '
                    'anyone with access to this phone\'s storage can read it. '
                    'Add a passphrase to encrypt it.',
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final Color color;
  final bool selected;
  final String? label;
  final VoidCallback onTap;
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? cs.onSurface : Colors.transparent,
            width: 3,
          ),
        ),
        child: label != null
            ? Text(label!,
                style: const TextStyle(color: Colors.white, fontSize: 10))
            : (selected
                ? const Icon(Icons.check, color: Colors.white, size: 20)
                : null),
      ),
    );
  }
}

class _IdentityRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  final VoidCallback onCopy;
  const _IdentityRow({
    required this.label,
    required this.value,
    required this.onCopy,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 11, color: cs.onSurfaceVariant)),
                SelectableText(
                  value,
                  style: TextStyle(
                      fontSize: 12,
                      fontFamily: mono ? 'monospace' : null),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 16),
            tooltip: 'Copy',
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}
