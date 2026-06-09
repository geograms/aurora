// Robot tab — an AI chat that proposes edits to the wapp being edited.
// Part of the wapp_page library (extension on _WappPageState) so it can read
// the editor's `_fieldValues` and drive its tab controller. The chat state +
// streaming live in [RobotChatController]; the AI backends live in lib/ai/.

part of '../wapp/wapp_page.dart';

extension _WappRobot on _WappPageState {
  Widget _buildRobotScreen() {
    final cs = Theme.of(context).colorScheme;
    final robot = _robot ??= RobotChatController();
    return Column(
      children: [
        const _RobotConfigBar(),
        Divider(height: 1, color: cs.outlineVariant.withAlpha(80)),
        Expanded(
          child: ListenableBuilder(
            listenable: robot,
            builder: (context, _) => Column(
              children: [
                Expanded(child: _buildRobotConversation(robot, cs)),
                Divider(height: 1, color: cs.outlineVariant.withAlpha(80)),
                _buildRobotInput(robot, cs),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRobotConversation(RobotChatController robot, ColorScheme cs) {
    if (robot.turns.isEmpty &&
        robot.streaming.isEmpty &&
        robot.error == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Ask the robot to change this wapp — e.g. “add a Save button to the '
            'home screen” or “make module_tick log the time”. It can propose '
            'updated main.c / home.ui.json, which you Apply, then Compile.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
          ),
        ),
      );
    }

    final items = <Widget>[
      for (final t in robot.turns)
        _robotBubble(t.role, t.text, cs,
            showApply: t.role == AiRole.assistant),
      if (robot.streaming.isNotEmpty)
        _robotBubble(AiRole.assistant, robot.streaming, cs, streaming: true),
      if (robot.error != null) _robotError(robot.error!, cs),
    ];

    // reverse:true pins the newest message to the bottom as it streams.
    return ListView(
      reverse: true,
      padding: const EdgeInsets.all(12),
      children: items.reversed.toList(),
    );
  }

  Widget _robotBubble(AiRole role, String text, ColorScheme cs,
      {bool streaming = false, bool showApply = false}) {
    final isUser = role == AiRole.user;
    final files =
        showApply ? RobotChatController.parseProposedFiles(text) : const [];
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: isUser ? cs.primaryContainer : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              streaming ? '$text▌' : text,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: isUser ? cs.onPrimaryContainer : cs.onSurface,
              ),
            ),
            for (final f in files)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: () => _applyRobotEdit(f),
                    icon: const Icon(Icons.check, size: 16),
                    label: Text('Apply → ${f.name}'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _robotError(String message, ColorScheme cs) => Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: cs.errorContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: cs.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: TextStyle(fontSize: 12, color: cs.onErrorContainer)),
            ),
          ],
        ),
      );

  Widget _buildRobotInput(RobotChatController robot, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            // Enter submits; Shift+Enter inserts a newline. We intercept the
            // key on the wrapping Focus so Enter doesn't add a line break to
            // the multiline field.
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.enter &&
                    !HardwareKeyboard.instance.isShiftPressed) {
                  if (!robot.busy) _sendRobotMessage(robot);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: _robotInput,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Ask the robot to change this wapp…  '
                      '(Enter to send, Shift+Enter for a new line)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          robot.busy
              ? IconButton.filled(
                  onPressed: robot.stop,
                  icon: const Icon(Icons.stop),
                  tooltip: 'Stop',
                )
              : IconButton.filled(
                  onPressed: () => _sendRobotMessage(robot),
                  icon: const Icon(Icons.send),
                  tooltip: 'Send',
                ),
        ],
      ),
    );
  }

  void _sendRobotMessage(RobotChatController robot) {
    final text = _robotInput.text;
    if (text.trim().isEmpty || robot.busy) return;
    _robotInput.clear();
    robot.send(
      text,
      currentMainC: (_fieldValues['source'] as String?) ?? '',
      currentUiJson: (_fieldValues['source_ui'] as String?) ?? '',
    );
  }

  /// Write an AI-proposed file into the editor's in-memory fields and jump to
  /// the relevant tab. The user still Compiles/Saves through the normal
  /// controls — nothing touches disk here.
  void _applyRobotEdit(ProposedFile f) {
    final name = f.name.toLowerCase();
    String? jumpTo;
    setState(() {
      if (name == 'main.c' || name == 'source') {
        _fieldValues['source'] = f.content;
        _fieldValues['source__readonly'] = false;
        _activeEditFile = 'source';
        jumpTo = 'Files';
      } else if (name.endsWith('.ui.json') || name == 'source_ui') {
        _fieldValues['source_ui'] = f.content;
        jumpTo = 'UI';
      }
    });
    if (jumpTo != null) _jumpToEditorScreen(jumpTo!);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Applied ${f.name} — Compile/Save to keep it.')),
    );
  }

  /// Switch the editor's TabBar to the screen with [name] (e.g. 'Files', 'UI'),
  /// matching either the raw screen name or its localized label.
  void _jumpToEditorScreen(String name) {
    final ctrl = _editorTabController;
    if (ctrl == null) return;
    final lower = name.toLowerCase();
    final idx = _editorScreenNames.indexWhere((n) =>
        n.toLowerCase() == lower || _i18n.resolve(n).toLowerCase() == lower);
    if (idx >= 0 && idx < ctrl.length) ctrl.animateTo(idx);
  }
}

