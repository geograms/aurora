/// A native 3D card-graph engine: CSS3D-style perspective cards rendered as
/// baked GPU quads, an orbit camera, deterministic layouts, edges with
/// crawling markers, and manual picking. Extracted from the TripleCheck
/// software view; built for scenes from dozens to a few thousand nodes.
library;

export 'src/graph_view.dart' show CardState, Graph3DView;
export 'src/link_layer.dart' show LinkPainter, buildCrawlPeriods;
export 'src/model.dart';
export 'src/profile.dart' show kProfileScene;
export 'src/scene/card_bakery.dart';
export 'src/scene/crowd_painter.dart' show CardCrowdPainter, pickCard;
export 'src/scene/layouts.dart';
export 'src/scene/orbit_camera.dart';
export 'src/scene/pose.dart';
export 'src/scene/projection.dart';
export 'src/scene/sprite.dart';
export 'src/scene/sprite_crowd_painter.dart' show SpriteCrowdPainter, pickSprite;
export 'src/scene_controller.dart';
