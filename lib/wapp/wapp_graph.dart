// Native node-link graph widget for the generic GeoUI `$type:"graph"` group.
// Drawn entirely with a CustomPainter (no webview, no web). The expensive part —
// laying out the nodes — runs in a BACKGROUND ISOLATE (Isolate.run); the UI
// thread only tweens to the returned positions and paints, so it never blocks
// even with thousands of nodes. Interaction (pan / pinch / scroll-zoom / tap)
// mirrors the slippy map in wapp_maps.dart.
//
// All chrome lives in this widget as full-height side panels (no popups): a
// node detail panel, a hub device-list (tap a hub → its peers; tap a peer →
// select it on the graph), a bootstrap-hub manager, and a settings panel —
// reached from a compact icon row at the top-right. Clustering keeps it
// scalable: hubs collapse their peers behind a "⊕N" badge by default.
//
// Part of the wapp_page library — see wapp_page.dart.
part of 'wapp_page.dart';

// Palette (GitHub-dark to match the host).
const _gBg = Color(0xFF0D1117);
const _gPanel = Color(0xFF161B22);
const _gBorder = Color(0xFF30363D);
const _gFg = Color(0xFFC9D1D9);
const _gMuted = Color(0xFF8B949E);
const _gSelf = Color(0xFF58A6FF);
const _gHub = Color(0xFFD29922);
const _gGeo = Color(0xFF3FB950);
const _gGeneric = Color(0xFF6E7681);

// ── Layout, computed off the main thread ───────────────────────────────────
// Pure, top-level (isolate-safe); invoked with Isolate.run. Self at the centre;
// hubs on a ring; self's direct neighbours on an inner ring; each expanded hub's
// peers fanned onto concentric arcs around that hub. Deterministic O(n) — no
// iterative simulation to burn CPU.
Map<String, dynamic> _computeGraphLayout(Map<String, dynamic> req) {
  final nodes = (req['nodes'] as List).cast<Map>();
  final w = (req['w'] as num).toDouble();
  final h = (req['h'] as num).toDouble();
  final n = nodes.length;
  final ids = <String>[for (final nd in nodes) nd['id'] as String];
  final kind = <String>[for (final nd in nodes) (nd['kind'] as String?) ?? 'leaf'];
  final relayer = <String>[for (final nd in nodes) (nd['relayer'] as String?) ?? ''];
  final pos = Float32List(n * 2);
  final idIndex = {for (var i = 0; i < n; i++) ids[i]: i};

  final span = (w < h ? w : h);
  final rHub = span * 0.34;
  final rDirect = span * 0.15;

  var selfI = -1;
  final hubIdx = <int>[];
  final directIdx = <int>[];
  final byHub = <String, List<int>>{};
  for (var i = 0; i < n; i++) {
    if (kind[i] == 'self') {
      selfI = i;
    } else if (kind[i] == 'hub') {
      hubIdx.add(i);
    } else if (relayer[i].isEmpty) {
      directIdx.add(i);
    } else {
      (byHub[relayer[i]] ??= <int>[]).add(i);
    }
  }

  void place(int i, double x, double y) {
    pos[i * 2] = x;
    pos[i * 2 + 1] = y;
  }

  if (selfI >= 0) place(selfI, 0, 0);
  for (var k = 0; k < hubIdx.length; k++) {
    final a = (2 * pi * k / (hubIdx.isEmpty ? 1 : hubIdx.length)) - pi / 2;
    place(hubIdx[k], cos(a) * rHub, sin(a) * rHub);
  }
  for (var k = 0; k < directIdx.length; k++) {
    final a = 2 * pi * k / (directIdx.isEmpty ? 1 : directIdx.length);
    place(directIdx[k], cos(a) * rDirect, sin(a) * rDirect);
  }
  byHub.forEach((hubId, peers) {
    final hi = idIndex[hubId] ?? -1;
    final hx = hi >= 0 ? pos[hi * 2] : 0.0;
    final hy = hi >= 0 ? pos[hi * 2 + 1] : 0.0;
    final base = atan2(hy, hx); // outward from the centre
    const perRing = 12;
    const spread = 2.2; // ~126° fan
    for (var k = 0; k < peers.length; k++) {
      final ring = k ~/ perRing;
      final inRing = (peers.length - ring * perRing) < perRing
          ? (peers.length - ring * perRing)
          : perRing;
      final j = k % perRing;
      final frac = inRing <= 1 ? 0.5 : j / (inRing - 1);
      final a = base + (frac - 0.5) * spread;
      final rr = 72.0 + ring * 50.0;
      place(peers[k], hx + cos(a) * rr, hy + sin(a) * rr);
    }
  });

  return {'pos': pos, 'ids': ids};
}

