/*
 * VideoKeyScope — desktop keyboard control for the fullscreen video routes:
 * ESC closes the route, SPACE toggles play/pause. Wraps the route body in
 * an autofocused Focus node so keys work the moment fullscreen opens.
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class VideoKeyScope extends StatelessWidget {
  final Widget child;

  /// SPACE. Null = no pause support on this backend (key ignored).
  final VoidCallback? onTogglePlay;

  const VideoKeyScope({super.key, required this.child, this.onTogglePlay});

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).maybePop();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.mediaPlayPause) {
          if (onTogglePlay != null) {
            onTogglePlay!();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
