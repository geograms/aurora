/*
 * FileFolderPicker — a self-contained file/folder navigator, ported (core UX)
 * from geogram/lib/widgets/file_folder_picker.dart but without its mirror/sync/
 * thumbnail/cache dependencies.
 *
 * One navigator shows BOTH files and folders. Tapping a folder navigates into
 * it; the system Back gesture (and the app-bar arrow) goes UP one folder and
 * only closes the picker at the root.
 *
 * Selection is always explicit and previewed: a persistent footer states
 * exactly what will happen ("Share this folder: Download" or "Add this file:
 * photo.jpg") next to the confirm button, so the user can never be unsure of
 * what is selected. Tapping a file selects it (the row highlights); with no
 * file selected the footer targets the folder you are currently inside.
 *
 * show() returns a [FilePickResult] (path + isDir) or null if cancelled.
 */
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/android_permissions_service.dart';
import '../platform/platform.dart' as platform;

class FilePickResult {
  final String path;
  final bool isDir;
  const FilePickResult(this.path, this.isDir);
}

class _Entry {
  final String path;
  final String name;
  final bool isDir;
  final int size;
  const _Entry(this.path, this.name, this.isDir, this.size);
}

class FileFolderPicker extends StatefulWidget {
  final String? initialDirectory;
  final String title;
  final bool allowFileSelect;
  final bool allowFolderSelect;

  const FileFolderPicker({
    super.key,
    this.initialDirectory,
    this.title = 'Select',
    this.allowFileSelect = true,
    this.allowFolderSelect = true,
  });

  static Future<FilePickResult?> show(
    BuildContext context, {
    String? initialDirectory,
    String title = 'Select',
    bool allowFileSelect = true,
    bool allowFolderSelect = true,
  }) {
    return Navigator.of(context).push<FilePickResult>(MaterialPageRoute(
      builder: (_) => FileFolderPicker(
        initialDirectory: initialDirectory,
        title: title,
        allowFileSelect: allowFileSelect,
        allowFolderSelect: allowFolderSelect,
      ),
    ));
  }

  @override
  State<FileFolderPicker> createState() => _FileFolderPickerState();
}

class _FileFolderPickerState extends State<FileFolderPicker> {
  late Directory _dir;
  List<_Entry> _entries = const [];
  bool _loading = true;
  String? _error;
  bool _needsAccess = false;

  /// Absolute path of the file the user tapped to select, or null when the
  /// current selection is "this folder". Cleared on navigation.
  String? _selectedFile;

  bool get _isAndroid => platform.platformName() == 'android';
  bool get _atRoot => _dir.path == '/' || _dir.path.isEmpty;

  @override
  void initState() {
    super.initState();
    _dir = Directory(widget.initialDirectory ?? _defaultRoot());
    _init();
  }

  String _defaultRoot() {
    if (_isAndroid) {
      for (final c in const ['/storage/emulated/0', '/sdcard']) {
        if (Directory(c).existsSync()) return c;
      }
      return '/';
    }
    final h = Platform.environment['HOME'];
    if (h != null && h.isNotEmpty && Directory(h).existsSync()) return h;
    return '/';
  }

  Future<void> _init() async {
    if (_isAndroid &&
        !await AndroidPermissionsService.instance.hasAllFilesAccess()) {
      setState(() {
        _loading = false;
        _needsAccess = true;
      });
      return;
    }
    _load();
  }

