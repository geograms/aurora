// A wapp that ships in an update has to be findable.
//
// The behaviour worth protecting is the pair of opposites: a wapp that arrives
// after the user already had a launcher is announced, and one that was there
// all along is not. Getting the second half wrong badges the whole grid on a
// fresh install, which trains the user to ignore the badge.

import 'package:aurora/services/new_wapp_tracker.dart';
import 'package:aurora/services/preferences_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTest();
    NewWappTracker.instance.fresh.value = {};
  });

  test('the first look at a profile announces nothing', () async {
    await NewWappTracker.instance.reconcile(['chat', 'social', 'xprs']);
    expect(NewWappTracker.instance.fresh.value, isEmpty,
        reason: 'everything installed at once is not news');
    expect(NewWappTracker.instance.isNew('xprs'), isFalse);
  });

  test('a wapp that arrives later is new', () async {
    await NewWappTracker.instance.reconcile(['chat', 'social']);
    await NewWappTracker.instance.reconcile(['chat', 'social', 'xprs']);
    expect(NewWappTracker.instance.fresh.value, {'xprs'});
  });

  test('it stays new across a restart until it is opened', () async {
    await NewWappTracker.instance.reconcile(['chat']);
    await NewWappTracker.instance.reconcile(['chat', 'xprs']);

    // A restart: the tracker forgets, the preference does not.
    NewWappTracker.instance.fresh.value = {};
    await NewWappTracker.instance.reconcile(['chat', 'xprs']);
    expect(NewWappTracker.instance.fresh.value, {'xprs'},
        reason: 'a launcher the user never opened has not been acknowledged');

    await NewWappTracker.instance.markSeen('xprs');
    expect(NewWappTracker.instance.fresh.value, isEmpty);

    await NewWappTracker.instance.reconcile(['chat', 'xprs']);
    expect(NewWappTracker.instance.fresh.value, isEmpty,
        reason: 'opening it is the acknowledgement, and it sticks');
  });

  test('uninstalling a still-new wapp takes the flag with it', () async {
    await NewWappTracker.instance.reconcile(['chat']);
    await NewWappTracker.instance.reconcile(['chat', 'xprs']);
    await NewWappTracker.instance.reconcile(['chat']);
    expect(NewWappTracker.instance.fresh.value, isEmpty);
  });

  test('the notifier only fires when the set actually changes', () async {
    await NewWappTracker.instance.reconcile(['chat']);
    var fires = 0;
    void listener() => fires++;
    NewWappTracker.instance.fresh.addListener(listener);
    await NewWappTracker.instance.reconcile(['chat']);
    await NewWappTracker.instance.reconcile(['chat']);
    expect(fires, 0, reason: 'an idle rescan must not rebuild the launcher');
    await NewWappTracker.instance.reconcile(['chat', 'xprs']);
    expect(fires, 1);
    NewWappTracker.instance.fresh.removeListener(listener);
  });
}
