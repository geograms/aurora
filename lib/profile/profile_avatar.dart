/*
 * ProfileAvatar — circular avatar for an [IwiProfile].
 *
 * Renders the profile's uploaded image (read from `devices/<id>/<avatar>`)
 * when set, otherwise a coloured circle with the profile's initials. The
 * colour is the profile's chosen [IwiProfile.color] (see [kProfileColors]) or
 * a deterministic fallback derived from the callsign, so every identity gets a
 * stable, distinct colour even without customization.
 *
 * Rebuilds whenever ProfileService.revision changes (e.g. after the user
 * edits their avatar/colour in the profile editor).
 */

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'iwi_profile.dart';
import 'profile_service.dart';

/// Map a [kProfileColors] name to a concrete colour.
Color profileColor(IwiProfile p) {
  switch (p.color) {
    case 'red':
      return const Color(0xFFE53935);
    case 'blue':
      return const Color(0xFF1E88E5);
    case 'green':
      return const Color(0xFF43A047);
    case 'yellow':
      return const Color(0xFFF9A825);
    case 'purple':
      return const Color(0xFF8E24AA);
    case 'orange':
      return const Color(0xFFFB8C00);
    case 'pink':
      return const Color(0xFFD81B60);
    case 'cyan':
      return const Color(0xFF00ACC1);
  }
  // Deterministic fallback from the callsign so it's stable + distinct.
  final h = p.callsign.codeUnits.fold<int>(0, (a, c) => (a * 31 + c) & 0x7fffffff);
  const palette = [
    Color(0xFFE53935), Color(0xFF1E88E5), Color(0xFF43A047),
    Color(0xFFF9A825), Color(0xFF8E24AA), Color(0xFFFB8C00),
    Color(0xFFD81B60), Color(0xFF00ACC1),
  ];
  return palette[h % palette.length];
}

/// Two-character initials for the circle fallback.
String profileInitials(IwiProfile p) {
  final src = (p.nickname.isNotEmpty ? p.nickname : p.callsign).trim();
  if (src.isEmpty) return '?';
  final letters = src.replaceAll(RegExp(r'\s+'), '');
  return letters.substring(0, letters.length >= 2 ? 2 : 1).toUpperCase();
}

class ProfileAvatar extends StatelessWidget {
  final IwiProfile profile;
  final double size;

  const ProfileAvatar({super.key, required this.profile, this.size = 36});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ProfileService.instance.revision,
      builder: (context, _, __) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final bg = profileColor(profile);
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(
        profileInitials(profile),
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.38,
        ),
      ),
    );

    if (profile.avatar.isEmpty) return fallback;

    return FutureBuilder<Uint8List?>(
      future: ProfileService.instance
          .storageForProfile(profile.id)
          .readBytes(profile.avatar),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) return fallback;
        return ClipOval(
          child: Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => fallback,
          ),
        );
      },
    );
  }
}
