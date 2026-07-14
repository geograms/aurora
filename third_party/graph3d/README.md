# graph3d

A native 3D card-graph engine for Flutter. CSS3D-style perspective cards
rendered as baked GPU quads, an orbit camera with damped inertia, animated
scene changes with enter/exit, edges with crawling markers, and manual
picking. Runs the same on Linux, Android, macOS, Windows and iOS; measured at
72-91fps with hundreds of cards on a low-end 90Hz phone.

Use it as a path dependency:

    dependencies:
      graph3d:
        path: ../graph3d        # wherever this package sits

## The five-minute tour

```dart
import 'package:graph3d/graph3d.dart';

// 1. Your data, wrapped in keyed nodes. The key is durable identity:
//    it carries selection, hover and the texture cache across scene changes.
final scene = GraphScene<MyThing>(
  nodes: [for (final t in things) SceneNode(key: t.id, data: t)],
  edges: [SceneEdge(1, 2, style: EdgeStyle(color: Colors.teal, label: 'TCP'))],
);

// 2. A controller owns the camera, transitions, selection and hover.
final controller = GraphSceneController<MyThing>(vsync: this);
controller.setScene(scene, layout: gridLayout());

// 3. A bakery rasterizes each card once into a GPU texture.
final bakery = CardBakery<MyThing>(
  paint: (canvas, thing, alpha) { /* draw 120x160 card content */ },
);

// 4. The view wires gestures, picking and the three render layers.
Graph3DView<MyThing>(
  controller: controller,
  bakery: bakery,
  liveCardBuilder: (context, node, state) => MyLiveCard(node, state),
);
```

Layouts are plain functions (`LayoutStrategy<T>`); `tableLayout`,
`helixLayout` and `gridLayout` ship with the engine, and `ringPoses` /
`sunflowerDiscPoses` help build network-style layouts. `setScene` diffs by
key: persisting nodes glide to their new poses, new nodes fly in, vanished
nodes fly out and fade before being pruned — which is what makes
cluster-style expand/collapse a single call.

## Examples

- **example/mesh_demo** — a cinematic Reticulum mesh visualization: glowing
  orbs colored by interface (BLE, LAN, WiFi-Direct, TCP, UDP, LoRa, radio),
  an ego view of what one node honestly knows (hop-distance shells, ghost
  segments for unknowable path middles, edge bridges), a backbone aggregate
  view, cluster expand/collapse, path walking with holographic detail
  panels. Dummy data, deterministic. Design rationale, before/after
  screenshots and on-device measurements: `example/mesh_demo/ANALYSIS.md`.
- **example/triplecheck** — the original TripleCheck software view this
  engine was extracted from: 426 files, search query language, review flow.

Both run with `flutter run -d linux` (or build an APK) from their directory.

## Why cards are baked

Flutter disables its raster cache under a perspective transform and Android
has no partial repaint, so a Stack of `Transform`ed widget cards re-draws
every glyph of every card on every animated frame — 21-30ms of raster for 426
cards on an Oukitel C61, a hard ~35fps ceiling that no `RepaintBoundary`
arrangement fixes. `CardBakery` rasterizes each card once (`toImageSync`,
LRU-bounded); `CardCrowdPainter` culls, depth-sorts and draws them as
textured quads through one perspective `canvas.transform` each. Same phone,
worst case: build 3-7ms, raster 5-14ms. The one or two cards that matter
(selected, hovered) render as live widgets on top — crisp at any zoom, free
to carry a glow, which as a per-frame blur only they can afford.

Two traps this design routes around, both measured: `Transform.filterQuality`
snapshots through `ImageFilter.matrix`, which cannot express perspective, so
it silently draws nothing; and `Quaternion.rotated` in vector_math applies
the *inverse* rotation while `asRotationMatrix`/`Matrix4.compose` apply the
forward one — mixing them makes an orbit camera circle a point it is not
looking at.

## Measuring

    flutter build apk --release --dart-define=GRAPH3D_FRAME_STATS=true
    adb logcat | grep -E 'FRAMES|CROWDPAINT|LINKPAINT|ADVANCE'

The examples print wall-clock frame windows (even at n=0, so idle is
provably idle) plus per-subsystem paint timings.
