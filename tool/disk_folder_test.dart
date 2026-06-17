// Headless test for DiskFolderSource + CompositeFileSource: index a real temp
// directory by sha256, serve bytes from disk, exclude the key file/dotfiles, and
// fall through composite sources. Pure dart:io — no Flutter, no sqlite.
//
//   dart run tool/disk_folder_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:aurora/services/files/composite_file_source.dart';
import 'package:aurora/services/files/file_transfer.dart' show EmptyFileSource;
import 'package:aurora/services/folders/disk_folder.dart';

int _pass = 0, _fail = 0;
void check(String name, bool ok) {
  if (ok) {
    _pass++;
    stdout.writeln('  ok   $name');
  } else {
    _fail++;
    stdout.writeln('  FAIL $name');
  }
}

Uint8List _shaBytes(String s) =>
    Uint8List.fromList(crypto.sha256.convert(s.codeUnits).bytes);

void main() {
  final dir = Directory.systemTemp.createTempSync('disk_folder_test');
  File('${dir.path}/song.mp3').writeAsStringSync('AUDIO-DATA-1');
  Directory('${dir.path}/album').createSync();
  File('${dir.path}/album/track.mp3').writeAsStringSync('AUDIO-DATA-2');
  File('${dir.path}/$kFolderKeyFile').writeAsStringSync('{"nsec":"SECRET"}');
  File('${dir.path}/.hidden').writeAsStringSync('ignore me');

  final src = DiskFolderSource(dir.path);
  final files = src.scan();

  check('indexes only real files (key file + dotfiles excluded)', files.length == 2);
  check('relative path name for nested file',
      files.any((f) => f.name == 'album/track.mp3'));
  check('top-level file name', files.any((f) => f.name == 'song.mp3'));
  check('key file never indexed', !files.any((f) => f.name.contains(kFolderKeyFile)));
  check('dotfile never indexed', !files.any((f) => f.name == '.hidden'));

  // Serve bytes from disk by content hash.
  final h1 = _shaBytes('AUDIO-DATA-1');
  final got = src.read(h1);
  check('serves file bytes from disk by sha', got != null && String.fromCharCodes(got) == 'AUDIO-DATA-1');
  check('has() true for held hash', src.has(h1));
  check('unknown hash -> null', src.read(_shaBytes('NOPE')) == null);

  // Composite falls through to the disk source.
  final comp = CompositeFileSource([const EmptyFileSource(), src]);
  final cgot = comp.read(_shaBytes('AUDIO-DATA-2'));
  check('composite serves from the disk source', cgot != null && String.fromCharCodes(cgot) == 'AUDIO-DATA-2');
  check('composite unknown -> null', comp.read(_shaBytes('NOPE')) == null);

  // Re-scan picks up a change (size + new hash).
  File('${dir.path}/song.mp3').writeAsStringSync('AUDIO-DATA-1-EDITED');
  src.scan();
  check('rescan reflects edited content', src.has(_shaBytes('AUDIO-DATA-1-EDITED')) && !src.has(h1));

  try {
    dir.deleteSync(recursive: true);
  } catch (_) {}
  stdout.writeln('\n$_pass passed, $_fail failed');
  exit(_fail == 0 ? 0 : 1);
}
