// Slippy map widget, radius circle/slider, marker clustering and the
// map screen — extracted from wapp_page.dart. Part of the wapp_page
// library: map builders are an extension on _WappPageState (which still
// holds the map state fields); the widgets are top-level classes.

part of 'wapp_page.dart';

// Log-scale radius mapping bounds (km), used by the slider helpers.
const double _rMin = 1, _rMid = 100, _rMax = 1000;

/// Paints the coverage/filter radius circle on the map.
class _RadiusCirclePainter extends CustomPainter {
  final double cx, cy, radiusPx;
  _RadiusCirclePainter(
      {required this.cx, required this.cy, required this.radiusPx});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(cx, cy);
    canvas.drawCircle(
        c, radiusPx, Paint()..color = const Color(0x2258A6FF));
    canvas.drawCircle(
        c,
        radiusPx,
        Paint()
          ..color = const Color(0xAA58A6FF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    // small dot at the center (my station)
    canvas.drawCircle(c, 4, Paint()..color = const Color(0xFF58A6FF));
  }

  @override
  bool shouldRepaint(_RadiusCirclePainter o) =>
      o.cx != cx || o.cy != cy || o.radiusPx != radiusPx;
}

class _SlippyMap extends StatefulWidget {
  final double lat, lon;
  final int zoom, minZoom, maxZoom;
  final String tileUrl;
  final void Function(double lat, double lon, int zoom) onViewportChanged;

  /// Pins to overlay on the map. Each map is {id, lat, lon, label, color?,
  /// kind?} pushed by the wapp via `ui.map.marker`.
  final List<Map<String, dynamic>> markers;

  /// Called with a marker's id when its pin is tapped.
  final void Function(String id)? onMarkerTap;

  /// Coverage circle: filter radius (km) drawn around the station at
  /// [centerLat]/[centerLon]. Null disables the circle + slider.
  final double? radiusKm;
  final double? centerLat;
  final double? centerLon;

  /// Fired (on slider release) with the new radius in km.
  final void Function(double km)? onRadiusChanged;

  /// Fired (on drag release) with the new circle centre when the user
  /// drags the centre handle to move the coverage area.
  final void Function(double lat, double lon)? onCenterChanged;

  /// Floating geo-chat, split into Live (unique/manual) and Beacons
  /// (messages seen repeating within 10 min). Each {from,text,time,...}.
  final List<Map<String, dynamic>> chatLive;
  final List<Map<String, dynamic>> chatBeacons;

  /// Fired with the composed text from the floating chat box.
  final void Function(String text)? onChatSend;

  /// Fired to clear a geo-chat tab (0 = Live, 1 = Beacons).
  final void Function(int tab)? onClearChat;

  /// Tapping a geo-chat message's location meta (carries lat/lon).
  final void Function(Map<String, dynamic>)? onLocate;

  /// A highlighted point (the last "locate" target) drawn as a reticle.
  final double? highlightLat, highlightLon;

  const _SlippyMap({
    required this.lat,
    required this.lon,
    required this.zoom,
    required this.tileUrl,
    required this.minZoom,
    required this.maxZoom,
    required this.onViewportChanged,
    this.markers = const [],
    this.onMarkerTap,
    this.radiusKm,
    this.centerLat,
    this.centerLon,
    this.onRadiusChanged,
    this.onCenterChanged,
    this.chatLive = const [],
    this.chatBeacons = const [],
    this.onChatSend,
    this.onClearChat,
    this.onLocate,
    this.highlightLat,
    this.highlightLon,
  });

