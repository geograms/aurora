/*
 * The one HTTP client for the whole host.
 *
 * Before this existed, host HTTP was duplicated three ways: package:http in
 * the installer and wapp_page, and raw dart:io HttpClient in the CLI. They
 * all funnel through here now. package:http works on desktop, web and the
 * Dart CLI, so this single implementation covers every entry point.
 *
 * A GET + POST that return bytes + status, plus a streaming POST for
 * server-sent / chunked responses (used by the AI providers in lib/ai/).
 */

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Result of an HTTP request.
class HttpResult {
  final int statusCode;
  final Uint8List bodyBytes;

  HttpResult(this.statusCode, this.bodyBytes);

  /// True for 2xx.
  bool get isOk => statusCode >= 200 && statusCode < 300;

  /// Body decoded as UTF-8 (lossy on invalid bytes).
  String get bodyString => utf8.decode(bodyBytes, allowMalformed: true);
}

/// Result of a streaming request: the status plus the raw byte stream of the
/// response body. The caller decodes/parses it (SSE, NDJSON, …). The owning
/// [http.Client] is closed automatically once the stream is done or errors.
class HttpStreamResult {
  final int statusCode;
  final Stream<List<int>> stream;

  HttpStreamResult(this.statusCode, this.stream);

  bool get isOk => statusCode >= 200 && statusCode < 300;
}

/// Host-side HTTP over the internet transport. Stateless; construct one or
/// reuse [HttpTransport.shared].
class HttpTransport {
  const HttpTransport();

  /// Shared default instance.
  static const HttpTransport shared = HttpTransport();

  /// GET [url]. Applies [timeout] when given (mirrors the previous
  /// per-call-site deadlines). Throws on network failure or timeout — the
  /// caller decides how to handle it.
  Future<HttpResult> get(
    Uri url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    var future = http.get(url, headers: headers);
    if (timeout != null) future = future.timeout(timeout);
    final res = await future;
    return HttpResult(res.statusCode, res.bodyBytes);
  }

  /// POST [url] with an optional string [body]. Non-streaming — awaits the
  /// whole response. Throws on network failure / timeout.
  Future<HttpResult> post(
    Uri url, {
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  }) async {
    var future = http.post(url, headers: headers, body: body);
    if (timeout != null) future = future.timeout(timeout);
    final res = await future;
    return HttpResult(res.statusCode, res.bodyBytes);
  }

  /// POST [url] and return the response body as a byte stream, for endpoints
  /// that stream (SSE / chunked NDJSON — e.g. LLM chat completions). The
  /// client is closed when the stream completes or errors. Throws on the
  /// initial connect failure / timeout.
  Future<HttpStreamResult> postStream(
    Uri url, {
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  }) async {
    final client = http.Client();
    final request = http.Request('POST', url);
    if (headers != null) request.headers.addAll(headers);
    if (body != null) request.body = body;

    var send = client.send(request);
    if (timeout != null) send = send.timeout(timeout);
    try {
      final res = await send;
      // Close the client once the caller finishes draining the stream.
      final stream = res.stream.transform<List<int>>(
        StreamTransformer.fromHandlers(
          handleDone: (sink) {
            sink.close();
            client.close();
          },
          handleError: (e, st, sink) {
            sink.addError(e, st);
            client.close();
          },
        ),
      );
      return HttpStreamResult(res.statusCode, stream);
    } catch (e) {
      client.close();
      rethrow;
    }
  }
}