// ── Parsed node/edge ───────────────────────────────────────────────────────
class _GNode {
  final String id;
  final String label;
  final String kind; // self | hub | leaf
  final bool geogram;
  final String relayer;
  final List<String> services;
  final int hops;
  final String via;
  final Map<String, dynamic> meta;
  final int childCount;
  // 1:1 reachability hint from the host: 'lxmf' | 'sf' | 'chat' | '' (see
  // graphSnapshot). Drives the detail-panel indicator + Message button.
  final String dm;
  // NOSTR npub (from meta), for distinguishing same-nickname devices. '' if none.
  final String npub;
  // First time we heard this node (epoch ms), and every hub/relayer it's been
  // heard through — for the device-row subtitle.
  final int firstSeenMs;
  final List<String> relayers;
  _GNode(Map<String, dynamic> m)
      : id = (m['id'] ?? '').toString(),
        label = (m['label'] ?? m['id'] ?? '').toString(),
        kind = (m['kind'] ?? 'leaf').toString(),
        dm = (m['dm'] ?? '').toString(),
        npub = ((m['meta'] as Map?)?['npub'] ?? '').toString(),
        geogram = m['geogram'] == true,
        relayer = (m['relayer'] ?? '').toString(),
        services =
            (m['services'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        hops = (m['hops'] as num?)?.toInt() ?? 0,
        via = (m['via'] ?? '').toString(),
        meta = (m['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
        firstSeenMs = ((m['meta'] as Map?)?['firstSeen'] as num?)?.toInt() ?? 0,
        relayers = ((m['meta'] as Map?)?['relayers'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        childCount = ((m['meta'] as Map?)?['children'] as num?)?.toInt() ?? 0;
}

class _GEdge {
  final String from, to, kind;
  _GEdge(this.from, this.to, this.kind);
}

// ── The widget ─────────────────────────────────────────────────────────────
class _GraphView extends StatefulWidget {
  const _GraphView({
    required this.data,
    required this.hubs,
    required this.onCommand,
    this.onPanelNav,
    this.onOpenProfile,
    this.avatarFor,
    super.key,
  });

  /// The latest {nodes,edges,…} snapshot (ui.graph.set).
  final ValueListenable<Map<String, dynamic>?> data;

  /// The configured bootstrap hubs [{endpoint,connected}] (ui.graph.hubs).
  final ValueListenable<List<dynamic>?> hubs;

  /// Forward a command (a JSON-able map with a "command" key) to the wapp.
  final void Function(Map<String, dynamic> cmd) onCommand;

  /// Report the open full-screen panel to the host so its app bar shows the
  /// panel title + a single back arrow (title null = graph, back closes panel).
  /// Avoids a second in-panel back arrow.
  final void Function(String? title, VoidCallback? back)? onPanelNav;

  /// Open the shared profile page for a geogram device (callsign + its NOSTR
  /// npub), with the reticulum facts (observed first-seen + reachable-via hubs).
  final void Function(String callsign, String? npub, int? firstSeenMs,
      List<String> reachableVia)? onOpenProfile;

  /// Resolve a peer's NOSTR npub to its profile avatar (cached kind-0 picture),
  /// for the device rows. Null = no avatar yet (row falls back to a dot).
  final ImageProvider? Function(String npub)? avatarFor;

  @override
  State<_GraphView> createState() => _GraphViewState();
}

// Which side panel is open.
enum _Panel {
  none,
  detail,
  devices, // all reachable devices (from the badge's "N devices")
  hubDevices,
  geogramDevices,
  hubs,
  settings,
  chats, // list of LXMF conversations
  chat, // one open conversation thread
}

class _GraphViewState extends State<_GraphView>
    with SingleTickerProviderStateMixin {
  List<_GNode> _allNodes = const [];
  // Other Reticulum devices (NOT geogram, NOT hubs) heard on the hubs — the full
  // observed set (NOT gated on re-announce), refreshed each data tick. This is
  // what the badge's "N devices" list shows.
  List<_GNode> _otherDevices = const [];
  List<_GEdge> _allEdges = const [];
  final Set<String> _expanded = {};

  List<_GNode> _vis = const [];
  List<_GEdge> _visEdges = const [];
  final Map<String, Offset> _posById = {};
  Map<String, Offset> _from = {};
  Map<String, Offset> _to = {};

  double _scale = 1;
  Offset _translate = Offset.zero;
  bool _fitted = false;
  Size _size = Size.zero;

  String _visSig = '';
  int _layoutSeq = 0;
  bool _laying = false;

  // Panel state.
  _Panel _panel = _Panel.none;
  String? _selectedId; // highlighted node
  String? _panelHubId; // hub whose devices are listed
  String? _lastNavTitle = ' '; // last title reported to the host app bar
  late final AnimationController _anim;

  // The title the host app bar should show for the open panel (null = graph).
  String? _panelTitle() {
    switch (_panel) {
      case _Panel.none:
        return null;
      case _Panel.detail:
        final n = _vis.where((e) => e.id == _selectedId).firstOrNull;
        return n?.label ?? 'Device';
      case _Panel.devices:
        return 'Devices';
      case _Panel.hubDevices:
        final hub = _allNodes.where((e) => e.id == _panelHubId).firstOrNull;
        return hub == null ? 'Devices' : 'Devices · ${hub.label}';
      case _Panel.geogramDevices:
        return 'Geogram devices';
      case _Panel.hubs:
        return 'Bootstrap hubs';
      case _Panel.settings:
        return 'Settings';
      case _Panel.chats:
        return 'Messages';
      case _Panel.chat:
        return _chatName.isNotEmpty ? _chatName : _shorten(_chatPeer ?? '');
    }
  }

  // Where a chat thread's back arrow returns to (the panel it was opened from —
  // Devices, Geogram, People/chats, …). Defaults to the conversation list.
  _Panel _chatReturn = _Panel.chats;

  // The single back arrow (in the host app bar) closes the current panel: a chat
  // thread returns to where it was opened from, every other panel to the graph.
  void _closePanel() {
    setState(() => _panel = _panel == _Panel.chat ? _chatReturn : _Panel.none);
  }

  // Tell the host app bar which panel (if any) is open, deduped on the title so
  // it isn't spammed every animation frame. Runs post-frame (never in build).
  void _reportNav() {
    final title = _panelTitle();
    if (title == _lastNavTitle) return;
    _lastNavTitle = title;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onPanelNav?.call(title, title == null ? null : _closePanel);
    });
  }

  // Filter controls.
  final TextEditingController _searchCtl = TextEditingController();
  bool _geoOnly = false;
  String _service = '';
  Timer? _searchDebounce;

  // Bootstrap manager.
  final TextEditingController _hubCtl = TextEditingController();
  List<Map<String, dynamic>> _hubList = const [];

  // LXMF conversations (NomadNet / Sideband / group chats).
  final TextEditingController _chatCtl = TextEditingController();
  final ScrollController _chatScroll = ScrollController();
  String? _chatPeer; // open thread's peer LXMF delivery-dest hex
  String _chatName = '';
  bool _peopleTab = false; // Messages panel: false = Chats, true = People

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 350))
      ..addListener(_onTween);
    widget.data.addListener(_onData);
    widget.hubs.addListener(_onHubs);
    RnsService.instance.addLxmfListener(_onLxmf);
    _onData();
    _onHubs();
  }

  void _onLxmf() {
    if (!mounted) return;
    setState(() {});
    // Keep the open thread pinned to the newest message.
    if (_panel == _Panel.chat) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_chatScroll.hasClients) {
          _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    widget.data.removeListener(_onData);
    widget.hubs.removeListener(_onHubs);
    RnsService.instance.removeLxmfListener(_onLxmf);
    _searchDebounce?.cancel();
    _searchCtl.dispose();
    _hubCtl.dispose();
    _chatCtl.dispose();
    _chatScroll.dispose();
    _anim.dispose();
    super.dispose();
  }

  // Open a conversation thread with [peerHex] (an LXMF delivery-dest hash).
  void _openChat(String peerHex, {String name = ''}) {
    if (peerHex.isEmpty) return;
    final k = peerHex.toLowerCase();
    RnsService.instance.lxmfEnsureConversation(k, name: name);
    RnsService.instance.lxmfMarkRead(k);
    // Remember where we came from so the chat's back arrow returns there (the
    // Devices list, a hub's devices, …) instead of always the conversation list.
    if (_panel != _Panel.chat) _chatReturn = _panel;
    setState(() {
      _chatPeer = k;
      _chatName = name;
      _panel = _Panel.chat;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent);
      }
    });
  }

  void _sendChat() {
    final peer = _chatPeer;
    final text = _chatCtl.text.trim();
    if (peer == null || text.isEmpty) return;
    _chatCtl.clear();
    // Fire-and-forget LXMF (direct + store-and-forward). The host records the
    // outgoing message into the conversation immediately.
    RnsService.instance.sendLxmf(destHex: peer, content: text);
    setState(() {});
  }

  void _onHubs() {
    final h = widget.hubs.value;
    if (h == null) return;
    _hubList = [
      for (final e in h)
        if (e is Map) e.cast<String, dynamic>()
    ];
    if (mounted) setState(() {});
  }

  void _onData() {
    final d = widget.data.value;
    if (d == null) return;
    final nodes = (d['nodes'] as List?) ?? const [];
    final edges = (d['edges'] as List?) ?? const [];
    _allNodes = [for (final m in nodes) _GNode((m as Map).cast<String, dynamic>())];
    _allEdges = [
      for (final e in edges)
        _GEdge((e as Map)['from'].toString(), e['to'].toString(),
            (e['kind'] ?? '').toString())
    ];
    // The full observed-devices set (heavy scan of the host registry) — refresh
    // here on the ~2s data tick, not on every animation frame.
    _otherDevices = [
      for (final m in RnsService.instance.observedDevices())
        _GNode(m.cast<String, dynamic>())
    ];
    _rebuildVisible();
  }

  void _rebuildVisible() {
    final byId = {for (final nd in _allNodes) nd.id: nd};
    final visIds = <String>{};
    final vis = <_GNode>[];
    void add(_GNode nd) {
      if (visIds.add(nd.id)) vis.add(nd);
    }

    for (final nd in _allNodes) {
      if (nd.kind == 'self' || nd.kind == 'hub') add(nd);
    }
    for (final nd in _allNodes) {
      if (nd.kind != 'leaf') continue;
      if (nd.relayer.isEmpty || _expanded.contains(nd.relayer)) add(nd);
    }
    _vis = vis;
    _visEdges = [
      for (final e in _allEdges)
        if (visIds.contains(e.from) && visIds.contains(e.to)) e
    ];
    if (_selectedId != null && !byId.containsKey(_selectedId)) _selectedId = null;

    final sig = (vis.map((e) => e.id).toList()..sort()).join('|');
    if (sig != _visSig) {
      _visSig = sig;
      _relayout();
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _relayout() async {
    if (_size.isEmpty) return;
    final seq = ++_layoutSeq;
    _laying = true;
    final req = <String, dynamic>{
      'w': _size.width,
      'h': _size.height,
      'nodes': [
        for (final nd in _vis)
          {'id': nd.id, 'kind': nd.kind, 'relayer': nd.relayer}
      ],
    };
    final result = await Isolate.run(() => _computeGraphLayout(req));
    if (!mounted || seq != _layoutSeq) return;
    _laying = false;
    final pos = result['pos'] as Float32List;
    final ids = (result['ids'] as List).cast<String>();
    final target = <String, Offset>{};
    for (var i = 0; i < ids.length; i++) {
      target[ids[i]] = Offset(pos[i * 2], pos[i * 2 + 1]);
    }
    _startTween(target);
  }

  void _startTween(Map<String, Offset> target) {
    final from = <String, Offset>{};
    for (final nd in _vis) {
      from[nd.id] = _posById[nd.id] ??
          (nd.relayer.isNotEmpty
              ? (_posById[nd.relayer] ?? Offset.zero)
              : Offset.zero);
    }
    _from = from;
    _to = target;
    _anim.forward(from: 0);
    _onTween();
    if (!_fitted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitToContent(target));
    }
  }

  void _onTween() {
    final t = Curves.easeOutCubic.transform(_anim.value);
    for (final nd in _vis) {
      final a = _from[nd.id] ?? Offset.zero;
      final b = _to[nd.id] ?? a;
      _posById[nd.id] = Offset.lerp(a, b, t)!;
    }
    if (mounted) setState(() {});
  }

  void _fitToContent(Map<String, Offset> pts) {
    if (pts.isEmpty || _size.isEmpty) return;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final p in pts.values) {
      minX = min(minX, p.dx);
      minY = min(minY, p.dy);
      maxX = max(maxX, p.dx);
      maxY = max(maxY, p.dy);
    }
    final cw = (maxX - minX).abs(), ch = (maxY - minY).abs();
    const padX = 90.0, padTop = 64.0, padBot = 40.0;
    final sx = cw < 1 ? 1.0 : (_size.width - padX) / cw;
    final sy = ch < 1 ? 1.0 : (_size.height - padTop - padBot) / ch;
    final s = (min(sx, sy)).clamp(0.1, 1.8);
    final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
    setState(() {
      _scale = s;
      _translate = Offset(_size.width / 2 - cx * s,
          (padTop + (_size.height - padTop - padBot) / 2) - cy * s);
      _fitted = true;
    });
  }

  Offset _screenToWorld(Offset s) => (s - _translate) / _scale;

  void _centerOn(String id) {
    final p = _posById[id];
    if (p == null || _size.isEmpty) return;
    setState(() {
      _translate = Offset(
          _size.width / 2 - p.dx * _scale, _size.height / 2 - p.dy * _scale);
    });
  }

  // ── Gestures ──
  Offset _lastFocal = Offset.zero;
  void _onScaleStart(ScaleStartDetails d) => _lastFocal = d.focalPoint;
  void _onScaleUpdate(ScaleUpdateDetails d) {
    setState(() {
      _translate += d.focalPoint - _lastFocal;
      _lastFocal = d.focalPoint;
      if (d.scale != 1.0) {
        final newScale = (_scale * d.scale).clamp(0.04, 6.0);
        final f = newScale / _scale;
        _translate = d.focalPoint - (d.focalPoint - _translate) * f;
        _scale = newScale;
      }
    });
  }

  void _zoomAround(Offset focus, double factor) {
    final newScale = (_scale * factor).clamp(0.04, 6.0);
    final f = newScale / _scale;
    setState(() {
      _translate = focus - (focus - _translate) * f;
      _scale = newScale;
    });
  }

  void _onTapUp(TapUpDetails d) {
    final world = _screenToWorld(d.localPosition);
    const tolPx = 22.0;
    final tolWorld = tolPx / _scale;
    _GNode? hit;
    var best = double.infinity;
    for (final nd in _vis) {
      final p = _posById[nd.id];
      if (p == null) continue;
      final dd = (p - world).distanceSquared;
      if (dd < best) {
        best = dd;
        hit = nd;
      }
    }
    if (hit == null || best > tolWorld * tolWorld) {
      setState(() {
        _selectedId = null;
        if (_panel == _Panel.detail || _panel == _Panel.hubDevices) {
          _panel = _Panel.none;
        }
      });
      return;
    }
    final node = hit;
    if (node.kind == 'hub' && node.childCount > 0) {
      setState(() {
        if (!_expanded.add(node.id)) _expanded.remove(node.id);
        _selectedId = node.id;
        _panelHubId = node.id;
        _panel = _Panel.hubDevices;
      });
      _rebuildVisible();
    } else {
      setState(() {
        _selectedId = node.id;
        _panel = _Panel.detail;
      });
    }
  }

  // ── Commands ──
  void _emitFilter() => widget.onCommand({
        'command': 'graph_filter',
        'geogramOnly': _geoOnly,
        'service': _service,
        'search': _searchCtl.text.trim(),
      });

  @override
  Widget build(BuildContext context) {
    _reportNav(); // keep the host app bar's title + back in sync with the panel
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      if (size != _size) {
        _size = size;
        if (!_fitted && _vis.isNotEmpty && !_laying) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _relayout());
        }
      }
      return ColoredBox(
        color: _gBg,
        child: Stack(children: [
          Positioned.fill(
            child: Listener(
              onPointerSignal: (s) {
                if (s is PointerScrollEvent) {
                  _zoomAround(
                      s.localPosition, s.scrollDelta.dy < 0 ? 1.12 : 1 / 1.12);
                }
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onTapUp: _onTapUp,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _GraphPainter(
                    nodes: _vis,
                    edges: _visEdges,
                    posById: _posById,
                    expanded: _expanded,
                    scale: _scale,
                    translate: _translate,
                    selectedId: _selectedId,
                    repaint: _anim,
                  ),
                ),
              ),
            ),
          ),
          if (_vis.where((n) => n.kind != 'self').isEmpty) _buildEmpty(),
          _buildTopBar(),
          _buildReachBadge(),
          _buildLegend(),
          _buildPanel(),
        ]),
      );
    });
  }

  // ── Top control bar (search + filters + Hubs/Settings icons) ──
  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        color: const Color(0xE60D1117),
        child: Row(children: [
          Expanded(
            child: SizedBox(
              height: 32,
              child: TextField(
                controller: _searchCtl,
                style: const TextStyle(color: _gFg, fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 16, color: _gMuted),
                  prefixIconConstraints:
                      BoxConstraints(minWidth: 30, minHeight: 30),
                  hintText: 'Search…',
                  hintStyle: TextStyle(color: _gMuted, fontSize: 13),
                  filled: true,
                  fillColor: _gPanel,
                  contentPadding: EdgeInsets.symmetric(vertical: 6),
                  border: OutlineInputBorder(borderSide: BorderSide.none),
                ),
                onChanged: (_) {
                  _searchDebounce?.cancel();
                  _searchDebounce =
                      Timer(const Duration(milliseconds: 350), _emitFilter);
                  setState(() {});
                },
              ),
            ),
          ),
          const SizedBox(width: 6),
          _filterChip(
            label: _service.isEmpty ? 'all' : _service,
            icon: Icons.filter_list,
            onTap: _pickService,
          ),
          const SizedBox(width: 4),
          _filterChip(
            label: 'geogram',
            icon: _geoOnly ? Icons.check_box : Icons.check_box_outline_blank,
            active: _geoOnly,
            onTap: () {
              setState(() => _geoOnly = !_geoOnly);
              _emitFilter();
            },
          ),
          const SizedBox(width: 4),
          _messagesButton(),
          _iconBtn(Icons.dns_outlined, 'Bootstrap hubs',
              () => setState(() => _panel = _Panel.hubs),
              active: _panel == _Panel.hubs),
          _iconBtn(Icons.tune, 'Settings',
              () => setState(() => _panel = _Panel.settings),
              active: _panel == _Panel.settings),
        ]),
      ),
    );
  }

  // Messages icon with an unread-conversation badge → the conversations list.
  Widget _messagesButton() {
    final unread = RnsService.instance.lxmfUnreadCount;
    final active = _panel == _Panel.chats || _panel == _Panel.chat;
    return Stack(clipBehavior: Clip.none, children: [
      _iconBtn(Icons.forum_outlined, 'Messages',
          () => setState(() => _panel = _Panel.chats),
          active: active),
      if (unread > 0)
        Positioned(
          right: 4,
          top: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            constraints: const BoxConstraints(minWidth: 15),
            decoration: BoxDecoration(
                color: const Color(0xFFDA3633),
                borderRadius: BorderRadius.circular(8)),
            child: Text('$unread',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w700)),
          ),
        ),
    ]);
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap,
      {bool active = false}) {
    return IconButton(
      icon: Icon(icon, size: 20),
      color: active ? _gSelf : _gMuted,
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
    );
  }

  Widget _filterChip(
      {required String label,
      required IconData icon,
      bool active = false,
      required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0x3358A6FF) : _gPanel,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: active ? _gSelf : _gBorder),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: active ? _gSelf : _gMuted),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: active ? _gSelf : _gMuted, fontSize: 12)),
        ]),
      ),
    );
  }

  Future<void> _pickService() async {
    const opts = [
      '', 'chat', 'files', 'dht', 'relay', 'wapp', 'lxmf', 'rv'
    ];
    final sel = await showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(1000, 46, 8, 0),
      color: _gPanel,
      items: [
        for (final o in opts)
          PopupMenuItem<String>(
            value: o,
            child: Text(o.isEmpty ? 'all services' : o,
                style: const TextStyle(color: _gFg)),
          ),
      ],
    );
    if (sel != null) {
      setState(() => _service = sel);
      _emitFilter();
    }
  }

  // ── Legend ──
  Widget _buildLegend() {
    Widget dot(Color c, {bool ring = false}) => Container(
          width: 9,
          height: 9,
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: ring ? Border.all(color: _gGeo, width: 2) : null,
          ),
        );
    const muted = TextStyle(color: _gMuted, fontSize: 11);
    return Positioned(
      left: 10,
      bottom: 12,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xE6161B22),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _gBorder),
          ),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  dot(_gSelf),
                  const Text('this node', style: muted)
                ]),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  dot(_gHub),
                  const Text('hub / transport', style: muted)
                ]),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  dot(_gGeo, ring: true),
                  const Text('geogram node', style: muted)
                ]),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  dot(_gGeneric),
                  const Text('other Reticulum', style: muted)
                ]),
              ]),
        ),
      ),
    );
  }

  // ── Reachable-devices badge (top-right) ──
  // Headline count: devices reachable right now across the connected hubs. The
  // device count is the host's unfiltered `online` (heard within the online
  // window); the hub count is how many bootstrap hubs we currently hold a link
  // to. Tapping opens the bootstrap-hubs panel.
  Widget _buildReachBadge() {
    // Three DISTINCT categories, each its own count + list:
    //  • geogram  — our devices;
    //  • devices  — other Reticulum peers (NomadNet/Sideband/generic), NOT
    //               geogram and NOT hubs;
    //  • hubs     — connected bootstrap hubs.
    final base = _allNodes.where((n) => n.kind != 'self').toList();
    final geo = _dedupPeers(base.where((n) => n.geogram).toList()).length;
    // "devices" = ALL other Reticulum peers heard on the hubs (the full observed
    // set, not just the graph's re-announced nodes).
    final online = _dedupPeers(_otherDevices).length;
    final hubs = _hubList.where((h) => h['connected'] == true).length;
    return Positioned(
      top: 54,
      right: 10,
      child: Material(
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xE6161B22),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _gBorder),
          ),
          // Positioned has no width; IntrinsicWidth bounds the column to its
          // widest line so the stretch + Divider can lay out.
          child: IntrinsicWidth(
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Line 1 — two separate tap targets: "devices" (other Reticulum)
              // and "hubs", each opening its OWN list.
              Row(mainAxisSize: MainAxisSize.min, children: [
                InkWell(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(8)),
                  onTap: () => setState(() => _panel = _Panel.devices),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.lan_outlined, size: 15, color: _gSelf),
                      const SizedBox(width: 6),
                      Text('$online',
                          style: const TextStyle(
                              color: _gFg,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(width: 4),
                      Text(online == 1 ? 'device' : 'devices',
                          style: const TextStyle(color: _gMuted, fontSize: 12)),
                    ]),
                  ),
                ),
                Container(width: 1, height: 20, color: _gBorder),
                InkWell(
                  borderRadius:
                      const BorderRadius.only(topRight: Radius.circular(8)),
                  onTap: () => setState(() => _panel = _Panel.hubs),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 7, 10, 7),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.dns_outlined, size: 14, color: _gHub),
                      const SizedBox(width: 5),
                      Text('$hubs',
                          style: const TextStyle(
                              color: _gFg,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(width: 4),
                      Text(hubs == 1 ? 'hub' : 'hubs',
                          style: const TextStyle(color: _gMuted, fontSize: 12)),
                    ]),
                  ),
                ),
              ]),
              const Divider(height: 1, thickness: 1, color: _gBorder),
              // Line 2 — geogram-reachable devices → list + 1:1 messaging.
              InkWell(
                borderRadius:
                    const BorderRadius.vertical(bottom: Radius.circular(8)),
                onTap: () => setState(() => _panel = _Panel.geogramDevices),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.hub_outlined, size: 15, color: _gGeo),
                    const SizedBox(width: 6),
                    Text('$geo',
                        style: const TextStyle(
                            color: _gFg,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(width: 4),
                    const Text('geogram',
                        style: TextStyle(color: _gMuted, fontSize: 12)),
                    const SizedBox(width: 6),
                    const Icon(Icons.chevron_right, size: 15, color: _gMuted),
                  ]),
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() => const Positioned.fill(
        child: IgnorePointer(
          child: Center(
            child: Text('No nodes heard yet.\nWaiting for Reticulum announces…',
                textAlign: TextAlign.center,
                style: TextStyle(color: _gMuted, fontSize: 14)),
          ),
        ),
      );

  // ── Side panels (full height, no popups) ──
  Widget _buildPanel() {
    if (_panel == _Panel.none) return const SizedBox.shrink();
    Widget content;
    switch (_panel) {
      case _Panel.detail:
        final n = _vis.where((e) => e.id == _selectedId).firstOrNull;
        if (n == null) return const SizedBox.shrink();
        content = _detailBody(n);
        break;
      case _Panel.devices:
        content = _devicesBody();
        break;
      case _Panel.hubDevices:
        content = _hubDevicesBody(_panelHubId ?? '');
        break;
      case _Panel.geogramDevices:
        content = _geogramDevicesBody();
        break;
      case _Panel.hubs:
        content = _hubsBody();
        break;
      case _Panel.settings:
        content = _settingsBody();
        break;
      case _Panel.chats:
        content = _chatsBody();
        break;
      case _Panel.chat:
        content = _chatThreadBody();
        break;
      case _Panel.none:
        return const SizedBox.shrink();
    }
    // Full-screen panel (no side-strip popup, no own header — the host app bar
    // shows the title + the single back arrow; see _reportNav).
    return Positioned.fill(
      child: Material(
        color: _gBg,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: content,
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k.toUpperCase(),
              style: const TextStyle(
                  color: _gMuted, fontSize: 10, letterSpacing: 0.4)),
          const SizedBox(height: 1),
          SelectableText(v, style: const TextStyle(color: _gFg, fontSize: 13)),
        ]),
      );

  String _shorten(String s, {int head = 10, int tail = 6}) {
    if (s.length <= head + tail + 1) return s;
    return tail > 0
        ? '${s.substring(0, head)}…${s.substring(s.length - tail)}'
        : s.substring(0, head);
  }

  String _ago(dynamic ms) {
    final v = (ms as num?)?.toInt() ?? 0;
    if (v == 0) return '—';
    final s = ((DateTime.now().millisecondsSinceEpoch - v) / 1000).floor();
    if (s < 60) return '${s}s ago';
    if (s < 3600) return '${s ~/ 60}m ago';
    if (s < 86400) return '${s ~/ 3600}h ago';
    return '${s ~/ 86400}d ago';
  }

  Widget _detailBody(_GNode n) {
    final m = n.meta;
    final kindName = n.kind == 'self'
        ? 'This node'
        : n.kind == 'hub'
            ? 'Hub / transport node'
            : 'Peer';
    final pubkey = (m['pubkey'] ?? '').toString();
    final canMessage = n.kind != 'self' && n.dm.isNotEmpty && pubkey.isNotEmpty;
    final color = n.kind == 'self'
        ? _gSelf
        : n.kind == 'hub'
            ? _gHub
            : (n.geogram ? _gGeo : _gGeneric);
    final initial = n.label.isNotEmpty ? n.label.substring(0, 1).toUpperCase() : '?';
    final dmText = switch (n.dm) {
      'lxmf' => 'LXMF · direct',
      'sf' => 'LXMF · store-and-forward',
      'chat' => 'Geogram chat',
      _ => 'No 1:1 messaging heard',
    };
    return ListView(padding: const EdgeInsets.all(18), children: [
      // Header: avatar + name + kind + last seen.
      Row(children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
              color: color.withAlpha(38),
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 2)),
          child: Center(
              child: Text(initial,
                  style: TextStyle(
                      color: color, fontSize: 25, fontWeight: FontWeight.w700))),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: _gFg, fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(kindName + (n.geogram ? ' · geogram' : ''),
                style: const TextStyle(color: _gMuted, fontSize: 13)),
            if (n.kind != 'self' && m['lastSeen'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Last seen ${_ago(m['lastSeen'])}',
                    style: const TextStyle(color: _gMuted, fontSize: 12)),
              ),
          ]),
        ),
      ]),
      const SizedBox(height: 18),
      // Prominent Message button (or a reachability note when unreachable).
      if (canMessage)
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            icon: const Icon(Icons.send, size: 18),
            label: const Text('Message'),
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 13)),
            onPressed: () => _messagePeer(n, pubkey),
          ),
        )
      else if (n.kind != 'self')
        Row(children: [
          const Icon(Icons.do_not_disturb_on, size: 15, color: _gMuted),
          const SizedBox(width: 6),
          Text(dmText, style: const TextStyle(color: _gMuted, fontSize: 13)),
        ]),
      // A geogram peer has a full profile (name/pic/about + follow/mute + its
      // reticulum facts) — open the same page the NOSTR/Chat wapps show.
      if (n.geogram && n.kind != 'self') ...[
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.account_circle_outlined, size: 18),
            label: const Text('View full profile'),
            onPressed: () => _openPeerProfile(n),
          ),
        ),
      ],
      const SizedBox(height: 16),
      if (n.kind == 'hub' && n.childCount > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.list, size: 16),
              label: Text('List ${n.childCount} devices'),
              onPressed: () => setState(() {
                _panelHubId = n.id;
                _expanded.add(n.id);
                _panel = _Panel.hubDevices;
                _rebuildVisible();
              }),
            ),
          ),
        ),
      if (n.services.isNotEmpty) _chips(n.services),
      if ((m['nickname'] ?? '').toString().isNotEmpty &&
          (m['nickname'] ?? '').toString().toUpperCase() !=
              (m['callsign'] ?? '').toString().toUpperCase())
        _kv('Nickname', m['nickname'].toString()),
      if ((m['callsign'] ?? '').toString().isNotEmpty)
        _kv('Callsign', m['callsign'].toString()),
      if ((m['role'] ?? '').toString().isNotEmpty)
        _kv('Relay role', m['role'].toString()),
      if (m['caps'] is List && (m['caps'] as List).isNotEmpty)
        _kv('Capabilities', (m['caps'] as List).join(', ')),
      if (n.kind != 'self') _kv('Hops', '${n.hops}'),
      if (n.via.isNotEmpty) _kv('Via', n.via),
      if (n.kind == 'hub' && n.childCount > 0)
        _kv('Peers heard', '≈ ${n.childCount} (sample)'),
      if (m['firstSeen'] != null) _kv('First seen', _ago(m['firstSeen'])),
      if (n.npub.isNotEmpty) _kv('npub', n.npub),
      if (n.id.isNotEmpty) _kv('Identity', n.id),
    ]);
  }

  // Open (or start) an LXMF conversation with a graph node. The conversation is
  // keyed by the node's LXMF delivery-dest — derived from its announced pubkey —
  // so incoming replies (same address) land in the same thread.
  void _messagePeer(_GNode n, String pubkey) {
    final dest = RnsService.instance.lxmfDestForPubkey(pubkey);
    if (dest == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('No usable key for this device')));
      return;
    }
    _openChat(dest, name: n.label.isNotEmpty ? n.label : _shorten(n.id));
  }

  Widget _chips(List<String> svcs) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Wrap(spacing: 4, runSpacing: 4, children: [
          for (final s in svcs)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0x2258A6FF),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x5558A6FF)),
              ),
              child: Text(s,
                  style: const TextStyle(color: _gSelf, fontSize: 11)),
            ),
        ]),
      );

  // Devices on a hub: tap a device → select + centre it on the graph.
  // A stable dedup key for a person: their npub (cross-device identity),
  // else their callsign, else their raw id.
  String _peerKey(_GNode n) {
    if (n.npub.isNotEmpty) return 'npub:${n.npub}';
    final call = (n.meta['callsign'] ?? '').toString();
    if (call.isNotEmpty) return 'call:${call.toUpperCase()}';
    return 'id:${n.id}';
  }

  // Collapse the same person heard from several identities/hubs into one row
  // (keeps the first, which is the best-labelled after sorting).
  List<_GNode> _dedupPeers(List<_GNode> src) {
    final seen = <String>{};
    final out = <_GNode>[];
    for (final n in src) {
      if (RnsService.instance.isMutedCallsign(
          (n.meta['callsign'] ?? '').toString())) {
        continue; // muted → hidden from the lists
      }
      if (seen.add(_peerKey(n))) out.add(n);
    }
    return out;
  }

  // Hubs a peer is reachable through NOW — the labels of every node sharing this
  // peer's key (same person on several identities → several hubs).
  List<String> _reachableViaFor(_GNode n) {
    final key = _peerKey(n);
    final labels = <String>{};
    for (final o in _allNodes) {
      if (_peerKey(o) != key) continue;
      final r = o.relayer;
      if (r.isEmpty) continue;
      final hub = _allNodes.where((h) => h.id == r).firstOrNull;
      labels.add(hub != null ? hub.label : 'hub ${_shorten(r, head: 8, tail: 0)}');
    }
    return labels.toList()..sort();
  }

  // Open the shared full profile page for a geogram peer (Follow / Message /
  // Mute + observed first-seen + reachable-via hubs).
  void _openPeerProfile(_GNode n) {
    final callsign = (n.meta['callsign'] ?? '').toString().isNotEmpty
        ? (n.meta['callsign']).toString()
        : n.label;
    final firstSeen = (n.meta['firstSeen'] as num?)?.toInt();
    widget.onOpenProfile
        ?.call(callsign, n.npub.isEmpty ? null : n.npub, firstSeen,
            _reachableViaFor(n));
  }

  // Other Reticulum devices (NomadNet / Sideband / generic) — NOT geogram and
  // NOT hubs. From the badge's "N devices" line. (Geogram → its own list; hubs →
  // the hubs panel.)
  Widget _devicesBody() {
    final peers = _dedupPeers(_otherDevices.toList()
      ..sort((a, b) {
        final am = a.dm.isNotEmpty, bm = b.dm.isNotEmpty;
        if (am != bm) return am ? -1 : 1; // messageable first
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      }));
    if (peers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
              'No other Reticulum devices right now.\n\n(Your geogram devices are under the "geogram" list; hubs under "hubs".)',
              textAlign: TextAlign.center,
              style: TextStyle(color: _gMuted, fontSize: 13)),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: peers.length,
      itemBuilder: (_, i) => _peerRow(peers[i]),
    );
  }

  Widget _hubDevicesBody(String hubId) {
    final peers = _allNodes.where((n) => n.relayer == hubId).toList()
      ..sort((a, b) {
        // Messageable people first, then by name — so the useful rows are on top.
        if (a.geogram != b.geogram) return a.geogram ? -1 : 1;
        final am = a.dm.isNotEmpty, bm = b.dm.isNotEmpty;
        if (am != bm) return am ? -1 : 1;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
    if (peers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
              'No peers of this hub have been heard yet.\n(We only see nodes that announce — not the hub\'s full roster.)',
              textAlign: TextAlign.center,
              style: TextStyle(color: _gMuted, fontSize: 13)),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: peers.length,
      itemBuilder: (_, i) => _peerRow(peers[i]),
    );
  }

  // Reachable geogram devices, compact + one-tap to message. Opened from the
  // badge's "geogram" line.
  Widget _geogramDevicesBody() {
    final peers = _dedupPeers(_allNodes
        .where((n) => n.kind != 'self' && n.geogram)
        .toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase())));
    if (peers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No geogram devices reachable right now.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _gMuted, fontSize: 13)),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: peers.length,
      itemBuilder: (_, i) => _peerRow(peers[i]),
    );
  }

  // Bootstrap-hub manager.
  Widget _hubsBody() {
    return Column(children: [
      Expanded(
        child: _hubList.isEmpty
            ? const Center(
                child: Text('No bootstrap hubs configured.',
                    style: TextStyle(color: _gMuted)))
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: _hubList.length,
                itemBuilder: (_, i) {
                  final h = _hubList[i];
                  final ep = (h['endpoint'] ?? '').toString();
                  final on = h['connected'] == true;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    child: Row(children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                            color: on ? _gGeo : _gGeneric,
                            shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(ep,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: _gFg, fontSize: 13)),
                              Text(on ? 'connected' : 'offline',
                                  style: TextStyle(
                                      color: on ? _gGeo : _gMuted,
                                      fontSize: 11)),
                            ]),
                      ),
                      IconButton(
                        icon: Icon(on ? Icons.link_off : Icons.link, size: 18),
                        color: _gMuted,
                        tooltip: on ? 'Disconnect' : 'Connect',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => widget.onCommand({
                          'command': on ? 'hub_disconnect' : 'hub_connect',
                          'hub_endpoint': ep,
                        }),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        color: const Color(0xFFDA3633),
                        tooltip: 'Remove',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => widget.onCommand(
                            {'command': 'hub_remove', 'hub_endpoint': ep}),
                      ),
                    ]),
                  );
                },
              ),
      ),
      const Divider(height: 1, color: _gBorder),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _hubCtl,
              style: const TextStyle(color: _gFg, fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'host:port',
                hintStyle: TextStyle(color: _gMuted, fontSize: 13),
                filled: true,
                fillColor: _gBg,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: OutlineInputBorder(borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () {
              final ep = _hubCtl.text.trim();
              if (ep.isEmpty) return;
              widget.onCommand({'command': 'hub_add', 'hub_endpoint': ep});
              _hubCtl.clear();
            },
            child: const Text('Add'),
          ),
        ]),
      ),
    ]);
  }

  // ── LXMF conversations (NomadNet / Sideband / group chats) ──
  // The list of open conversations, plus a way to start a new one / join a group
  // by pasting an LXMF address. Peers can be geogram devices, NomadNet/Sideband
  // users, or LXMF distribution-group nodes — all interoperate over LXMF.
  Widget _chatsBody() {
    return Column(children: [
      // Chats | People segmented control.
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
        child: Row(children: [
          _seg('Chats', !_peopleTab, () => setState(() => _peopleTab = false)),
          const SizedBox(width: 6),
          _seg('People', _peopleTab, () => setState(() => _peopleTab = true)),
        ]),
      ),
      Expanded(child: _peopleTab ? _peopleList() : _conversationsList()),
      const Divider(height: 1, color: _gBorder),
      Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('New chat / join group'),
            onPressed: _newChatDialog,
          ),
        ),
      ),
    ]);
  }

  Widget _seg(String label, bool active, VoidCallback onTap) => Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? const Color(0x3358A6FF) : _gBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: active ? _gSelf : _gBorder),
            ),
            child: Text(label,
                style: TextStyle(
                    color: active ? _gSelf : _gMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
        ),
      );

  Widget _conversationsList() {
    final convos = RnsService.instance.lxmfConversations();
    if (convos.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(22),
          child: Text(
              'No conversations yet.\n\nOpen the People tab to message a reachable device, or "New chat / join group" for an LXMF address.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _gMuted, fontSize: 13)),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: convos.length,
      itemBuilder: (_, i) {
        final c = convos[i];
        final id = (c['id'] ?? '').toString();
        final unread = c['unread'] == true;
        return InkWell(
          onTap: () => _openChat(id, name: (c['name'] ?? '').toString()),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Icon(Icons.chat_bubble,
                  size: 15, color: unread ? _gSelf : _gMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text((c['name'] ?? '').toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: _gFg,
                              fontSize: 13.5,
                              fontWeight:
                                  unread ? FontWeight.w700 : FontWeight.w500)),
                      if ((c['last'] ?? '').toString().isNotEmpty)
                        Text((c['last'] ?? '').toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(color: _gMuted, fontSize: 11.5)),
                    ]),
              ),
              if (unread)
                Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                        color: _gSelf, shape: BoxShape.circle)),
            ]),
          ),
        );
      },
    );
  }

  // Reachable, messageable peers (geogram / NomadNet / Sideband), newest network
  // heard. Tap a row → start messaging. Compact single-line rows.
  Widget _peopleList() {
    final peers = _dedupPeers(_allNodes.where((n) {
      if (n.kind == 'self') return false;
      final pubkey = (n.meta['pubkey'] ?? '').toString();
      return n.dm.isNotEmpty && pubkey.isNotEmpty; // can receive a 1:1 message
    }).toList()
      ..sort((a, b) {
        if (a.geogram != b.geogram) return a.geogram ? -1 : 1; // our devices top
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      }));
    if (peers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(22),
          child: Text(
              'No reachable people right now.\n\nDevices that announce LXMF — geogram, NomadNet or Sideband — appear here as they are heard.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _gMuted, fontSize: 13)),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: peers.length,
      itemBuilder: (_, i) => _peerRow(peers[i]),
    );
  }

  // One compact, tappable peer row.
  //  • geogram peer → row opens its full PROFILE (avatar + a send shortcut);
  //  • other messageable peer (NomadNet/Sideband) → row opens a chat;
  //  • bare node/relay → row opens the graph detail.
  Widget _peerRow(_GNode p) {
    final pubkey = (p.meta['pubkey'] ?? '').toString();
    final canMsg = p.dm.isNotEmpty && pubkey.isNotEmpty;
    final color = p.geogram
        ? _gGeo
        : (p.dm.isNotEmpty ? _gSelf : _gGeneric);
    // A short tag telling the peer's network apart at a glance.
    final tag = p.geogram
        ? ''
        : p.services.contains('node')
            ? 'nomadnet'
            : p.dm.isNotEmpty
                ? 'lxmf'
                : (p.services.isNotEmpty ? p.services.first : '');
    final avatar =
        (p.geogram && p.npub.isNotEmpty) ? widget.avatarFor?.call(p.npub) : null;
    void onRowTap() {
      if (p.geogram) {
        _openPeerProfile(p);
      } else if (canMsg) {
        _messagePeer(p, pubkey);
      } else {
        setState(() {
          _selectedId = p.id;
          _panel = _Panel.detail;
        });
        _centerOn(p.id);
      }
    }

    final sub = _peerSubtitle(p);
    return InkWell(
      onTap: onRowTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(children: [
          // Leading: profile avatar for a geogram peer, else a status dot.
          if (avatar != null)
            CircleAvatar(radius: 15, backgroundImage: avatar)
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle)),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(p.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: _gFg, fontSize: 13.5)),
                    ),
                    if (tag.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(tag,
                          style:
                              const TextStyle(color: _gMuted, fontSize: 10.5)),
                    ],
                  ]),
                  if (sub.isNotEmpty)
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _gMuted, fontSize: 11)),
                ]),
          ),
          // Geogram: the row opens the profile, so give a direct Message
          // shortcut here. Others: a plain affordance.
          if (p.geogram && canMsg)
            InkWell(
              onTap: () => _messagePeer(p, pubkey),
              borderRadius: BorderRadius.circular(16),
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(Icons.send, size: 17, color: _gSelf),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(canMsg ? Icons.send : Icons.chevron_right,
                  size: canMsg ? 17 : 16, color: canMsg ? _gSelf : _gMuted),
            ),
        ]),
      ),
    );
  }

  // Row subtitle: how long ago we first heard the device + which hub(s) it's
  // reachable through (or "N hubs" when present on several bridges).
  String _peerSubtitle(_GNode p) {
    final parts = <String>[];
    if (p.firstSeenMs > 0) parts.add('first seen ${_ago(p.firstSeenMs)}');
    final relayers =
        p.relayers.isNotEmpty ? p.relayers : (p.relayer.isEmpty ? const <String>[] : [p.relayer]);
    if (relayers.length > 1) {
      parts.add('${relayers.length} hubs');
    } else if (relayers.length == 1) {
      parts.add(_hubLabel(relayers.first));
    }
    return parts.join('  ·  ');
  }

  // A relayer identity → a readable hub label (its graph node's label, else a
  // short hex).
  String _hubLabel(String relayerId) {
    if (relayerId.isEmpty) return '';
    final hub = _allNodes.where((n) => n.id == relayerId).firstOrNull;
    if (hub != null && hub.label.isNotEmpty) return hub.label;
    return 'hub ${_shorten(relayerId, head: 8, tail: 0)}';
  }

  Future<void> _newChatDialog() async {
    final addrCtl = TextEditingController();
    final nameCtl = TextEditingController();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _gPanel,
        title: const Text('New chat / join group',
            style: TextStyle(color: _gFg, fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
                'Paste a Reticulum LXMF address (32 hex chars) — a NomadNet or Sideband user, or an LXMF distribution-group node for group chat.',
                style: TextStyle(color: _gMuted, fontSize: 12)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: addrCtl,
            autofocus: true,
            style: const TextStyle(
                color: _gFg, fontSize: 13, fontFamily: 'monospace'),
            decoration: const InputDecoration(
                labelText: 'LXMF address (hex)',
                labelStyle: TextStyle(color: _gMuted)),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: nameCtl,
            style: const TextStyle(color: _gFg, fontSize: 13),
            decoration: const InputDecoration(
                labelText: 'Name (optional)',
                labelStyle: TextStyle(color: _gMuted)),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Open')),
        ],
      ),
    );
    final addr = addrCtl.text.trim().toLowerCase().replaceAll(
        RegExp('[^0-9a-f]'), '');
    final name = nameCtl.text.trim();
    addrCtl.dispose();
    nameCtl.dispose();
    if (res != true) return;
    if (addr.length == 32) {
      _openChat(addr, name: name);
    } else {
      messenger?.showSnackBar(const SnackBar(
          content: Text('Not a valid LXMF address (need 32 hex characters)')));
    }
  }

  Widget _chatThreadBody() {
    final peer = _chatPeer;
    if (peer == null) return const SizedBox.shrink();
    final msgs = RnsService.instance.lxmfConversation(peer);
    return Column(children: [
      // Address bar: the full LXMF address (copyable) so a group address can be
      // shared/verified. (Back is the panel header's arrow.)
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        color: _gPanel,
        child: Row(children: [
          const Icon(Icons.alternate_email, size: 13, color: _gMuted),
          const SizedBox(width: 6),
          Expanded(
            child: SelectableText(peer,
                maxLines: 1,
                style: const TextStyle(
                    color: _gMuted, fontSize: 11.5, fontFamily: 'monospace')),
          ),
        ]),
      ),
      Expanded(
        child: msgs.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                      'No messages yet. Say hello — for a group node, try sending "help" or "join" first.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _gMuted, fontSize: 13)),
                ),
              )
            : ListView.builder(
                controller: _chatScroll,
                padding: const EdgeInsets.all(10),
                itemCount: msgs.length,
                itemBuilder: (_, i) => _chatBubble(msgs[i]),
              ),
      ),
      _chatComposer(),
    ]);
  }

  Widget _chatBubble(Map<String, dynamic> m) {
    final incoming = m['in'] == true;
    final text = (m['text'] ?? '').toString();
    final title = (m['title'] ?? '').toString();
    return Align(
      alignment: incoming ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        constraints: const BoxConstraints(maxWidth: 250),
        decoration: BoxDecoration(
          color: incoming ? _gPanel : const Color(0xFF1F6FEB),
          borderRadius: BorderRadius.circular(12),
          border: incoming ? Border.all(color: _gBorder) : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (title.isNotEmpty && title != text)
            Text(title,
                style: TextStyle(
                    color: incoming ? _gFg : Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          SelectableText(text,
              style: TextStyle(
                  color: incoming ? _gFg : Colors.white, fontSize: 13)),
        ]),
      ),
    );
  }

  Widget _chatComposer() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration:
          const BoxDecoration(border: Border(top: BorderSide(color: _gBorder))),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _chatCtl,
            style: const TextStyle(color: _gFg, fontSize: 13),
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendChat(),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Message…',
              hintStyle: TextStyle(color: _gMuted, fontSize: 13),
              filled: true,
              fillColor: _gBg,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderSide: BorderSide.none),
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          icon: const Icon(Icons.send, size: 20),
          color: _gSelf,
          onPressed: _sendChat,
        ),
      ]),
    );
  }

  Widget _settingsBody() {
    final d = widget.data.value ?? const {};
    final passive = d['passive'] == true;
    final stats = (d['stats'] as Map?)?.cast<String, dynamic>() ?? const {};
    final total = (stats['total'] as num?)?.toInt() ?? 0;
    final geo = (stats['geogram'] as num?)?.toInt() ?? 0;
    final seen24h = (stats['seen24h'] as num?)?.toInt() ?? 0;
    final oldest = (stats['oldest'] as num?)?.toInt() ?? 0;
    final live = (d['observed'] as num?)?.toInt() ?? _allNodes.length;
    final online = (d['online'] as num?)?.toInt() ?? 0;
    final lxmfReach = (d['lxmfReachable'] as num?)?.toInt() ?? 0;
    String date(int ms) {
      if (ms <= 0) return '—';
      final t = DateTime.fromMillisecondsSinceEpoch(ms);
      String two(int v) => v.toString().padLeft(2, '0');
      return '${t.year}-${two(t.month)}-${two(t.day)}';
    }

    Widget stat(String label, String value, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label, style: const TextStyle(color: _gMuted, fontSize: 13)),
                Text(value,
                    style: TextStyle(
                        color: color ?? _gFg,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ]),
        );

    return ListView(padding: const EdgeInsets.all(14), children: [
      const Text('DEVICES SEEN (PERSISTENT)',
          style: TextStyle(color: _gMuted, fontSize: 10, letterSpacing: 0.5)),
      const SizedBox(height: 4),
      stat('All time', '$total'),
      stat('Running geogram', '$geo', color: _gGeo),
      stat('Active (24h)', '$seen24h'),
      stat('Live now', '$live'),
      stat('Online now', '$online'),
      stat('Messageable now (LXMF)', '$lxmfReach', color: _gGeo),
      stat('First ever seen', date(oldest)),
      const SizedBox(height: 4),
      const Text(
          'Counts are from the on-disk cache in this wapp\'s data folder, so '
          'first-seen and totals persist across restarts. The live graph is a '
          'sampled view — not a hub\'s full roster.',
          style: TextStyle(color: _gMuted, fontSize: 11)),
      const Divider(color: _gBorder, height: 28),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text("Passive (don't relay for others)",
            style: TextStyle(color: _gFg, fontSize: 14)),
        subtitle: const Text(
            'Stay meshed and carry your own traffic, but stop doing relay work for others (sheds CPU).',
            style: TextStyle(color: _gMuted, fontSize: 12)),
        value: passive,
        onChanged: (v) =>
            widget.onCommand({'command': 'apply_settings', 'passive': v}),
      ),
    ]);
  }
}

