// ChatPalette — the shared colour palette for the GeoUI messaging widgets
// (ChatViewField bubbles/background, ConversationsField list, and the wapp
// page chrome). The values are sampled from the X (Twitter) dark-theme DM
// view, so the chat surfaces read as X. This is generic styling — no app
// (APRS, Circles, …) knowledge lives here; every chat-based wapp shares it.

import 'package:flutter/material.dart';

abstract final class ChatPalette {
  /// Window chrome: app bar, tab bar, conversation list, room header,
  /// composer bar. Slightly lifted off pure black so bars stay visible.
  static const Color windowBg = Color(0xFF0B0B0B);

  /// Chat history background, behind the message bubbles. Pure AMOLED black.
  static const Color chatBg = Color(0xFF000000);

  /// Incoming (received) message bubble. Dark neutral grey.
  static const Color inBubble = Color(0xFF141618);

  /// Outgoing (sent) message bubble + selected conversation row.
  /// X's blue.
  static const Color outBubble = Color(0xFF1D9BF0);

  /// Primary text on bubbles and rows.
  static const Color text = Color(0xFFFFFFFF);

  /// Secondary text: timestamps, subtitles, unselected tabs.
  static const Color secondary = Color(0xFF71767B);

  /// Accent: links, sender names, tab indicator, unread badges, compose
  /// icons. X uses the same blue as the outgoing bubble.
  static const Color accent = Color(0xFF1D9BF0);
}