/// Collapsible AI settings shown above the chat. Reads/writes the
/// `ai.*` PreferencesService keys directly; defaults come from the selected
/// provider when a field is left blank.
class _RobotConfigBar extends StatefulWidget {
  const _RobotConfigBar();

  @override
  State<_RobotConfigBar> createState() => _RobotConfigBarState();
}

class _RobotConfigBarState extends State<_RobotConfigBar> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  String _providerId = 'ollama';

  PreferencesService? get _prefs => PreferencesService.instanceSync;

  @override
  void initState() {
    super.initState();
    final p = _prefs;
    _providerId = p?.aiProviderId ?? 'ollama';
    _baseUrl = TextEditingController(text: p?.aiBaseUrl ?? '');
    _model = TextEditingController(text: p?.aiModel ?? '');
    _apiKey = TextEditingController(text: p?.aiApiKey ?? '');
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final provider = aiProviderById(_providerId);
    final modelLabel = _model.text.isEmpty ? provider.defaultModel : _model.text;
    return ExpansionTile(
      leading: Icon(Icons.smart_toy_outlined, color: cs.primary),
      title: const Text('AI provider'),
      subtitle: Text('${provider.label} · $modelLabel',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        DropdownButtonFormField<String>(
          initialValue: _providerId,
          isExpanded: true,
          decoration: const InputDecoration(
              labelText: 'Provider', isDense: true),
          items: [
            for (final p in aiProviders)
              DropdownMenuItem(value: p.id, child: Text(p.label)),
          ],
          onChanged: (v) {
            if (v == null) return;
            // Preconfigure the endpoint + model for the chosen provider so
            // OpenAI / Claude / DeepSeek work without hunting for the URL.
            final p = aiProviderById(v);
            setState(() {
              _providerId = v;
              _baseUrl.text = p.defaultBaseUrl;
              _model.text = p.defaultModel;
            });
            _prefs
              ?..aiProviderId = v
              ..aiBaseUrl = p.defaultBaseUrl
              ..aiModel = p.defaultModel;
          },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _baseUrl,
          decoration: InputDecoration(
            labelText: 'Base URL',
            hintText: provider.defaultBaseUrl,
            isDense: true,
          ),
          onChanged: (v) => _prefs?.aiBaseUrl = v,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _model,
          decoration: InputDecoration(
            labelText: 'Model',
            hintText: provider.defaultModel,
            isDense: true,
          ),
          onChanged: (v) {
            _prefs?.aiModel = v;
            setState(() {}); // refresh the subtitle
          },
        ),
        if (provider.requiresApiKey) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration:
                const InputDecoration(labelText: 'API key', isDense: true),
            onChanged: (v) => _prefs?.aiApiKey = v,
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            provider.isLocal
                ? 'Runs locally — no internet, no API key.'
                : 'Online API — sends the wapp\'s files to the provider.',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
