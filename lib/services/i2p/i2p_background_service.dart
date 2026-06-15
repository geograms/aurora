/*
 * I2pBackgroundService — registers the I2P node as a governable background
 * process. Because it goes through the BackgroundService template + the task
 * monitor's governor, the node is automatically PAUSED on CPU overload (tick/
 * budget governor) or low battery (PowerGovernor -> pauseAllNonCritical), and
 * RESUMED when pressure clears — via onPause()/onResume() which tear down and
 * rebuild the node's tunnels in its background isolate.
 *
 * Priority is normal (pausable). The node itself runs in a worker isolate
 * (I2pWorker), so it never blocks the UI isolate.
 */
import '../../models/monitored_task.dart';
import '../background_service.dart';
import 'i2p_service.dart';

class I2pBackgroundService extends BackgroundService {
  I2pBackgroundService()
      : super(
          id: 'i2p.node',
          name: 'I2P node',
          serviceName: 'services',
          interval: const Duration(minutes: 5),
          priority: TaskPriority.normal, // pausable under CPU / battery pressure
          description:
              'Pure-Dart I2P node (background isolate) for device-to-device sharing',
        );

  @override
  Future<void> onStart() async {
    await I2pService.instance.ensureStarted();
  }

  @override
  Future<void> onTick() async {
    // Light health check; the node has its own keepalive in the worker isolate.
    // If it died (not paused), bring it back up.
    if (!I2pService.instance.isUp && !I2pService.instance.isPaused) {
      await I2pService.instance.ensureStarted();
    }
  }

  @override
  Future<void> onPause() async {
    await I2pService.instance.pause();
  }

  @override
  Future<void> onResume() async {
    await I2pService.instance.resume();
  }

  @override
  Future<void> onStop() async {
    I2pService.instance.stop();
  }
}
