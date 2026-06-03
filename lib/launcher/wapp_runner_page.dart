part of 'launcher.dart';

// ── Wapp Runner (generic WASM module runner) ─────────────────────────

class WappRunnerPage extends StatefulWidget {
  final String? title;
  final String? wasmPath;

  const WappRunnerPage({super.key, this.title, this.wasmPath});

  @override
  State<WappRunnerPage> createState() => _WappRunnerPageState();
}

class _WappRunnerPageState extends State<WappRunnerPage> {
  final _engine = WappEngine();
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _tickTimer;
  String _status = 'Not loaded';

  @override
  void initState() {
    super.initState();
    // Auto-load if a wasm path was provided
    if (widget.wasmPath != null) {
      _loadWasmFromFile(widget.wasmPath!);
    }
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _engine.dispose();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadWasmFromFile(String path) async {
    setState(() => _status = 'Loading...');
    try {
      final sep = platform.pathSeparator;
      final slashIdx = path.lastIndexOf(sep);
      if (slashIdx < 0) {
        setState(() => _status = 'Invalid path: $path');
        return;
      }
      final dir = path.substring(0, slashIdx);
      final file = path.substring(slashIdx + 1);
      final bytes = await makeFilesystemStorage(dir).readBytes(file);
      if (bytes == null) {
        setState(() => _status = 'wasm not found: $path');
        return;
      }
      await _startEngine(bytes);
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _loadWasmFromAsset() async {
    setState(() => _status = 'Loading...');
    try {
      final bytes = await rootBundle.load('assets/hello_world.wasm');
      await _startEngine(bytes.buffer.asUint8List());
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _startEngine(Uint8List bytes) async {
    await _engine.load(bytes);
    _engine.init();

    final interval = _engine.tickIntervalMs;
    _tickTimer = Timer.periodic(Duration(milliseconds: interval), (_) {
      _engine.tick();
      _engine.handleEvent();
      setState(() {});
      _scrollToBottom();
    });

    setState(() => _status = 'Running (tick every ${interval}ms)');
    _scrollToBottom();
  }

  void _sendMessage() {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;
    _engine.sendMessage(text);
    _engine.handleEvent();
    _msgController.clear();
    setState(() {});
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Color _levelColor(int level) {
    return switch (level) {
      0 => Colors.grey,
      1 => Colors.lightBlueAccent,
      2 => Colors.orange,
      3 => Colors.redAccent,
      _ => Colors.white,
    };
  }

  @override
  Widget build(BuildContext context) {
    final outbox = _engine.drainOutbox();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? 'Wapp Runner'),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: _engine.isLoaded ? Colors.green.withAlpha(30) : Colors.grey.withAlpha(30),
            child: Row(
              children: [
                Icon(
                  _engine.isLoaded ? Icons.check_circle : Icons.circle_outlined,
                  size: 14,
                  color: _engine.isLoaded ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_status, style: const TextStyle(fontSize: 13)),
                ),
                if (!_engine.isLoaded && widget.wasmPath == null)
                  TextButton.icon(
                    onPressed: _loadWasmFromAsset,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Load hello_world.wasm'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: _engine.logs.length + outbox.length,
              itemBuilder: (context, index) {
                if (index < _engine.logs.length) {
                  final log = _engine.logs[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: '[${log.levelName}] ',
                          style: TextStyle(
                            color: _levelColor(log.level),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            fontFamily: 'monospace',
                          ),
                        ),
                        TextSpan(
                          text: log.message,
                          style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                        ),
                      ]),
                    ),
                  );
                } else {
                  final msg = outbox[index - _engine.logs.length];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(
                      '<< $msg',
                      style: const TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: Colors.amber,
                      ),
                    ),
                  );
                }
              },
            ),
          ),
          if (_engine.isLoaded)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.grey.shade800)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _msgController,
                      decoration: const InputDecoration(
                        hintText: 'Send message to module...',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _sendMessage,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
