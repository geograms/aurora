// ChatPalette — the shared colour palette for the GeoUI messaging widgets
// (ChatViewField bubbles/background, ConversationsField list, and the wapp
// page chrome). The values mirror the Telegram Desktop "Night" theme so the
// chat surfaces read as Telegram. This is generic styling — no app (APRS,
// Circles, …) knowledge lives here; every chat-based wapp shares it.

import 'package:flutter/material.dart';

abstract final class ChatPalette {
  /// Window chrome: app bar, tab bar, conversation list, room header,
  /// composer bar. Slightly lifted off pure black so bars stay visible.
  static const Color windowBg = Color(0xFF0B0B0B);

  /// Chat history background, behind the message bubbles. Pure AMOLED black.
  static const Color chatBg = Color(0xFF000000);

  /// Incoming (received) message bubble. Dark neutral grey.
  static const Color inBubble = Color(0xFF1C1C1E);

  /// Outgoing (sent) message bubble + selected conversation row.
  /// Telegram `msgOutBg` / active dialog.
  static const Color outBubble = Color(0xFF2B5278);

  /// Primary text on bubbles and rows.
  static const Color text = Color(0xFFFFFFFF);

  /// Secondary text: timestamps, subtitles, unselected tabs.
  static const Color secondary = Color(0xFF8A8A8E);

  /// Accent: links, sender names, tab indicator, unread badges, compose
  /// icons. Telegram `windowActiveTextFg`.
  static const Color accent = Color(0xFF50A8EB);
}