  @override
  State<_SlippyMap> createState() => _SlippyMapState();
}

class _SlippyMapState extends State<_SlippyMap>
    with SingleTickerProviderStateMixin {
  static const _tileSize = 256.0;

  late double _pxX, _pxY; // top-left in world pixels
  late int _zoom;
  Offset? _dragStart;
  double? _dragPxX, _dragPxY;

  // Circle interaction: 'move' (drag anywhere inside) or 'resize' (drag the
  // edge band); null means the pan moves the map. Drag overrides apply live.
  String? _circleDrag;
  double? _dragCenterLat, _dragCenterLon, _dragRadiusKm;
  Offset? _circleC0; // circle centre (screen px) captured when a move begins

  // Search
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  List<_SearchResult>? _searchResults;
  bool _searching = false;
  Timer? _debounce;

  // Floating geo-chat visibility + active tab (0 = Live, 1 = Beacons).
  bool _showChat = true;
  int _geoTab = 0;

  /// Current circle centre in screen pixels (honouring an in-progress
  /// move drag), or null when there's no circle.
  Offset? _circleCenterPx() {
    if (widget.centerLat == null || widget.radiusKm == null) return null;
    final lat = _dragCenterLat ?? widget.centerLat!;
    final lon = _dragCenterLon ?? widget.centerLon!;
    return Offset(_lon2px(lon, _zoom) - _pxX, _lat2px(lat, _zoom) - _pxY);
  }

  /// Radius in screen pixels at the current zoom (Web-Mercator ground
  /// resolution at the circle's latitude).
  double _radiusPx(double km) {
    final lat = widget.centerLat ?? widget.lat;
    final groundRes =
        cos(lat * pi / 180) * 2 * pi * 6378137 / (_tileSize * pow(2, _zoom));
    return (km * 1000) / groundRes;
  }

  /// True when the whole viewport sits inside the circle, so its edge isn't
  /// visible anywhere. In that state the circle is just a full-screen tint
  /// that would hijack every drag — so we stop drawing it and let drags pan
  /// the map normally (zoom out to bring the circle back into play).
  bool _circleEngulfsView(double w, double h) {
    final c = _circleCenterPx();
    if (c == null) return false;
    final rPx = _radiusPx(_dragRadiusKm ?? widget.radiusKm!);
    var far = 0.0;
    for (final p in [
      const Offset(0, 0),
      Offset(w, 0),
      Offset(0, h),
      Offset(w, h),
    ]) {
      far = max(far, (p - c).distance);
    }
    return far < rPx;
  }

  List<Widget> _buildChatOverlay(double w, double h) {
    // Portrait / phone: the panel can't sit full-height on the right or it
    // covers the map — show a bottom sheet (map visible above) instead.
    final narrow = w < 600;
    if (!_showChat) {
      return [
        Positioned(
          right: 12,
          bottom: narrow ? 16 : 70,
          child: FloatingActionButton.small(
            heroTag: 'geochat-toggle',
            onPressed: () => setState(() => _showChat = true),
            child: const Icon(Icons.chat_bubble_outline),
          ),
        ),
      ];
    }
    final panel = _chatPanel();
    if (narrow) {
      return [
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          height: (h * 0.46).clamp(180.0, 440.0),
          child: panel,
        ),
      ];
    }
    return [
      Positioned(right: 12, top: 64, bottom: 60, width: 320, child: panel),
    ];
  }

