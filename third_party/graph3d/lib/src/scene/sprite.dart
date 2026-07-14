import 'dart:ui';

import 'package:flutter/foundation.dart';

/// How one node draws in sprite mode: a screen-facing glow orb.
///
/// Pure visual data — emphasis, enter/exit fade and depth fog are applied
/// uniformly by the painter on top of this.
@immutable
class NodeSprite {
  const NodeSprite({
    required this.radius,
    required this.coreColor,
    this.haloScale = 2.6,
    this.ringColor,
    this.secondaryColor,
    this.badge,
    this.badgeMinPx,
    this.label,
    this.labelMinPx,
  });

  /// Core radius in world units. The engine's own scale reference: a card is
  /// 120 wide, so hubs ≈ 40, devices ≈ 22 read well together.
  final double radius;

  /// The orb's colour. The gradient runs white-hot centre → [coreColor] →
  /// transparent halo.
  final Color coreColor;

  /// Halo radius as a multiple of [radius].
  final double haloScale;

  /// An extra stroked ring just outside the core — hubs and other anchors.
  final Color? ringColor;

  /// A second ring in another colour: a bridge node that lives on two
  /// networks at once.
  final Color? secondaryColor;

  /// Short text centred on the orb, e.g. an aggregate device count.
  final String? badge;

  /// Overrides the painter's minimum projected core radius for showing the
  /// badge, like [labelMinPx] does for the label. An anchor whose badge IS
  /// the information (a hub's device count) can set this low so the number
  /// reads even at overview distance.
  final double? badgeMinPx;

  /// Name drawn under the orb. Level-of-detail gated by projected size, and
  /// budgeted per frame, so a 500-node cluster does not become a wall of text.
  final String? label;

  /// Overrides the painter's minimum projected core radius for showing the
  /// label. The few always-visible anchors of a scene can set this low so
  /// their names read even at overview distance; crowds keep the default.
  final double? labelMinPx;
}

/// Depth-fog parameters: nodes fade with camera distance, which is most of
/// what makes a 3D scene read as deep on a flat screen.
@immutable
class FogStyle {
  const FogStyle({
    this.enabled = true,
    this.minAlpha = 0.25,
  });

  final bool enabled;

  /// The fog floor: the farthest node keeps at least this much presence.
  final double minAlpha;
}

/// Alpha multiplier for a node at camera-space [depth] (negative, more
/// negative = farther), given the near/far band the scene occupies.
double fogAlpha(double depth, double near, double far, double minAlpha) {
  if (far >= near) return 1; // degenerate band: no fog
  final t = ((depth - near) / (far - near)).clamp(0.0, 1.0);
  return 1 - (1 - minAlpha) * t;
}
