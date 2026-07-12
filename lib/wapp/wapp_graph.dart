// Native node-link graph widget for the generic GeoUI `$type:"graph"` group,
// rendered by the graph3d 3D engine (glowing orbs, Google-Earth navigation,
// depth fog). Scene assembly — snapshot parsing, interface classification,
// orb styling, ego layout — lives in wapp_graph_scene.dart; this file wires
// it to the wapp's data stream and hosts the chrome.
//
// All chrome lives in this widget as full-height side panels (no popups): a
// node detail panel, a hub device-list (tap a hub → its peers; tap a peer →
// select it on the graph), a bootstrap-hub manager, and a settings panel —
// reached from a compact icon row at the top-right. Clustering keeps it
// scalable: hubs collapse their peers behind a count badge by default and
// only one hub is expanded at a time.
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
  page, // a NomadNet node page (browser)
}

class _GraphViewState extends State<_GraphView> with TickerProviderStateMixin {
  List<RnsGraphNode> _allNodes = const [];
  // Other Reticulum devices (NOT geogram, NOT hubs) heard on the hubs — the full
  // observed set (NOT gated on re-announce), refreshed each data tick. This is
  // what the badge's "N devices" list shows.
  List<RnsGraphNode> _otherDevices = const [];

  // The 3D scene. Node keys are identity hashes, so the wapp's 2s snapshot
  // refresh glides persisting nodes to their new poses (and keeps selection)
  // instead of rebuilding from scratch.
  late final GraphSceneController<RnsGraphNode> _scene =
      GraphSceneController<RnsGraphNode>(vsync: this)
        ..camera.rotateSpeed = 0.24
        ..camera.dampingFactor = 0.18;
  String? _expandedHubId; // one expanded hub cluster max
  RnsIface? _focusedIface; // legend-chip group focus
  bool _framedOnce = false; // first non-empty snapshot frames the view
  // The camera follows the growing network (announces trickle in for minutes
  // after connect) until the user takes the stick; the recenter button hands
  // control back.
  bool _userNavigated = false;
  double _framedRadius = 0;

  // Panel state.
  _Panel _panel = _Panel.none;
  String? _selectedId; // highlighted node
  String? _panelHubId; // hub whose devices are listed
  String? _lastNavTitle = ' '; // last title reported to the host app bar

  // The title the host app bar should show for the open panel (null = graph).
  String? _panelTitle() {
    switch (_panel) {
      case _Panel.none:
        return null;
      case _Panel.detail:
        final n = _allNodes.where((e) => e.id == _selectedId).firstOrNull;
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
      case _Panel.page:
        return _pageLabel.isNotEmpty ? _pageLabel : 'Page';
    }
  }

  // Where a chat thread's back arrow returns to (the panel it was opened from —
  // Devices, Geogram, People/chats, …). Defaults to the conversation list.
  _Panel _chatReturn = _Panel.chats;

