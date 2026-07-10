part of 'launcher.dart';

class _ConnectionIndicator extends StatefulWidget {
  const _ConnectionIndicator();

  @override
  State<_ConnectionIndicator> createState() => _ConnectionIndicatorState();
}

class _ConnectionIndicatorState extends State<_ConnectionIndicator> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _connectionColor();
    return Tooltip(
      message: _connectionLabel(),
      child: Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.38),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }

  Color _connectionColor() {
    final rns = RnsService.instance;
    if (!rns.isUp) return const Color(0xFF6B717E);
    final mode = rns.mode;
    if (mode.startsWith('tcp') &&
        (rns.connectedHubs.isNotEmpty || mode == 'tcpserver')) {
      return const Color(0xFF52C77E);
    }
    if (mode.startsWith('ble') || rns.isBleBridge) {
      return const Color(0xFF4A90E2);
    }
    return const Color(0xFF6B717E);
  }

  String _connectionLabel() {
    final rns = RnsService.instance;
    if (!rns.isUp) return 'Offline';
    if (rns.mode.startsWith('tcp') && rns.connectedHubs.isNotEmpty) {
      return 'Connected to ${rns.connectedHubs.length} hub(s)';
    }
    if (rns.mode == 'tcpserver') return 'Hub server active';
    if (rns.mode.startsWith('ble') || rns.isBleBridge) return 'BLE mesh';
    return 'Limited connectivity';
  }
}
