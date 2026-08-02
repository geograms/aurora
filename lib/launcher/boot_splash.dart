import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// First Flutter frame during startup: the full Geogram triad (star +
/// mountains + waves) over the wordmark. Android 12+ owns the launch window
/// and circle-masks its icon; this frame follows it on the same background
/// colour so the two read as one continuous launch. Shown by main() before
/// the boot orchestrator runs; replaced by the second runApp(IwiApp) once
/// startup work completes. No animation.
class BootSplashApp extends StatelessWidget {
  const BootSplashApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _BootSplashPage(),
    );
  }
}

class _BootSplashPage extends StatelessWidget {
  const _BootSplashPage();

  static const _bgLight = Color(0xFFF4F1EA); // sand
  static const _bgDark = Color(0xFF232A2E); // dark
  static const _inkLight = Color(0xFF2A2620); // ink
  static const _inkDark = Color(0xFFE8E3D6); // bone

  @override
  Widget build(BuildContext context) {
    final dark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final ink = dark ? _inkDark : _inkLight;
    // Fill most of a portrait phone's width; capped so desktop/tablet
    // windows don't get a wall-sized glyph.
    final screenWidth = MediaQuery.sizeOf(context).width;
    final triadWidth = (screenWidth * 0.78).clamp(212.0, 460.0);
    final wordmarkSize = (triadWidth / 13.0).clamp(16.0, 30.0);
    return ColoredBox(
      color: dark ? _bgDark : _bgLight,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              dark
                  ? 'assets/splash/geogram-triad-dark.svg'
                  : 'assets/splash/geogram-triad.svg',
              width: triadWidth,
            ),
            SizedBox(height: triadWidth * 0.16),
            Text(
              'GEOGRAM',
              style: TextStyle(
                color: ink,
                fontSize: wordmarkSize,
                fontWeight: FontWeight.w500,
                letterSpacing: wordmarkSize * 0.22,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