  // The single back arrow (in the host app bar) closes the current panel: a chat
  // thread returns to where it was opened from, every other panel to the graph.
  void _closePanel() {
    // Inside the page browser, back walks the page history first.
    if (_panel == _Panel.page && _pageHistory.isNotEmpty) {
      _loadPage(_pageHistory.removeLast());
      return;
    }
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

  // NomadNet page browser state.
  String _pagePub = ''; // the node's identity pubkey hex
  String _pageLabel = ''; // node label for the title
  String _pagePath = '/page/index.mu';
  String? _pageText; // fetched page bytes as text (null = loading)
  String? _pageErr;
  int _pageSeq = 0; // guards against a stale fetch overwriting a newer one
  final List<String> _pageHistory = []; // page paths visited, for in-page back
  bool _pageSource = false; // false = rendered micron, true = raw source

  @override
  void initState() {
    super.initState();
    _scene.addListener(_onSceneChange);
    widget.data.addListener(_onData);
    widget.hubs.addListener(_onHubs);
    RnsService.instance.addLxmfListener(_onLxmf);
    _onData();
    _onHubs();
  }

  void _onSceneChange() {
    if (_scene.isDragging) _userNavigated = true;
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
    _scene.removeListener(_onSceneChange);
    _scene.dispose();
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
    // Seed from the host directly when the wapp has not pushed a frame yet.
    //
    // The wasm module ticks every 2s and a periodic timer fires FIRST at
    // +interval, so opening this page used to show zeros for ~5 seconds while
    // the data it needed was already sitting in memory, one synchronous call
    // away. Reading it here means the graph is populated on the first frame.
    final d = widget.data.value ?? RnsService.instance.graphSnapshot();
    final nodes = (d['nodes'] as List?) ?? const [];
    final parsed = [
      for (final m in nodes) RnsGraphNode((m as Map).cast<String, dynamic>())
    ];
    resolveIfaces(parsed);
    // Cluster the hub-flood behind its uplink connections — the snapshot's
    // own edges predate the grouping, so the scene derives its edges itself.
    _allNodes = regroupByUplink(parsed);
    // The full observed-devices set (heavy scan of the host registry) — refresh
    // here on the ~2s data tick, not on every animation frame.
    _otherDevices = [
      for (final m in RnsService.instance.observedDevices())
        RnsGraphNode(m.cast<String, dynamic>())
    ];
    _rebuildScene();
  }

  // Rebuild the scene from the latest snapshot + expansion state. Old poses
  // are snapshotted BEFORE setScene (the controller's lists are mid-swap
  // during the diff): new nodes burst from their relayer, vanishing ones fold
  // back the same way.
  void _rebuildScene() {
    if (_expandedHubId != null &&
        !_allNodes.any((n) => n.id == _expandedHubId)) {
      _expandedHubId = null;
    }
    if (_selectedId != null && !_allNodes.any((n) => n.id == _selectedId)) {
      _selectedId = null;
      if (_panel == _Panel.detail) _panel = _Panel.none;
    }
    final built = buildRnsScene(
      allNodes: _allNodes,
      expandedHubId: _expandedHubId,
    );

    _scene.advancePoses();
    final positionById = <String, Vector3>{
      for (var i = 0; i < _scene.renderNodes.length; i++)
        _scene.renderNodes[i].key: _scene.poses[i].position,
    };
    Vector3 sourceOf(RnsGraphNode n) =>
        positionById[n.effectiveRelayer] ?? Vector3.zero();

    _scene.setScene(
      built.scene,
      layout: built.layout,
      enterPoseOf: _framedOnce
          ? (node) => Pose(sourceOf(node.data), Quaternion.identity())
          : null,
      exitPoseOf: (node) => Pose(sourceOf(node.data), Quaternion.identity()),
      reframe: false,
    );

    if (!_framedOnce && _allNodes.length > 1) {
      _framedOnce = true;
      _resetView(immediate: true);
    } else if (_framedOnce && !_userNavigated && _expandedHubId == null) {
      // The network keeps growing after connect; until the user flies the
      // camera themselves, keep the whole scene in frame.
      final radius = _scene.geometry.radius;
      if (radius > _framedRadius * 1.2 || radius < _framedRadius * 0.6) {
        _resetView();
      }
    }
    if (mounted) setState(() {});
  }

  void _resetView({bool immediate = false}) {
    final radius = _scene.geometry.radius + 300;
    if (radius <= 300) return;
    _framedRadius = _scene.geometry.radius;
    // Fitting the whole ego sphere on a portrait phone would shrink the core
    // to specks; frame the heart of it and let the fringe overflow — panning
    // is tethered, nothing gets lost.
    _scene.camera.maxFrameDistance = 12500;
    _scene.camera.frameFacing(
      Pose(
        Vector3.zero(),
        lookAtQuaternion(Vector3.zero(), Vector3(0, 0.5, 1)),
      ),
      halfExtent: Vector3(radius, radius * 0.62, radius * 0.9),
      sceneRadius: radius,
      durationMs: immediate ? 0 : 1200,
    );
  }

  // Frame an expanded hub's cluster from off-axis, so the hop shells behind
  // it read as depth instead of collapsing onto one line of sight. The
  // extent tracks the cluster's real footprint — a live hub can fan out a
  // hundred members over several hop shells.
  void _frameCluster(String hubId) {
    final i = _scene.renderNodes.indexWhere((n) => n.key == hubId);
    if (i < 0) return;
    _scene.advancePoses();
    _scene.camera.maxFrameDistance = 12000;
    final anchor = _scene.geometry.poses[i].position;
    final outward =
        anchor.length < 1 ? Vector3(0, 0, 1) : anchor.normalized();
    var members = 0;
    var maxHops = 2;
    for (final n in _allNodes) {
      if (n.effectiveRelayer != hubId) continue;
      members++;
      if (n.hops > maxHops) maxHops = n.hops;
    }
    final spreadHalf = members > 40 ? 0.5 : 0.28;
    final fanRadius = kHubShell + kHopSpacing * max(1, maxHops - 1);
    final depth = kHopSpacing * max(2, maxHops - 1).toDouble();
    final lateral = fanRadius * spreadHalf + 250;
    final vertical = fanRadius * (members > 40 ? 0.45 : 0.23) + 150;
    final side = Vector3(outward.z, 0, -outward.x);
    final viewDirection =
        (outward + side * 0.9 + Vector3(0, 0.42, 0)).normalized();
    final centre = anchor + outward * (depth * 0.55);
    _scene.camera.frameFacing(
      Pose(centre, lookAtQuaternion(centre, centre + viewDirection)),
      halfExtent: Vector3(lateral, vertical, depth),
      sceneRadius: fanRadius,
      durationMs: 1400,
    );
  }

  // Tap on an orb. A hub with hidden peers expands in place — its members
  // burst out of the orb and the camera swings to face the cluster; a second
  // tap opens its detail panel (device list lives there), and the recenter
  // button folds the cluster home. Everything else opens the detail panel.
  void _onNodeTap(int id) {
    if (id < 1 || id > _scene.renderNodes.length) return;
    _userNavigated = true;
    final node = _scene.renderNodes[id - 1].data;
    if (node.effectiveKind == 'hub' && node.members > 0) {
      if (_expandedHubId != node.id) {
        // First tap: the cluster bursts out of the orb, camera swings to
        // face it. The graph is the answer — no panel yet.
        setState(() {
          _expandedHubId = node.id;
          _selectedId = node.id;
          if (_panel == _Panel.detail || _panel == _Panel.hubDevices) {
            _panel = _Panel.none;
          }
        });
        _scene.selectNode(id);
        _rebuildScene();
        _frameCluster(node.id);
      } else {
        // Second tap on the open hub: its detail panel (with the device
        // list). The recenter button folds the cluster home.
        _scene.selectNode(id);
        setState(() {
          _selectedId = node.id;
          _panel = _Panel.detail;
        });
      }
      return;
    }
    _scene.selectNode(id);
    _scene.advancePoses();
    _scene.camera
        .flyToPoint(_scene.poses[id - 1].position, distance: 1500,
            durationMs: 1100);
    setState(() {
      _selectedId = node.id;
      _panel = _Panel.detail;
    });
  }

  // Select a node by identity and fly the camera to it (device-list rows).
  void _centerOn(String id) {
    final i = _scene.renderNodes.indexWhere((n) => n.key == id);
    if (i < 0) return;
    _scene.selectNode(i + 1);
    _scene.advancePoses();
    _scene.camera.flyToPoint(_scene.poses[i].position,
        distance: 1500, durationMs: 1100);
  }

  // Tapping a legend chip: light every device on that network and fly the
  // camera to face the group. Tapping the same chip again lets go.
  void _focusIface(RnsIface iface) {
    if (_focusedIface == iface) {
      setState(() => _focusedIface = null);
      _scene.highlightKeys = const <String>{};
      _resetView();
      return;
    }
    setState(() => _focusedIface = iface);
    _scene.advancePoses();
    final keys = <String>{};
    var centroid = Vector3.zero();
    var members = 0;
    for (var i = 0; i < _scene.liveCount; i++) {
      final n = _scene.renderNodes[i].data;
      if (n.kind == 'self' || n.iface != iface) continue;
      keys.add(n.id);
      centroid += _scene.geometry.poses[i].position;
      members++;
    }
    _scene.highlightKeys = keys;
    if (members == 0) return;
    centroid /= members.toDouble();

    var spread = 0.0;
    for (var i = 0; i < _scene.liveCount; i++) {
      final n = _scene.renderNodes[i].data;
      if (n.kind == 'self' || n.iface != iface) continue;
      final d = (_scene.geometry.poses[i].position - centroid).length;
      if (d > spread) spread = d;
    }
    spread = max(spread + 250, 900);

    // Face the group from outside, keeping self visible behind it.
    final outward =
        centroid.length < 1 ? Vector3(0, 0, 1) : centroid.normalized();
    final side = Vector3(outward.z, 0, -outward.x);
    final viewDirection =
        (outward + side * 0.55 + Vector3(0, 0.4, 0)).normalized();
    _scene.camera.maxFrameDistance = 14000;
    _scene.camera.frameFacing(
      Pose(centroid, lookAtQuaternion(centroid, centroid + viewDirection)),
      halfExtent: Vector3(spread, spread * 0.85, spread * 0.8),
      sceneRadius: spread + 500,
      durationMs: 1400,
    );
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
    return ColoredBox(
      color: _gBg,
      child: Stack(children: [
        // The space behind the mesh: a static starfield and a faint polar
        // grid, painted once into a picture and replayed — no per-frame cost.
        const Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
                painter: _GraphBackdropPainter(), size: Size.infinite),
          ),
        ),
        Positioned.fill(
          child: Graph3DView<RnsGraphNode>.sprites(
            controller: _scene,
            spriteOf: (node) =>
                spriteOfRnsNode(node, expandedHubId: _expandedHubId),
            onNodeTap: _onNodeTap,
            initialReframe: false,
          ),
        ),
        if (_allNodes.where((n) => n.kind != 'self').isEmpty) _buildEmpty(),
        // The HUD steps aside while the user flies the camera: chrome fades
        // and stops eating touches, so a drag that starts over it still moves
        // the world. The chrome's own Positioned widgets live in a nested
        // Stack — a Positioned can't sit below the fade's render objects.
        Positioned.fill(
          child: _hudFade(Stack(children: [
            _buildTopBar(),
            _buildReachBadge(),
            _buildLegend(),
            _buildRecenter(),
          ])),
        ),
        _buildPanel(),
      ]),
    );
  }

  Widget _hudFade(Widget child) => AnimatedBuilder(
        animation: _scene,
        builder: (context, _) => IgnorePointer(
          ignoring: _scene.isDragging,
          child: AnimatedOpacity(
            opacity: _scene.isDragging ? 0.08 : 1,
            duration: const Duration(milliseconds: 220),
            child: child,
          ),
        ),
      );

  // Recenter: fold the open cluster, drop focus/selection, frame everything
  // — and resume following the network as it grows.
  Widget _buildRecenter() {
    return Positioned(
      right: 12,
      bottom: 96,
      child: Material(
        color: const Color(0xE6161B22),
        shape: const CircleBorder(side: BorderSide(color: _gBorder)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            setState(() {
              _focusedIface = null;
              _expandedHubId = null;
              _selectedId = null;
              _userNavigated = false;
            });
            _scene.highlightKeys = const <String>{};
            _scene.clearSelection();
            _rebuildScene();
            _resetView();
          },
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Icon(Icons.center_focus_strong, size: 22, color: _gFg),
          ),
        ),
      ),
    );
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

  // ── Legend: one chip per network with a live device count. Tap a chip to
  // light that group on the graph and fly to face it; tap again to let go.
  // Forward-looking networks (LoRa, radio) render dimmed while empty. ──
  Widget _buildLegend() {
    final counts = <RnsIface, int>{};
    for (final n in _allNodes) {
      if (n.kind == 'self') continue;
      counts[n.iface] = (counts[n.iface] ?? 0) + 1;
    }
    return Positioned(
      left: 10,
      right: 10,
      bottom: 12,
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final iface in RnsIface.values)
            if ((counts[iface] ?? 0) > 0 || iface.forwardLooking)
              _legendChip(iface, counts[iface] ?? 0),
        ],
      ),
    );
  }

  Widget _legendChip(RnsIface iface, int count) {
    final active = _focusedIface == iface;
    final dimmed = iface.forwardLooking && count == 0;
    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: InkWell(
        onTap: dimmed ? null : () => _focusIface(iface),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? iface.color.withValues(alpha: 0.22)
                : const Color(0xE6161B22),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: active ? iface.color : _gBorder,
                width: active ? 1.4 : 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 6),
              decoration:
                  BoxDecoration(color: iface.color, shape: BoxShape.circle),
            ),
            Text(iface.label,
                style: TextStyle(
                    color: active ? iface.color : _gFg, fontSize: 11.5)),
            const SizedBox(width: 5),
            Text('$count',
                style: TextStyle(
                    color: active ? iface.color : _gMuted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700)),
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
    // ONE source of truth, shared with the launcher's status bar
    // (RnsService.reachability). These counts used to be derived here, from the
    // graph's own node lists, and disagreed with the launcher badly enough to
    // look like a bug in both: "8 devices" on the home screen against "209
    // devices" here — the same word for two different populations.
    final reach = RnsService.instance.reachability();
    final geo = reach.geogram;
    final online = reach.others;
    final hubs = reach.hubs;
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
                      // NOT "devices": these are other people's Reticulum peers
                      // (Sideband, NomadNet, plain LXMF), not geogram devices.
                      // Calling both "devices" is what made this badge and the
                      // launcher look like they were contradicting each other.
                      Text(online == 1 ? 'peer' : 'peers',
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
        final n = _allNodes.where((e) => e.id == _selectedId).firstOrNull;
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
      case _Panel.page:
        content = _pageBody();
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

  Widget _detailBody(RnsGraphNode n) {
    final m = n.meta;
    final kindName = n.effectiveKind == 'self'
        ? 'This node'
        : n.effectiveKind == 'hub'
            ? 'Hub / transport node'
            : 'Peer';
    final pubkey = (m['pubkey'] ?? '').toString();
    final canMessage = n.kind != 'self' && n.dm.isNotEmpty && pubkey.isNotEmpty;
    final color = n.effectiveKind == 'self'
        ? _gSelf
        : n.effectiveKind == 'hub'
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
      if (n.effectiveKind == 'hub' && n.members > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.list, size: 16),
              label: Text('List ${n.members} devices'),
              onPressed: () {
                setState(() {
                  _panelHubId = n.id;
                  _expandedHubId = n.id;
                  _panel = _Panel.hubDevices;
                });
                _rebuildScene();
              },
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
      if (n.effectiveKind == 'hub' && n.members > 0)
        _kv('Peers heard', '≈ ${n.members} (sample)'),
      if (m['firstSeen'] != null) _kv('First seen', _ago(m['firstSeen'])),
      if (n.npub.isNotEmpty) _kv('npub', n.npub),
      if (n.id.isNotEmpty) _kv('Identity', n.id),
    ]);
  }

  // Open (or start) an LXMF conversation with a graph node. The conversation is
  // keyed by the node's LXMF delivery-dest — derived from its announced pubkey —
  // so incoming replies (same address) land in the same thread.
  void _messagePeer(RnsGraphNode n, String pubkey) {
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
  String _peerKey(RnsGraphNode n) {
    if (n.npub.isNotEmpty) return 'npub:${n.npub}';
    final call = (n.meta['callsign'] ?? '').toString();
    if (call.isNotEmpty) return 'call:${call.toUpperCase()}';
    return 'id:${n.id}';
  }

  // Collapse the same person heard from several identities/hubs into one row
  // (keeps the first, which is the best-labelled after sorting).
  List<RnsGraphNode> _dedupPeers(List<RnsGraphNode> src) {
    final seen = <String>{};
    final out = <RnsGraphNode>[];
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
  List<String> _reachableViaFor(RnsGraphNode n) {
    final key = _peerKey(n);
    final labels = <String>{};
    for (final o in _allNodes) {
      if (_peerKey(o) != key) continue;
      final r = o.effectiveRelayer;
      if (r.isEmpty) continue;
      final hub = _allNodes.where((h) => h.id == r).firstOrNull;
      labels.add(hub != null ? hub.label : 'hub ${_shorten(r, head: 8, tail: 0)}');
    }
    return labels.toList()..sort();
  }

  // Open the shared full profile page for a geogram peer (Follow / Message /
  // Mute + observed first-seen + reachable-via hubs).
  void _openPeerProfile(RnsGraphNode n) {
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
    final peers =
        _allNodes.where((n) => n.effectiveRelayer == hubId).toList()
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
  Widget _peerRow(RnsGraphNode p) {
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
      if (p.services.contains('node')) {
        // A NomadNet node → browse its pages.
        _openNodePage((p.meta['pubkey'] ?? '').toString(), p.label);
      } else if (p.geogram) {
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
  String _peerSubtitle(RnsGraphNode p) {
    final parts = <String>[];
    if (p.firstSeenMs > 0) parts.add('first seen ${_ago(p.firstSeenMs)}');
    final relayers =
        p.relayers.isNotEmpty
            ? p.relayers
            : (p.effectiveRelayer.isEmpty
                ? const <String>[]
                : [p.effectiveRelayer]);
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

  // ── NomadNet page browser ──
  // Open a node's page browser at its index (fresh history).
  void _openNodePage(String pubHex, String label,
      {String path = '/page/index.mu'}) {
    _pageHistory.clear();
    _pagePub = pubHex;
    _pageLabel = label;
    _loadPage(path);
  }

  // Fetch [path] on the current node ([_pagePub]) and show it. [fields] carries
  // dynamic-page/chatroom input.
  void _loadPage(String path, {Map<String, String>? fields}) {
    final seq = ++_pageSeq;
    setState(() {
      _pagePath = path;
      _pageText = null;
      _pageErr = null;
      _panel = _Panel.page;
    });
    if (_pagePub.isEmpty) {
      setState(() => _pageErr = 'No identity key for this node yet.');
      return;
    }
    RnsService.instance
        .fetchNomadPage(_pagePub, path, fields: fields)
        .then((bytes) {
      if (!mounted || seq != _pageSeq) return;
      setState(() {
        if (bytes == null) {
          _pageErr =
              'No response — the node may be offline or not serving $path.';
        } else {
          try {
            _pageText = utf8.decode(bytes, allowMalformed: true);
          } catch (_) {
            _pageText = String.fromCharCodes(bytes);
          }
        }
      });
    });
  }

  // A micron link/submit was tapped. Navigate on the same node; a ":/path"
  // target is node-relative. Pushes the current path so in-page back works.
  void _onPageLink(String url, Map<String, String> fields) {
    if (url.isEmpty) return;
    var path = url.startsWith(':') ? url.substring(1) : url;
    // A "hash:/path" target points at a DIFFERENT node — not yet supported.
    if (RegExp(r'^[0-9a-fA-F]{16,}:').hasMatch(path)) {
      setState(() => _pageErr = 'Links to other nodes are not supported yet.');
      return;
    }
    if (!path.startsWith('/')) path = '/$path';
    if (path != _pagePath) _pageHistory.add(_pagePath);
    _loadPage(path, fields: fields.isEmpty ? null : fields);
  }

  Widget _pageBody() {
    if (_pageErr != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, size: 34, color: _gMuted),
            const SizedBox(height: 12),
            Text(_pageErr!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _gMuted, fontSize: 13)),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry'),
              onPressed: () =>
                  _openNodePage(_pagePub, _pageLabel, path: _pagePath),
            ),
          ]),
        ),
      );
    }
    if (_pageText == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(height: 14),
          Text('Loading $_pagePath …',
              style: const TextStyle(color: _gMuted, fontSize: 13)),
        ]),
      );
    }
    // A thin path/toggle bar, then the rendered micron (or raw source).
    return Column(children: [
      Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        color: const Color(0x11FFFFFF),
        child: Row(children: [
          Expanded(
            child: Text(_pagePath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: _gMuted, fontSize: 11, fontFamily: 'monospace')),
          ),
          InkWell(
            onTap: () => setState(() => _pageSource = !_pageSource),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(_pageSource ? 'rendered' : 'source',
                  style: const TextStyle(color: _gSelf, fontSize: 11.5)),
            ),
          ),
        ]),
      ),
      Expanded(
        child: _pageSource
            ? ListView(padding: const EdgeInsets.all(14), children: [
                SelectableText(_pageText!,
                    style: const TextStyle(
                        color: _gFg,
                        fontSize: 12.5,
                        fontFamily: 'monospace',
                        height: 1.4)),
              ])
            : MicronView(_pageText!, onLink: _onPageLink),
      ),
    ]);
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

