/*
 * Web stub for RemoteApiService — there is no dart:io HttpServer on web, so
 * the remote-control API is a no-op there. Keeps the public surface identical
 * to remote_api_service_io.dart so callers are platform-agnostic.
 */

import 'package:flutter/widgets.dart';

class RemoteApiService {
  RemoteApiService._();
  static final RemoteApiService instance = RemoteApiService._();

  static const int defaultPort = 3456;

  bool get running => false;
  int get port => defaultPort;

  Future<void> start({int? port, GlobalKey<NavigatorState>? navigatorKey}) async {}
  Future<void> stop() async {}
}
