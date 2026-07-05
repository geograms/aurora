// Re-exports the NOSTR relay layer from the shared `reticulum` package (single
// source of truth; the implementation lives in reticulum-dart). Thin shim so
// aurora's relative imports keep working.
//
// The relay pipeline runs on a background isolate: aurora talks to [NostrClient]
// (a main-isolate proxy), never the hub directly.
export 'package:reticulum/src/services/social/nostr_engine.dart'
    show NostrClient;
export 'package:reticulum/src/services/social/nostr_ws_server.dart'
    show NostrWsServer;