// ── Backdrop ───────────────────────────────────────────────────────────────
// Static starfield + faint polar grid (ported from graph3d's mesh_demo).
class _GraphBackdropPainter extends CustomPainter {
  const _GraphBackdropPainter();

  static ui.Picture? _picture;
  static Size _pictureSize = Size.zero;

  static ui.Picture _record(Size size) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Deep-space wash: barely-blue at the top fading to black.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(size.width / 2, 0),
          Offset(size.width / 2, size.height),
          const <Color>[Color(0xFF06141B), Color(0xFF020408)],
        ),
    );

    // Stars: three brightness tiers, deterministic.
    var state = 0x9E3779B9;
    double next() {
      state ^= state << 13;
      state ^= state >>> 17;
      state ^= state << 5;
      return (state & 0xFFFFFF) / 0xFFFFFF;
    }

    final star = Paint();
    for (var i = 0; i < 260; i++) {
      final x = next() * size.width;
      final y = next() * size.height;
      final tier = next();
      if (tier > 0.92) {
        star.color = const Color(0xB0CFF6FF);
        canvas.drawCircle(Offset(x, y), 1.4, star);
      } else if (tier > 0.7) {
        star.color = const Color(0x66A9D8E6);
        canvas.drawCircle(Offset(x, y), 1.0, star);
      } else {
        star.color = const Color(0x3370A5B8);
        canvas.drawCircle(Offset(x, y), 0.7, star);
      }
    }

    // A faint polar grid low in the frame: the "floor" of the scene.
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x1230C8D8);
    final centre = Offset(size.width / 2, size.height * 0.58);
    for (var ring = 1; ring <= 6; ring++) {
      canvas.drawOval(
        Rect.fromCenter(
          center: centre,
          width: size.width * 0.28 * ring,
          height: size.width * 0.1 * ring,
        ),
        grid,
      );
    }
    for (var spoke = 0; spoke < 12; spoke++) {
      final angle = spoke * pi / 6;
      canvas.drawLine(
        centre,
        centre +
            Offset(
              cos(angle) * size.width * 0.9,
              sin(angle) * size.width * 0.32,
            ),
        grid,
      );
    }

    return recorder.endRecording();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (_picture == null || _pictureSize != size) {
      _picture = _record(size);
      _pictureSize = size;
    }
    canvas.drawPicture(_picture!);
  }

  @override
  bool shouldRepaint(_GraphBackdropPainter oldDelegate) => false;
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