  Widget _chatPanel() {
    final live = widget.chatLive;
    final beacons = widget.chatBeacons;
    final showing = _geoTab == 0 ? live : beacons;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(230),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF30363d)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 2, 0),
            child: Row(
              children: [
                const Icon(Icons.chat_bubble_outline,
                    size: 16, color: Colors.white70),
                const SizedBox(width: 8),
                const Text('Geo Chat',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_sweep,
                      size: 18, color: Colors.white60),
                  tooltip: 'Clear ${_geoTab == 0 ? "Live" : "Beacons"}',
                  visualDensity: VisualDensity.compact,
                  onPressed: showing.isEmpty
                      ? null
                      : () => widget.onClearChat?.call(_geoTab),
                ),
                IconButton(
                  icon: const Icon(Icons.close,
                      size: 16, color: Colors.white54),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _showChat = false),
                ),
              ],
            ),
          ),
          // Live | Beacons tabs.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Row(
              children: [
                _geoTabButton('Live', live.length, 0),
                const SizedBox(width: 6),
                _geoTabButton('Beacons', beacons.length, 1),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ChatViewField(
              key: ValueKey('geochat-$_geoTab'),
              fieldName: 'geochat',
              label: '',
              hint: _geoTab == 0 ? 'Message…' : 'Repeated beacons',
              fill: true,
              messages: showing,
              onLocate: widget.onLocate,
              onSend: (t) => widget.onChatSend?.call(t),
            ),
          ),
        ],
      ),
    );
  }

  Widget _geoTabButton(String label, int count, int idx) {
    final sel = _geoTab == idx;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _geoTab = idx),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(
            color: sel ? const Color(0x332B5278) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: sel ? const Color(0xFF2B5278) : const Color(0x33FFFFFF)),
          ),
          alignment: Alignment.center,
          child: Text('$label ($count)',
              style: TextStyle(
                  color: sel ? Colors.white : Colors.white60,
                  fontSize: 12,
                  fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
        ),
      ),
    );
  }

  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _zoom = widget.zoom;
    _centerOn(widget.lat, widget.lon);
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
  }

  @override
  void didUpdateWidget(_SlippyMap old) {
    super.didUpdateWidget(old);
    if ((old.lat - widget.lat).abs() > 0.0001 ||
        (old.lon - widget.lon).abs() > 0.0001 ||
        old.zoom != widget.zoom) {
      _zoom = widget.zoom;
      _centerOn(widget.lat, widget.lon);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _doSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _searchResults = null);
      return;
    }
    setState(() => _searching = true);

    // Check if it's raw coordinates (lat, lon)
    final coordMatch = RegExp(r'^(-?\d+\.?\d*)\s*[,\s]\s*(-?\d+\.?\d*)$')
        .firstMatch(query.trim());
    if (coordMatch != null) {
      final lat = double.tryParse(coordMatch.group(1)!);
      final lon = double.tryParse(coordMatch.group(2)!);
      if (lat != null && lon != null) {
        setState(() {
          _searchResults = [_SearchResult('$lat, $lon', 'Coordinates', lat, lon)];
          _searching = false;
        });
        return;
      }
    }

    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': query,
        'format': 'json',
        'limit': '8',
        'addressdetails': '1',
      });
      final resp = await HttpTransport.shared.get(
        uri,
        headers: const {'User-Agent': 'Geogram/1.0'},
        timeout: const Duration(seconds: 10),
      );
      final body = resp.bodyString;

      final results = (jsonDecode(body) as List).map((r) {
        final lat = double.tryParse(r['lat']?.toString() ?? '') ?? 0;
        final lon = double.tryParse(r['lon']?.toString() ?? '') ?? 0;
        final name = r['display_name'] as String? ?? '';
        final type = r['type'] as String? ?? '';
        return _SearchResult(name, type, lat, lon);
      }).toList();

      // Sort by distance from current center
      final size = _viewSize;
      final cLat = _px2lat(_pxY + size.height / 2, _zoom);
      final cLon = _px2lon(_pxX + size.width / 2, _zoom);
      results.sort((a, b) {
        final da = _distDeg(a.lat, a.lon, cLat, cLon);
        final db = _distDeg(b.lat, b.lon, cLat, cLon);
        return da.compareTo(db);
      });

      setState(() { _searchResults = results; _searching = false; });
    } catch (_) {
      setState(() { _searchResults = []; _searching = false; });
    }
  }

  double _distDeg(double lat1, double lon1, double lat2, double lon2) {
    final dlat = lat1 - lat2, dlon = lon1 - lon2;
    return sqrt(dlat * dlat + dlon * dlon);
  }

  void _goToResult(_SearchResult r) {
    setState(() {
      _searchResults = null;
      _searchController.clear();
      _zoom = 15;
      _centerOn(r.lat, r.lon);
    });
    _syncViewport();
  }

  void _centerOn(double lat, double lon) {
    final size = _viewSize;
    _pxX = _lon2px(lon, _zoom) - size.width / 2;
    _pxY = _lat2px(lat, _zoom) - size.height / 2;
  }

  Size get _viewSize {
    final ctx = context;
    final rb = ctx.findRenderObject() as RenderBox?;
    return rb?.size ?? const Size(800, 600);
  }

  double _lon2px(double lon, int z) =>
      ((lon + 180) / 360) * _tileSize * pow(2, z);
  double _lat2px(double lat, int z) {
    final r = pi / 180 * lat;
    return (1 - log(tan(r) + 1 / cos(r)) / pi) / 2 * _tileSize * pow(2, z);
  }
  double _px2lon(double px, int z) =>
      px / (_tileSize * pow(2, z)) * 360 - 180;
  double _px2lat(double py, int z) {
    final n = pi - 2 * pi * py / (_tileSize * pow(2, z));
    return 180 / pi * atan(0.5 * (exp(n) - exp(-n)));
  }

  /// Group markers that would overlap on screen into a single cluster
  /// bubble showing the count, so dense areas stay readable. Tapping a
  /// cluster zooms in to break it apart.
  List<Widget> _clusterMarkers(double w, double h) {
    const cell = 50.0; // px proximity that triggers grouping
    final pts = <Offset>[];
    final mk = <Map<String, dynamic>>[];
    for (final m in widget.markers) {
      final lat = (m['lat'] as num?)?.toDouble();
      final lon = (m['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      pts.add(Offset(
          _lon2px(lon, _zoom) - _pxX, _lat2px(lat, _zoom) - _pxY));
      mk.add(m);
    }
    final used = List<bool>.filled(pts.length, false);
    final out = <Widget>[];
    for (var i = 0; i < pts.length; i++) {
      if (used[i]) continue;
      used[i] = true;
      final group = <int>[i];
      for (var j = i + 1; j < pts.length; j++) {
        if (!used[j] && (pts[j] - pts[i]).distance <= cell) {
          used[j] = true;
          group.add(j);
        }
      }
      if (group.length == 1) {
        out.add(_buildMarker(mk[i], w, h));
      } else {
        double ax = 0, ay = 0;
        for (final g in group) { ax += pts[g].dx; ay += pts[g].dy; }
        ax /= group.length;
        ay /= group.length;
        if (ax < -60 || ax > w + 60 || ay < -60 || ay > h + 60) continue;
        out.add(_buildCluster(ax, ay, group.length));
      }
    }
    return out;
  }

  /// Draw a pulsing reticle on the last "locate" target so the user can
  /// immediately spot it among the other pins.
  List<Widget> _buildHighlight(double w, double h) {
    final lat = widget.highlightLat, lon = widget.highlightLon;
    if (lat == null || lon == null) return const [];
    final px = _lon2px(lon, _zoom) - _pxX;
    final py = _lat2px(lat, _zoom) - _pxY;
    if (px < -80 || px > w + 80 || py < -80 || py > h + 80) return const [];
    const box = 120.0;
    return [
      Positioned(
        left: px - box / 2,
        top: py - box / 2,
        width: box,
        height: box,
        child: IgnorePointer(
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final t = _pulse.value; // 0..1
              final ringSize = 26.0 + t * 70.0;
              return Stack(
                alignment: Alignment.center,
                children: [
                  // Expanding fading pulse ring.
                  Opacity(
                    opacity: (1 - t) * 0.7,
                    child: Container(
                      width: ringSize,
                      height: ringSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: const Color(0xFF00E5FF), width: 3),
                      ),
                    ),
                  ),
                  // Steady reticle: bright ring + centre dot.
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: const Color(0xFF00E5FF), width: 3),
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 4),
                      ],
                    ),
                  ),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFF00E5FF),
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ];
  }

  /// A cluster bubble: orange circle with the callsign count; tap to
  /// zoom in (which separates the grouped pins).
  Widget _buildCluster(double cx, double cy, int n) {
    const sz = 38.0;
    return Positioned(
      left: cx - sz / 2,
      top: cy - sz / 2,
      width: sz,
      height: sz,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _zoomBy(2, Offset(cx, cy)),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xE6FB8C00),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 4),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            n > 999 ? '999+' : '$n',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: n > 99 ? 11 : 13,
            ),
          ),
        ),
      ),
    );
  }

  /// Build one marker pin (label chip + teardrop icon), anchored so the
  /// icon's tip sits on the geographic point. Off-screen markers collapse.
  Widget _buildMarker(Map<String, dynamic> m, double w, double h) {
    final lat = (m['lat'] as num?)?.toDouble();
    final lon = (m['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return const SizedBox.shrink();
    final px = _lon2px(lon, _zoom) - _pxX;
    final py = _lat2px(lat, _zoom) - _pxY;
    if (px < -200 || px > w + 200 || py < -200 || py > h + 200) {
      return const SizedBox.shrink();
    }
    final label = (m['label'] as String?) ?? (m['id']?.toString() ?? '');
    final color = _markerColor(m['color']);
    const pinW = 140.0;
    return Positioned(
      left: px - pinW / 2,
      top: py - 46,
      width: pinW,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onMarkerTap?.call(m['id']?.toString() ?? ''),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (label.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(204),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold),
                ),
              ),
            Icon(Icons.location_on,
                color: color,
                size: 28,
                shadows: const [Shadow(color: Colors.black54, blurRadius: 3)]),
          ],
        ),
      ),
    );
  }

  Color _markerColor(dynamic raw) {
    if (raw is String && raw.isNotEmpty) {
      var s = raw.replaceAll('#', '');
      if (s.length == 6) s = 'FF$s';
      final v = int.tryParse(s, radix: 16);
      if (v != null) return Color(v);
      switch (raw.toLowerCase()) {
        case 'red':
          return const Color(0xFFE53935);
        case 'green':
          return const Color(0xFF43A047);
        case 'blue':
          return const Color(0xFF1E88E5);
        case 'orange':
          return const Color(0xFFFB8C00);
      }
    }
    return const Color(0xFFE53935);
  }

  void _syncViewport() {
    final size = _viewSize;
    final lat = _px2lat(_pxY + size.height / 2, _zoom);
    final lon = _px2lon(_pxX + size.width / 2, _zoom);
    widget.onViewportChanged(lat, lon, _zoom);
  }

  void _zoomBy(int delta, [Offset? focus]) {
    final newZoom = (_zoom + delta).clamp(widget.minZoom, widget.maxZoom);
    if (newZoom == _zoom) return;
    final size = _viewSize;
    final fx = focus?.dx ?? size.width / 2;
    final fy = focus?.dy ?? size.height / 2;
    final worldX = _pxX + fx, worldY = _pxY + fy;
    final scale = pow(2, newZoom - _zoom).toDouble();
    setState(() {
      _zoom = newZoom;
      _pxX = worldX * scale - fx;
      _pxY = worldY * scale - fy;
    });
    _syncViewport();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth, h = constraints.maxHeight;
      final tileXMin = (_pxX / _tileSize).floor();
      final tileYMin = (_pxY / _tileSize).floor();
      final tileXMax = ((_pxX + w) / _tileSize).floor();
      final tileYMax = ((_pxY + h) / _tileSize).floor();
      final maxTile = pow(2, _zoom).toInt() - 1;

      final tiles = <Widget>[];
      for (var ty = tileYMin; ty <= tileYMax; ty++) {
        for (var tx = tileXMin; tx <= tileXMax; tx++) {
          final wrappedX = ((tx % (maxTile + 1)) + (maxTile + 1)) % (maxTile + 1);
          if (ty < 0 || ty > maxTile) continue;
          final url = widget.tileUrl
              .replaceAll('{z}', '$_zoom')
              .replaceAll('{x}', '$wrappedX')
              .replaceAll('{y}', '$ty');
          tiles.add(Positioned(
            left: tx * _tileSize - _pxX,
            top: ty * _tileSize - _pxY,
            width: _tileSize,
            height: _tileSize,
            child: Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Container(color: const Color(0xFF0a0e14)),
            ),
          ));
        }
      }

      final centerLat = _px2lat(_pxY + h / 2, _zoom);
      final centerLon = _px2lon(_pxX + w / 2, _zoom);

      final mapStack = GestureDetector(
        onPanStart: (d) {
          // The edge band resizes; anywhere else inside the circle moves it
          // (relative to the grab, so it doesn't jump). Outside pans the map.
          // When the circle engulfs the whole view it's not manipulable —
          // skip it entirely so the drag pans the map.
          final c = _circleEngulfsView(w, h) ? null : _circleCenterPx();
          if (c != null) {
            final dist = (d.localPosition - c).distance;
            final rPx = _radiusPx(_dragRadiusKm ?? widget.radiusKm!);
            if ((dist - rPx).abs() <= 16) {
              _circleDrag = 'resize';
              _dragRadiusKm = widget.radiusKm;
              return;
            }
            if (dist < rPx) {
              _circleDrag = 'move';
              _circleC0 = c;
              _dragStart = d.localPosition;
              _dragCenterLat = widget.centerLat;
              _dragCenterLon = widget.centerLon;
              return;
            }
          }
          _circleDrag = null;
          _dragStart = d.localPosition;
          _dragPxX = _pxX;
          _dragPxY = _pxY;
        },
        onPanUpdate: (d) {
          if (_circleDrag == 'move') {
            // Move the centre by the same delta as the pointer (relative).
            final np = _circleC0! + (d.localPosition - _dragStart!);
            setState(() {
              _dragCenterLon = _px2lon(_pxX + np.dx, _zoom);
              _dragCenterLat = _px2lat(_pxY + np.dy, _zoom);
            });
            return;
          }
          if (_circleDrag == 'resize') {
            final c = _circleCenterPx()!;
            final dist = (d.localPosition - c).distance;
            final lat = _dragCenterLat ?? widget.centerLat ?? widget.lat;
            final groundRes = cos(lat * pi / 180) * 2 * pi * 6378137 /
                (_tileSize * pow(2, _zoom));
            final km = (dist * groundRes) / 1000.0;
            setState(() => _dragRadiusKm = km.clamp(1.0, 1000.0));
            return;
          }
          setState(() {
            _pxX = _dragPxX! - (d.localPosition.dx - _dragStart!.dx);
            _pxY = _dragPxY! - (d.localPosition.dy - _dragStart!.dy);
          });
        },
        onPanEnd: (_) {
          if (_circleDrag == 'move') {
            final la = _dragCenterLat, lo = _dragCenterLon;
            _circleDrag = null;
            setState(() {
              _dragCenterLat = null;
              _dragCenterLon = null;
            });
            if (la != null && lo != null) widget.onCenterChanged?.call(la, lo);
            return;
          }
          if (_circleDrag == 'resize') {
            final km = _dragRadiusKm;
            _circleDrag = null;
            setState(() => _dragRadiusKm = null);
            if (km != null) widget.onRadiusChanged?.call(km.roundToDouble());
            return;
          }
          _syncViewport();
        },
        child: Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              final delta = event.scrollDelta.dy < 0 ? 1 : -1;
              _zoomBy(delta, event.localPosition);
            }
          },
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Container(color: const Color(0xFF0a0e14)),
              ...tiles,
              // Coverage radius circle (filter area). Centre + radius
              // honour an in-progress move/resize drag for live feedback.
              // Hidden when it engulfs the whole view (zoomed in past its
              // edge) so the map stays clear and pannable.
              if (widget.radiusKm != null &&
                  widget.centerLat != null &&
                  !_circleEngulfsView(w, h))
                Positioned.fill(
                  child: CustomPaint(
                    painter: _RadiusCirclePainter(
                      cx: _lon2px(_dragCenterLon ?? widget.centerLon!, _zoom) -
                          _pxX,
                      cy: _lat2px(_dragCenterLat ?? widget.centerLat!, _zoom) -
                          _pxY,
                      radiusPx: _radiusPx(_dragRadiusKm ?? widget.radiusKm!),
                    ),
                  ),
                ),
              // Marker pins (clustered when they would overlap).
              ..._clusterMarkers(w, h),
              // Highlighted "locate" target — a pulsing reticle on top.
              ..._buildHighlight(w, h),
              // Search bar
              Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: Column(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xF0161b22),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF30363d)),
                      ),
                      child: Row(
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: Icon(Icons.search, size: 18, color: Color(0xFF8b949e)),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              focusNode: _searchFocus,
                              style: const TextStyle(fontSize: 13, color: Color(0xFFe6edf3)),
                              decoration: const InputDecoration(
                                hintText: 'Search address or coordinates...',
                                hintStyle: TextStyle(color: Color(0xFF8b949e), fontSize: 13),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                isDense: true,
                              ),
                              onChanged: (v) {
                                _debounce?.cancel();
                                _debounce = Timer(const Duration(milliseconds: 400), () => _doSearch(v));
                              },
                              onSubmitted: _doSearch,
                            ),
                          ),
                          if (_searching)
                            const Padding(
                              padding: EdgeInsets.only(right: 10),
                              child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          else if (_searchController.text.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.close, size: 16, color: Color(0xFF8b949e)),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchResults = null);
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            ),
                        ],
                      ),
                    ),
                    if (_searchResults != null && _searchResults!.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        constraints: const BoxConstraints(maxHeight: 240),
                        decoration: BoxDecoration(
                          color: const Color(0xF0161b22),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF30363d)),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: _searchResults!.length,
                          separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF30363d)),
                          itemBuilder: (context, i) {
                            final r = _searchResults![i];
                            return InkWell(
                              onTap: () => _goToResult(r),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      r.name.length > 80 ? '${r.name.substring(0, 80)}...' : r.name,
                                      style: const TextStyle(fontSize: 12, color: Color(0xFFe6edf3)),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '${r.lat.toStringAsFixed(5)}, ${r.lon.toStringAsFixed(5)}',
                                      style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Color(0xFF8b949e)),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    if (_searchResults != null && _searchResults!.isEmpty && !_searching)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xF0161b22),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF30363d)),
                        ),
                        child: const Text('No results found', style: TextStyle(fontSize: 12, color: Color(0xFF8b949e))),
                      ),
                  ],
                ),
              ),
              // Zoom controls \u2014 left, vertically centred so they stay clear
              // of the right-side chat panel (landscape) and the bottom-sheet
              // chat (portrait/phone). Nudged up in portrait so the lower
              // button clears the bottom sheet.
              Positioned(
                left: 12,
                top: h / 2 - (w < 600 ? 64 : 44),
                child: _buildZoomControl(),
              ),
              // Coordinates \u2014 lower-right corner; in portrait they sit just
              // above the geo-chat bottom sheet's right corner.
              Positioned(
                right: 12,
                bottom: w < 600
                    ? (_showChat
                        ? (h * 0.46).clamp(180.0, 440.0) + 12
                        : 64)
                    : 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${centerLat.toStringAsFixed(5)}, ${centerLon.toStringAsFixed(5)} z$_zoom',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Color(0xFF8b949e),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      // The geo-chat overlay sits OUTSIDE the map's GestureDetector/Listener
      // so drags and the mouse wheel over it drive the chat (scroll/compose),
      // never the map underneath.
      return Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned.fill(child: mapStack),
          if (widget.onChatSend != null) ..._buildChatOverlay(w, h),
        ],
      );
    });
  }

  /// A single unified zoom control (+ over −, split by a divider) — the
  /// familiar map widget, with a rounded translucent body and a shadow.
  Widget _buildZoomControl() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xF0161b22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF30363d)),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _zoomBtn(Icons.add, () => _zoomBy(1),
              radius: const BorderRadius.vertical(top: Radius.circular(10))),
          Container(width: 30, height: 1, color: const Color(0xFF30363d)),
          _zoomBtn(Icons.remove, () => _zoomBy(-1),
              radius: const BorderRadius.vertical(bottom: Radius.circular(10))),
        ],
      ),
    );
  }

  Widget _zoomBtn(IconData icon, VoidCallback onTap,
      {required BorderRadius radius}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: SizedBox(
          width: 42,
          height: 40,
          child: Center(
            child: Icon(icon, size: 20, color: const Color(0xFFE6EDF3)),
          ),
        ),
      ),
    );
  }
}

