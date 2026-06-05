/*
 * Remote-control HTTP API for the Aurora app.
 *
 * Opens a small JSON HTTP server (default port 3456 — the standard geogram
 * device-API port) so the app can be driven and inspected remotely:
 *
 *   GET  /api/status        → app + active-profile info, installed wapps
 *   GET  /api/log[?n=200]   → recent log lines (see LogService)
 *   GET  /api/wapps         → installed wapps [{id,name,folder,kind}]
 *   POST /api/launch        → body {"wapp":"<id|folder|name>"} opens that wapp
 *
 * Modelled on geogram's LogApiService (lib/services/log_api_service.dart):
 * same /api/ path shape, CORS-open, gated behind a setting. Conditional
 * export keeps dart:io out of the web build (the stub is a no-op there).
 */

export 'remote_api_service_stub.dart'
    if (dart.library.io) 'remote_api_service_io.dart';