// ── Painter ────────────────────────────────────────────────────────────────
class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.nodes,
    required this.edges,
    required this.posById,
    required this.expanded,
    required this.scale,
    required this.translate,
    required this.selectedId,
    required Listenable repaint,
  }) : super(repaint: repaint);
  final List<_GNode> nodes;
  final List<_GEdge> edges;
  final Map<String, Offset> posById;
  final Set<String> expanded;
  final double scale;
  final Offset translate;
  final String? selectedId;

  Offset _s(Offset w) => w * scale + translate;

  @override
  void paint(Canvas canvas, Size size) {
    final uplink = Path(), relay = Path(), direct = Path();
    for (final e in edges) {
      final a = posById[e.from], b = posById[e.to];
      if (a == null || b == null) continue;
      final sa = _s(a), sb = _s(b);
      final p = e.kind == 'uplink'
          ? uplink
          : e.kind == 'relay'
              ? relay
              : direct;
      p.moveTo(sa.dx, sa.dy);
      p.lineTo(sb.dx, sb.dy);
    }
    canvas.drawPath(
        relay,
        Paint()
          ..color = const Color(0x66484F58)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke);
    canvas.drawPath(
        direct,
        Paint()
          ..color = const Color(0x883FB950)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke);
    canvas.drawPath(
        uplink,
        Paint()
          ..color = const Color(0xCC58A6FF)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke);

    final bounds = (Offset.zero & size).inflate(40);
    for (final n in nodes) {
      final wp = posById[n.id];
      if (wp == null) continue;
      final p = _s(wp);
      if (!bounds.contains(p)) continue;
      _paintNode(canvas, n, p);
    }
  }

  void _paintNode(Canvas canvas, _GNode n, Offset p) {
    double r;
    Color c;
    switch (n.kind) {
      case 'self':
        r = 9;
        c = _gSelf;
        break;
      case 'hub':
        r = 8;
        c = _gHub;
        break;
      default:
        r = 5.5;
        c = n.geogram ? _gGeo : _gGeneric;
    }
    final selected = n.id == selectedId;
    if (n.kind == 'hub') {
      final path = Path()
        ..moveTo(p.dx, p.dy - r)
        ..lineTo(p.dx + r, p.dy)
        ..lineTo(p.dx, p.dy + r)
        ..lineTo(p.dx - r, p.dy)
        ..close();
      canvas.drawPath(path, Paint()..color = c);
    } else {
      canvas.drawCircle(p, r, Paint()..color = c);
      if (n.geogram && n.kind != 'self') {
        canvas.drawCircle(
            p,
            r + 1.5,
            Paint()
              ..color = _gGeo
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
    }
    if (selected) {
      canvas.drawCircle(
          p,
          r + 4,
          Paint()
            ..color = _gSelf
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
    if (n.kind == 'hub' && n.childCount > 0 && !expanded.contains(n.id)) {
      _text(canvas, '⊕ ${n.childCount}', p + const Offset(11, -6), _gHub, 10);
    }
    // Labels: self + hubs always; leaves only when zoomed in or selected
    // (keeps dense hub clusters readable instead of an overlapping mess).
    final showLabel = n.kind == 'self' ||
        n.kind == 'hub' ||
        selected ||
        scale > 1.5;
    if (showLabel && n.label.isNotEmpty) {
      _text(canvas, n.label, p + Offset(0, r + 3),
          selected ? _gSelf : _gFg, 10,
          center: true);
    }
  }

  final Map<String, TextPainter> _tpCache = {};
  void _text(Canvas canvas, String s, Offset at, Color color, double size,
      {bool center = false}) {
    final tp = _tpCache.putIfAbsent('$s|$color|$size', () {
      return TextPainter(
        text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
        textDirection: TextDirection.ltr,
      )..layout();
    });
    tp.paint(canvas, center ? at - Offset(tp.width / 2, 0) : at);
  }

  @override
  bool shouldRepaint(_GraphPainter o) => true;
}

// ── _WappPageState integration ─────────────────────────────────────────────
extension _WappGraphExt on _WappPageState {
  /// Full-bleed native graph screen for a `$type:"graph"` group.
  Widget _buildGraphScreen(GeoUiBlock screen, GeoUiBlock group) {
    return _GraphView(
      key: const ValueKey('wapp-graph'),
      data: _graphData,
      hubs: _graphHubs,
      onCommand: (cmd) {
        _engine.sendMessage(jsonEncode(cmd));
        _engine.handleEvent();
        _drainOutbox();
      },
      onPanelNav: (title, back) {
        if (!mounted) return;
        setState(() {
          _graphPanelTitle = title;
          _graphPanelBack = back;
        });
      },
      onOpenProfile: (callsign, npub, firstSeenMs, reachableVia) =>
          _openReticulumProfile(
        callsign: callsign,
        npub: npub,
        firstSeenMs: firstSeenMs,
        reachableVia: reachableVia,
      ),
      avatarFor: (npub) {
        final hex = RnsService.instance.nostrHexFromNpub(npub);
        if (hex == null) return null;
        final pic = RnsService.instance.nostrProfile(hex)['pic'] ?? '';
        if (pic.isEmpty) return null;
        return pic.startsWith('http')
            ? NetworkImage(pic)
            : _imageForPicture(pic);
      },
    );
  }
}