class _SearchResult {
  final String name;
  final String type;
  final double lat, lon;
  _SearchResult(this.name, this.type, this.lat, this.lon);
}

extension _WappMaps on _WappPageState {
  Widget _buildMapScreen(GeoUiBlock screen, GeoUiBlock mapGroup) {
    return Column(
      children: [
        _buildMapRadiusBar(),
        Expanded(
          child: _SlippyMap(
      lat: _mapLat,
      lon: _mapLon,
      zoom: _mapZoom,
      tileUrl: _tileUrl,
      minZoom: mapGroup.getNumber('min-zoom')?.toInt() ?? 2,
      maxZoom: mapGroup.getNumber('max-zoom')?.toInt() ?? 18,
      markers: _mapMarkers.values.toList(),
      onMarkerTap: (id) {
        _engine.sendMessage(jsonEncode({'command': 'marker_tap', 'id': id}));
        _engine.handleEvent();
        _drainOutbox();
        if (mounted) setState(() {});
      },
      onViewportChanged: (lat, lon, zoom) {
        _mapLat = lat;
        _mapLon = lon;
        _mapZoom = zoom;
        _engine.sendMessage(jsonEncode({
          'type': 'setViewport',
          'lat': lat,
          'lon': lon,
          'zoom': zoom,
        }));
        _engine.handleEvent();
        _drainOutbox();
      },
      radiusKm: _mapDragKm ?? _mapRadiusKm,
      centerLat: _mapCenterLat,
      centerLon: _mapCenterLon,
      onRadiusChanged: (km) {
        _mapRadiusKm = km;
        // Keep both the slider's value and the Settings field in sync so
        // a later Connect uses the same radius.
        _fieldValues['map_radius'] = km.round().toString();
        _fieldValues['radius_km'] = km.round().toString();
        _sendCommand('set_radius');
        if (mounted) setState(() {});
      },
      onCenterChanged: (lat, lon) {
        // Move the coverage area: update centre + my-position fields and
        // re-filter (set_radius reconnects with the new r/lat/lon/km).
        _mapCenterLat = lat;
        _mapCenterLon = lon;
        _fieldValues['my_lat'] = lat.toStringAsFixed(5);
        _fieldValues['my_lon'] = lon.toStringAsFixed(5);
        _sendCommand('set_radius');
        if (mounted) setState(() {});
      },
      chatLive: _geoLive,
      chatBeacons: _geoBeacons,
      onClearChat: (tab) {
        // Clear the chosen tab's list (keeps the seen/beacon keys so
        // future repeats still classify correctly).
        if (tab == 0) {
          _geoLive.clear();
        } else {
          _geoBeacons.clear();
        }
        if (mounted) setState(() {});
      },
      onChatSend: (text) {
        _fieldValues['geochat_input'] = text;
        _sendCommand('geochat_send');
        if (mounted) setState(() {});
      },
      onLocate: _locateFromMessage,
      highlightLat: _locateLat,
      highlightLon: _locateLon,
          ),
        ),
      ],
    );
  }

