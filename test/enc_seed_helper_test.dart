/// Helper (not a real test): seeds an ENCRYPTED, LOCKED profile into the
/// current HOME so a live app boot can be pointed at it. Guarded by
/// AURORA_TEST_HOME=1 like the flow test. Deleted after Phase 4 validation
/// if it stops being useful.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

import 'package:aurora/profile/profile_encryption.dart';
import 'package:aurora/profile/profile_service.dart';

void main() {
  final isolated = Platform.environment['AURORA_TEST_HOME'] == '1';

  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });

  test('seed locked encrypted profile', () async {
    final service = ProfileService.instance;
    await service.load();
    final preview = service.generatePreview(nickname: 'Locked One');
    await service.saveAndActivate(preview);
    await ProfileEncryption.enable(preview.id, 'boot-test 🔒');
    await ProfileEncryption.lockNow(preview.id);
    expect(ProfileEncryption.isUnlocked(preview.id), isFalse);
    // ignore: avoid_print
    print('seeded locked profile ${preview.id}');
  }, skip: isolated ? false : 'set AURORA_TEST_HOME=1 with an isolated HOME');
}
