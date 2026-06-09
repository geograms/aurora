/*
 * Shared helper: turn a raw response byte stream into a stream of UTF-8
 * lines. Both SSE (`data: {...}` lines) and Ollama's NDJSON are line-based,
 * so every provider decodes the same way.
 */

import 'dart:convert';

Stream<String> lineStream(Stream<List<int>> bytes) =>
    bytes.transform(utf8.decoder).transform(const LineSplitter());