  double _sliderToKm(double t) => t <= 0.5
      ? _rMin * pow(_rMid / _rMin, t / 0.5).toDouble()
      : _rMid * pow(_rMax / _rMid, (t - 0.5) / 0.5).toDouble();

  double _kmToSlider(double km) {
    km = km.clamp(_rMin, _rMax);
    return km <= _rMid
        ? 0.5 * (log(km / _rMin) / log(_rMid / _rMin))
        : 0.5 + 0.5 * (log(km / _rMid) / log(_rMax / _rMid));
  }

  double _snapKm(double km) {
    if (km < 10) return (km * 2).round() / 2;
    if (km < 100) return km.round().toDouble();
    return (km / 10).round() * 10;
  }

  /// The radius slider strip shown above the map. Dragging updates the
  /// circle live; releasing commits (re-filters the APRS-IS feed).
  Widget _buildMapRadiusBar() {
    final cs = Theme.of(context).colorScheme;
    final km = _mapDragKm ?? _mapRadiusKm ?? 100;
    final label = km >= 10 ? '${km.round()} km' : '${km.toStringAsFixed(1)} km';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      color: cs.surfaceContainerHighest.withAlpha(120),
      child: Row(
        children: [
          Icon(Icons.cell_tower, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          const Text('Range', style: TextStyle(fontSize: 13)),
          Expanded(
            child: Slider(
              value: _kmToSlider(km),
              onChanged: (t) =>
                  setState(() => _mapDragKm = _snapKm(_sliderToKm(t))),
              onChangeEnd: (t) {
                final v = _snapKm(_sliderToKm(t));
                setState(() {
                  _mapDragKm = null;
                  _mapRadiusKm = v;
                });
                _fieldValues['map_radius'] = v.round().toString();
                _fieldValues['radius_km'] = v.round().toString();
                _sendCommand('set_radius');
              },
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(label,
                textAlign: TextAlign.end,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
