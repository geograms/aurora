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

  /// Muted: unread still counts on this row (shown grey) but does NOT propagate
  /// to the Messages-tab / app-icon badge (no app-wide attention).
  bool muted;

  /// Closed: removed from the conversation list view. Re-appears when a new
  /// incoming message arrives.
  bool closed;

  /// Private: a wapp-defined flag the wapp sets per conversation (e.g. APRS's
  /// "Reticulum-only" mode). Purely a display hint here — the host shows a lock
  /// indicator; the wapp owns the routing behaviour.
  bool private;

  /// Host wall-clock (ms) of the last real activity (message / pin / new
  /// unread) — the primary sort key so the most recently active conversations
  /// sit on top. 0 for legacy rows that predate this field; the list sort then
  /// falls back to unread-first, then non-empty, then insertion order.
  int activityTs;

  /// Normal messages, in arrival order. Each: {dir, from, text, time}.
  final List<Map<String, dynamic>> messages = [];

  ConversationItem(
    this.id, {
    this.title = '',
    this.subtitle = '',
    this.badge = '',
    this.icon = 'chat',
    this.unread = 0,
    this.activityTs = 0,
    this.muted = false,
    this.closed = false,
    this.private = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'badge': badge,
        'icon': icon,
        'unread': unread,
        'activityTs': activityTs,
        'muted': muted,
        'closed': closed,
        'private': private,
        'messages': messages,
      };

  factory ConversationItem.fromJson(Map<String, dynamic> j) {
    final it = ConversationItem(
      (j['id'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      subtitle: (j['subtitle'] ?? '').toString(),
      badge: (j['badge'] ?? '').toString(),
      icon: (j['icon'] ?? 'chat').toString(),
      unread: (j['unread'] as num?)?.toInt() ?? 0,
      activityTs: (j['activityTs'] as num?)?.toInt() ?? 0,
      muted: j['muted'] == true,
      closed: j['closed'] == true,
      private: j['private'] == true,
    );
    final msgs = j['messages'];
    if (msgs is List) {
      for (final m in msgs) {
        if (m is Map) it.messages.add(m.map((k, v) => MapEntry(k.toString(), v)));
      }
    }
    return it;
  }
}

class ConversationStore {
  final Map<String, ConversationItem> items = {};

  /// Most-recent-first display order.
  final List<String> order = [];

  /// Reaction tally per message id (mid). The wapp reports each individual
  /// like/unlike (by an opaque actor id) and the host owns the set, so each
  /// actor counts once. Value: `{'likers': List<String>, 'mine': bool}`. The
  /// derived count + my-state are mirrored onto every message carrying that mid
  /// (`likes`/`liked`) so the renderer reads simple fields. Keyed by mid so it
  /// survives message ordering and applies across conversations sharing a mid.
  final Map<String, Map<String, dynamic>> reactions = {};

  /// The conversation currently shown (set by the widget) so the store can
  /// auto-manage unread counts. Null when no conversation is open.
  String? openId;

  ConversationItem _ensure(String id) {
    final it = items.putIfAbsent(id, () => ConversationItem(id, title: id));
    // Append, don't front-insert: a conversation only rises to the top when it
    // has ACTUAL activity (addMessage / bump). Front-inserting here made groups
    // merely listed via upsert (metadata, no message) jump above conversations
    // with recent messages.
    if (!order.contains(id)) order.add(id);
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
    if (d.containsKey('private')) it.private = d['private'] == true;
    if (d.containsKey('unread')) {
      final nv = (d['unread'] as num?)?.toInt() ?? it.unread;
      if (nv > it.unread) it.activityTs = _nowMs(); // new unread = activity
      it.unread = nv;
    }
    if (d['bump'] == true) {
      it.activityTs = _nowMs();
      _bump(id);
    }
  }

  void addMessage(Map d) {
    final id = (d['id'] ?? '').toString();
    if (id.isEmpty) return;
    // A closed conversation is unsubscribed: drop incoming messages so it stays
    // gone (our own sends still go through — they reopen it intentionally).
    final existing = items[id];
    final dir = (d['dir'] ?? 'in').toString();
    if (existing != null && existing.closed && dir == 'in') return;
    final it = _ensure(id);
    it.messages.add({
      'dir': dir,
      'from': (d['from'] ?? '').toString(),
      'text': (d['text'] ?? '').toString(),
      'time': (d['time'] ?? '').toString(),
      'meta': (d['meta'] ?? '').toString(),
      'key': (d['key'] ?? '').toString(),
      if ((d['via'] ?? '').toString().isNotEmpty) 'via': d['via'].toString(),
      // Opaque threading ids set by the wapp (groups only): this message's id
      // and the id it replies to. The host just stores + renders the relation.
      if ((d['mid'] ?? '').toString().isNotEmpty) 'mid': d['mid'].toString(),
      if ((d['parent'] ?? '').toString().isNotEmpty) 'parent': d['parent'].toString(),
      if ((d['auth'] ?? '').toString().isNotEmpty) 'auth': d['auth'].toString(),
      if (d['enc'] == true) 'enc': true,
      if (d['lat'] != null) 'lat': d['lat'],
      if (d['lon'] != null) 'lon': d['lon'],
    });
    if (it.messages.length > 500) {
      it.messages.removeRange(0, it.messages.length - 500);
    }
    // A like may have arrived before this message — seed its tally now.
    final mid = (d['mid'] ?? '').toString();
    if (mid.isNotEmpty && reactions.containsKey(mid)) _applyReaction(mid);
    if (dir == 'in' && id != openId) it.unread++;
    it.activityTs = _nowMs();
    _bump(id);
  }

  /// Mute / unmute a conversation (its unread stops counting app-wide).
  void setMuted(String id, bool v) {
    final it = items[id];
    if (it != null) it.muted = v;
  }

  /// Close a conversation (hide from the list) or reopen it.
  void setClosed(String id, bool v) {
    final it = items[id];
    if (it != null) it.closed = v;
  }

  /// Remove already-shown messages locally (hide / block — never network state).
  /// Two forms: `{id, key}` drops one message from one conversation; `{from}`
  /// drops every message by a sender across all conversations and removes a
  /// direct conversation row with that callsign.
  void remove(Map d) {
    final from = (d['from'] ?? '').toString();
    if (from.isNotEmpty) {
      for (final it in items.values) {
        it.messages.removeWhere((m) => (m['from'] ?? '').toString() == from);
      }
      // A 1:1 conversation with the blocked station goes away entirely; group
      // rows stay (only that sender's messages were stripped).
      if (items.containsKey(from)) {
        items.remove(from);
        order.remove(from);
      }
      return;
    }
    final id = (d['id'] ?? '').toString();
    final key = (d['key'] ?? '').toString();
    if (id.isEmpty) return;
    if (key.isEmpty) {
      // Remove the whole conversation row (e.g. a wapp deleting/leaving a circle).
      items.remove(id);
      order.remove(id);
      return;
    }
    items[id]?.messages.removeWhere((m) => (m['key'] ?? '').toString() == key);
  }

  /// Record a reaction (like) on a message. [d]: `{mid, from, remove?, mine?}`.
  /// The set of `likers` is deduped, so each actor counts once however many
  /// times they vote; `remove` retracts. `mine` marks our own vote.
  void react(Map d) {
    final mid = (d['mid'] ?? '').toString();
    final from = (d['from'] ?? '').toString();
    if (mid.isEmpty || from.isEmpty) return;
    final remove = d['remove'] == true;
    final mine = d['mine'] == true;
    final r = reactions.putIfAbsent(
        mid, () => {'likers': <String>[], 'mine': false});
    final likers = (r['likers'] as List).cast<String>();
    if (remove) {
      likers.remove(from);
      if (mine) r['mine'] = false;
    } else {
      if (!likers.contains(from)) likers.add(from);
      if (mine) r['mine'] = true;
    }
    _applyReaction(mid);
  }

  /// Mirror a mid's tally (`likes` count + `liked` mine-flag) onto every stored
  /// message/pinned entry carrying that mid, across all conversations.
  void _applyReaction(String mid) {
    final r = reactions[mid];
    if (r == null) return;
    final count = (r['likers'] as List).length;
    final mine = r['mine'] == true;
    for (final it in items.values) {
      for (final m in it.messages) {
        if ((m['mid'] ?? '') == mid) {
          m['likes'] = count;
          m['liked'] = mine;
        }
      }
    }
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

  /// Total unread across all conversations — drives the Messages tab/app-icon
  /// badge. Muted (and closed) conversations are excluded so they don't pull
  /// app-wide attention; their count still shows on their own row.
  int get totalUnread => items.values.fold(
      0,
      (sum, it) =>
          sum + ((it.unread > 0 && !it.muted && !it.closed) ? it.unread : 0));

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Conversations for display, most-recently-active first. Primary key is
  /// [ConversationItem.activityTs] (host-stamped on real activity). Legacy rows
  /// (activityTs == 0, saved before that field existed) tie on 0 and fall back
  /// to: unread first, then non-empty, then insertion order — which fixes
  /// already-persisted lists where unread/active rows had sunk below empties.
  List<ConversationItem> ordered() {
    // Closed conversations are hidden from the list (they reappear on a new
    // incoming message).
    final list = [
      for (final id in order)
        if (items.containsKey(id) && !items[id]!.closed) items[id]!
    ];
    final idx = {for (var i = 0; i < order.length; i++) order[i]: i};
    list.sort((a, b) {
      if (a.activityTs != b.activityTs) {
        return b.activityTs.compareTo(a.activityTs); // newer first
      }
      final ua = a.unread > 0 ? 1 : 0, ub = b.unread > 0 ? 1 : 0;
      if (ua != ub) return ub.compareTo(ua); // unread before read
      final ma = a.messages.isNotEmpty ? 1 : 0, mb = b.messages.isNotEmpty ? 1 : 0;
      if (ma != mb) return mb.compareTo(ma); // non-empty before empty
      return (idx[a.id] ?? 0).compareTo(idx[b.id] ?? 0); // stable
    });
    return list;
  }

  /// Serialize the whole store for on-disk persistence.
  Map<String, dynamic> toJson() => {
        'order': order,
        'items': {for (final e in items.entries) e.key: e.value.toJson()},
        'reactions': reactions,
      };

  /// Replace the store's contents from a previously [toJson]-ed map.
  void loadJson(Map<String, dynamic> j) {
    items.clear();
    order.clear();
    reactions.clear();
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
    // Restore reaction tallies and re-mirror them onto the loaded messages.
    final rx = j['reactions'];
    if (rx is Map) {
      rx.forEach((k, v) {
        if (v is Map) {
          final likers = <String>[
            for (final e in (v['likers'] is List ? v['likers'] as List : const []))
              e.toString()
          ];
          reactions[k.toString()] = {'likers': likers, 'mine': v['mine'] == true};
        }
      });
      for (final mid in reactions.keys) {
        _applyReaction(mid);
      }
    }
  }
}
