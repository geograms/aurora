// Generic, app-agnostic conversation model for the ConversationsField
// primitive. A wapp owns all semantics (who a conversation is, how it is
// named, what is pinned, badges, ordering inputs) and drives this store via
// the ui.convo.* protocol; the host only renders what it is told. There is
// no domain knowledge here (no groups, callsigns, bulletins, distance, etc.).

/// One conversation row + its messages. All fields are opaque to the host.
class ConversationItem {
  final String id;
  String title;
  String subtitle; // preview line for the list
  String badge; // free-text trailing chip, e.g. a distance the wapp computed
  String icon; // generic icon name (person, campaign, tag, group, chat…)
  int unread;

  /// Normal messages, in arrival order. Each: {dir, from, text, time}.
  final List<Map<String, dynamic>> messages = [];

  /// Pinned messages, keyed by an opaque key the wapp chooses (it decides
  /// what to pin / dedup). Each value: {from, text, time, dir}.
  final Map<String, Map<String, dynamic>> pinned = {};

  ConversationItem(
    this.id, {
    this.title = '',
    this.subtitle = '',
    this.badge = '',
    this.icon = 'chat',
    this.unread = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'badge': badge,
        'icon': icon,
        'unread': unread,
        'messages': messages,
        'pinned': pinned,
      };

  factory ConversationItem.fromJson(Map<String, dynamic> j) {
    final it = ConversationItem(
      (j['id'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      subtitle: (j['subtitle'] ?? '').toString(),
      badge: (j['badge'] ?? '').toString(),
      icon: (j['icon'] ?? 'chat').toString(),
      unread: (j['unread'] as num?)?.toInt() ?? 0,
    );
    final msgs = j['messages'];
    if (msgs is List) {
      for (final m in msgs) {
        if (m is Map) it.messages.add(m.map((k, v) => MapEntry(k.toString(), v)));
      }
    }
    final pins = j['pinned'];
    if (pins is Map) {
      pins.forEach((k, v) {
        if (v is Map) {
          it.pinned[k.toString()] = v.map((kk, vv) => MapEntry(kk.toString(), vv));
        }
      });
    }
    return it;
  }
}

class ConversationStore {
  final Map<String, ConversationItem> items = {};

  /// Most-recent-first display order.
  final List<String> order = [];

  /// The conversation currently shown (set by the widget) so the store can
  /// auto-manage unread counts. Null when no conversation is open.
  String? openId;

  ConversationItem _ensure(String id) {
    final it = items.putIfAbsent(id, () => ConversationItem(id, title: id));
    if (!order.contains(id)) order.insert(0, id);
    return it;
  }

  void _bump(String id) {
    order.remove(id);
    order.insert(0, id);
  }

  /// Create/update a conversation's list-row metadata. Only the keys present
  /// in [d] are changed.
  void upsert(Map d) {
    final id = (d['id'] ?? '').toString();
    if (id.isEmpty) return;
    final it = _ensure(id);
    if (d.containsKey('title')) it.title = (d['title'] ?? '').toString();
    if (d.containsKey('subtitle')) it.subtitle = (d['subtitle'] ?? '').toString();
    if (d.containsKey('badge')) it.badge = (d['badge'] ?? '').toString();
    if (d.containsKey('icon')) it.icon = (d['icon'] ?? 'chat').toString();
    if (d.containsKey('unread')) {
      it.unread = (d['unread'] as num?)?.toInt() ?? it.unread;
    }
    if (d['bump'] == true) _bump(id);
  }

  void addMessage(Map d) {
    final id = (d['id'] ?? '').toString();
    if (id.isEmpty) return;
    final it = _ensure(id);
    final dir = (d['dir'] ?? 'in').toString();
    it.messages.add({
      'dir': dir,
      'from': (d['from'] ?? '').toString(),
      'text': (d['text'] ?? '').toString(),
      'time': (d['time'] ?? '').toString(),
      'meta': (d['meta'] ?? '').toString(),
      'key': (d['key'] ?? '').toString(),
      if ((d['via'] ?? '').toString().isNotEmpty) 'via': d['via'].toString(),
      if (d['lat'] != null) 'lat': d['lat'],
      if (d['lon'] != null) 'lon': d['lon'],
    });
    if (it.messages.length > 500) {
      it.messages.removeRange(0, it.messages.length - 500);
    }
    if (dir == 'in' && id != openId) it.unread++;
    _bump(id);
  }

  void pin(Map d) {
    final id = (d['id'] ?? '').toString();
    final key = (d['key'] ?? '').toString();
    if (id.isEmpty || key.isEmpty) return;
    final it = _ensure(id);
    // Promote: a message that becomes pinned must leave the normal flow so it
    // is shown once (pinned), not duplicated.
    it.messages.removeWhere((m) => (m['key'] ?? '') == key);
    it.pinned[key] = {
      'dir': (d['dir'] ?? 'in').toString(),
      'from': (d['from'] ?? '').toString(),
      'text': (d['text'] ?? '').toString(),
      'time': (d['time'] ?? '').toString(),
      'meta': (d['meta'] ?? '').toString(),
      if ((d['via'] ?? '').toString().isNotEmpty) 'via': d['via'].toString(),
      if (d['lat'] != null) 'lat': d['lat'],
      if (d['lon'] != null) 'lon': d['lon'],
    };
    if (d['bump'] == true) _bump(id);
  }

  void unpin(Map d) {
    final id = (d['id'] ?? '').toString();
    final key = (d['key'] ?? '').toString();
    items[id]?.pinned.remove(key);
  }

  void clearUnread(String id) {
    items[id]?.unread = 0;
  }

  /// Clear one conversation (id given) or all (id empty/null).
  void clear([String? id]) {
    if (id == null || id.isEmpty) {
      items.clear();
      order.clear();
    } else {
      items.remove(id);
      order.remove(id);
    }
  }

  List<ConversationItem> ordered() =>
      [for (final id in order) if (items.containsKey(id)) items[id]!];

  /// Serialize the whole store for on-disk persistence.
  Map<String, dynamic> toJson() => {
        'order': order,
        'items': {for (final e in items.entries) e.key: e.value.toJson()},
      };

  /// Replace the store's contents from a previously [toJson]-ed map.
  void loadJson(Map<String, dynamic> j) {
    items.clear();
    order.clear();
    final its = j['items'];
    if (its is Map) {
      its.forEach((k, v) {
        if (v is Map) {
          items[k.toString()] =
              ConversationItem.fromJson(v.map((kk, vv) => MapEntry(kk.toString(), vv)));
        }
      });
    }
    final ord = j['order'];
    if (ord is List) {
      for (final id in ord) {
        final s = id.toString();
        if (items.containsKey(s) && !order.contains(s)) order.add(s);
      }
    }
    // Defensive: any item missing from the saved order still gets shown.
    for (final k in items.keys) {
      if (!order.contains(k)) order.add(k);
    }
  }
}