  void _load() {
    setState(() {
      _loading = true;
      _error = null;
      _needsAccess = false;
    });
    try {
      final dirs = <_Entry>[];
      final files = <_Entry>[];
      for (final e in _dir.listSync(followLinks: false)) {
        final name = e.path.split('/').last;
        if (name.startsWith('.')) continue;
        if (e is Directory) {
          dirs.add(_Entry(e.path, name, true, 0));
        } else if (e is File) {
          int sz = 0;
          try {
            sz = e.lengthSync();
          } catch (_) {}
          files.add(_Entry(e.path, name, false, sz));
        }
      }
      dirs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _entries = [...dirs, ...files];
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Cannot open this folder${_isAndroid ? ' (permission?)' : ''}.';
      });
    }
  }

  void _enter(String path) {
    _dir = Directory(path);
    _selectedFile = null; // selection is folder-scoped; reset on navigation
    _load();
  }

  void _up() {
    if (_atRoot) {
      Navigator.of(context).pop();
      return;
    }
    final parent = _dir.parent.path;
    _enter(parent.isEmpty ? '/' : parent);
  }

  void _toggleFile(String path) {
    setState(() => _selectedFile = (_selectedFile == path) ? null : path);
  }

  void _confirm() {
    if (_selectedFile != null && widget.allowFileSelect) {
      Navigator.of(context).pop(FilePickResult(_selectedFile!, false));
    } else if (widget.allowFolderSelect) {
      Navigator.of(context).pop(FilePickResult(_dir.path, true));
    }
  }

  static String _human(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1073741824).toStringAsFixed(1)} GB';
  }

  String get _dirName {
    final p = _dir.path;
    if (p == '/storage/emulated/0' || p == '/sdcard') return 'Internal storage';
    if (p == '/storage') return 'Storage';
    if (p == '/' || p.isEmpty) return 'Device root';
    final n = p.split('/').last;
    return n.isEmpty ? p : n;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: Icon(_atRoot ? Icons.close : Icons.arrow_back),
            tooltip: _atRoot ? 'Cancel' : 'Up',
            onPressed: _up,
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.title, style: const TextStyle(fontSize: 16)),
              Text(_dir.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ],
          ),
          actions: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.sd_storage),
              tooltip: 'Go to',
              onSelected: _enter,
              itemBuilder: (_) => [
                for (final s in _shortcuts())
                  PopupMenuItem(value: s.$2, child: Text(s.$1)),
              ],
            ),
          ],
        ),
        body: _body(cs),
        bottomNavigationBar: _needsAccess ? null : _footer(cs),
      ),
    );
  }

  List<(String, String)> _shortcuts() {
    final out = <(String, String)>[];
    final h = Platform.environment['HOME'];
    if (_isAndroid) {
      out.add(('Internal storage', '/storage/emulated/0'));
      out.add(('SD / USB (/storage)', '/storage'));
    } else if (h != null && h.isNotEmpty) {
      out.add(('Home', h));
    }
    out.add(('Root /', '/'));
    return out;
  }

  /// Persistent footer: always states exactly what the confirm button will do,
  /// so the selection is never ambiguous.
  Widget _footer(ColorScheme cs) {
    final hasFile = _selectedFile != null && widget.allowFileSelect;
    // In file-only mode with nothing picked yet, the action is disabled and the
    // footer prompts the user to tap a file.
    final disabled = !hasFile && !widget.allowFolderSelect;

    final String caption;
    final String name;
    final IconData icon;
    final String button;
    if (hasFile) {
      caption = 'Add this file';
      name = _selectedFile!.split('/').last;
      icon = Icons.insert_drive_file;
      button = 'Add file';
    } else if (widget.allowFolderSelect) {
      caption = 'Share this folder';
      name = _dirName;
      icon = Icons.folder;
      button = 'Share folder';
    } else {
      caption = 'No file selected';
      name = 'Tap a file in the list to select it';
      icon = Icons.touch_app;
      button = 'Add file';
    }

    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          border: Border(top: BorderSide(color: cs.outlineVariant)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Row(
          children: [
            Icon(icon, color: disabled ? cs.onSurfaceVariant : cs.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(caption,
                      style: TextStyle(
                          fontSize: 11, color: cs.onSurfaceVariant)),
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              icon: Icon(hasFile ? Icons.check : Icons.share, size: 18),
              label: Text(button),
              onPressed: disabled ? null : _confirm,
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(ColorScheme cs) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_needsAccess) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                  'Aurora needs "All files access" to browse your storage.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  await AndroidPermissionsService.instance
                      .requestAllFilesAccess();
                  _init();
                },
                child: const Text('Grant access'),
              ),
            ],
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _up, child: const Text('Go up')),
          ]),
        ),
      );
    }
    return ListView(
      children: [
        if (!_atRoot)
          ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: const Text('.. (up)'),
            onTap: _up,
          ),
        for (final e in _entries)
          if (e.isDir)
            // Tapping a folder OPENS it (navigates in). The trailing chevron
            // reinforces that. To share a folder, open it then use the footer.
            ListTile(
              leading: Icon(Icons.folder, color: cs.primary),
              title: Text(e.name),
              trailing: Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              onTap: () => _enter(e.path),
            )
          else
            // Tapping a file SELECTS it: the row highlights and the footer
            // updates to "Add this file: <name>".
            ListTile(
              selected: _selectedFile == e.path,
              selectedTileColor: cs.primaryContainer.withAlpha(90),
              leading: Icon(
                _selectedFile == e.path
                    ? Icons.check_circle
                    : Icons.insert_drive_file_outlined,
                color: _selectedFile == e.path ? cs.primary : null,
              ),
              title: Text(e.name),
              subtitle: Text(_human(e.size)),
              enabled: widget.allowFileSelect,
              onTap: widget.allowFileSelect ? () => _toggleFile(e.path) : null,
            ),
      ],
    );
  }
}
