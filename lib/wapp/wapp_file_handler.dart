/*
 * WappFileHandler — one `provides.file_handlers` entry from a wapp
 * manifest. Declares which file extensions / MIME types a wapp can
 * open, the verb to show in an "Open with…" picker, and the modes it
 * supports. Ported from the root geogram manifest model.
 */

class WappFileHandler {
  /// Extensions accepted, lowercased and without the leading dot. The
  /// literal "*" is a catch-all (lowest priority).
  final List<String> extensions;

  /// MIME types accepted. "type/*" wildcards are honoured.
  final List<String> mimeTypes;

  /// Short verb for the picker ("Play", "Edit", "Preview"). Falls back
  /// to the wapp's title when empty.
  final String title;

  /// Supported modes — "view" (default) and/or "edit". Unknown values
  /// pass through so new modes don't need an engine update.
  final List<String> modes;

  const WappFileHandler({
    this.extensions = const [],
    this.mimeTypes = const [],
    this.title = '',
    this.modes = const ['view'],
  });

  bool matchesExtension(String ext) {
    final normalized = ext.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    return extensions.contains(normalized) || extensions.contains('*');
  }

  bool matchesMime(String mime) {
    final m = mime.toLowerCase();
    for (final pattern in mimeTypes) {
      final pat = pattern.toLowerCase();
      if (pat == m) return true;
      if (pat.endsWith('/*')) {
        final prefix = pat.substring(0, pat.length - 1);
        if (m.startsWith(prefix)) return true;
      }
      if (pat == '*/*' || pat == '*') return true;
    }
    return false;
  }

  bool supportsMode(String mode) {
    if (mode.isEmpty) return true;
    final lower = mode.toLowerCase();
    for (final m in modes) {
      if (m.toLowerCase() == lower) return true;
    }
    return false;
  }

  factory WappFileHandler.fromJson(Map<String, dynamic> json) {
    List<String> readList(dynamic v) {
      if (v is List) return v.whereType<String>().toList();
      if (v is String) return [v];
      return const [];
    }

    final exts = readList(json['extensions'])
        .map((e) => e.toLowerCase().replaceFirst(RegExp(r'^\.'), ''))
        .where((e) => e.isNotEmpty)
        .toList();
    final mimes = readList(json['mime'])
        .map((m) => m.toLowerCase())
        .where((m) => m.isNotEmpty)
        .toList();
    final modes = readList(json['modes']);
    return WappFileHandler(
      extensions: exts,
      mimeTypes: mimes,
      title: (json['title'] as String? ?? '').trim(),
      modes: modes.isEmpty ? const ['view'] : modes,
    );
  }
}
