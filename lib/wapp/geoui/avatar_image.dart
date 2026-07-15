import 'package:flutter/widgets.dart';

/// Memory-bounded image providers for profile pictures and banners.
///
/// Full-resolution avatars/banners were decoded straight to GPU textures. A
/// single profile picture can be 1000×1000+ (multiple MB of texture), and once
/// the curated feed cached 100+ profiles WITH pictures, and a profile page added
/// a full-res banner on top, the graphics memory ran into the tens/hundreds of MB
/// and OOM'd (ANR then kill) on budget phones. Decode small — an avatar renders
/// at ~40–60px and a banner at screen width; nothing needs the source resolution.
///
/// [ResizeImage] bounds the DECODE, so the texture is small regardless of the
/// source image size. Width-only keeps aspect ratio (BoxFit handles the crop).

/// A small square-ish avatar provider (returns null for empty/non-http urls).
ImageProvider? avatarImage(String? url, {int px = 128}) {
  if (url == null || url.isEmpty || !url.startsWith('http')) return null;
  return ResizeImage(NetworkImage(url), width: px, allowUpscaling: false);
}

/// A wider banner provider, bounded to a sane width (banners are often 1500px+).
ImageProvider? bannerImage(String? url, {int width = 720}) {
  if (url == null || url.isEmpty || !url.startsWith('http')) return null;
  return ResizeImage(NetworkImage(url), width: width, allowUpscaling: false);
}
