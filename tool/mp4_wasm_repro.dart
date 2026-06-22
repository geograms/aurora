// Reproduce the mp4player decode under wasm_run (the SAME runtime the app
// uses) on the Linux desktop, to debug the on-device SIGSEGV without APK
// cycles. Run: dart run tool/mp4_wasm_repro.dart <app.wasm> <file.mp4>
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wasm_run/wasm_run.dart';

late WasmMemory mem;
Uint8List view() => mem.view;
String readStr(int p, int n) => String.fromCharCodes(view().buffer.asUint8List(p, n));

void main(List<String> args) async {
  final wasmPath = args.isNotEmpty ? args[0] : 'assets/wapps/_unused';
  final mp4Path = args.length > 1 ? args[1] : '/tmp/mp4probe/aR0FwpUubxz3q4V94asBZajw83wWv0BvJ7JCQIIIEtY.mp4';
  final wasmBytes = await File(wasmPath).readAsBytes();
  final fileBytes = await File(mp4Path).readAsBytes();

  final inbox = <String>[];
  inbox.add(jsonEncode({'type': 'file.open', 'path': mp4Path, 'mode': 'view'}));
  final openFiles = <int, ({Uint8List buf, int pos})>{};
  var nextFd = 3;
  var clock = 0;
  var frames = 0;
  var audioBytes = 0, audioRate = 0, audioCh = 0, audioFmt = -1, audioChunks = 0;

  final module = await compileWasmModule(wasmBytes);
  final builder = module.builder();

  WasmFunction vfn(Function f, List<ValueTy> p) =>
      WasmFunction.voidReturn(f, params: p);
  WasmFunction i32fn(Function f, List<ValueTy> p) =>
      WasmFunction(f, params: p, results: [ValueTy.i32]);

  final imports = <WasmImport>[
    WasmImport('hal', 'log', vfn((int lvl, int p, int n) {
      print('LOG: ${readStr(p, n)}');
    }, [ValueTy.i32, ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'time_ms', WasmFunction(() => clock,
        params: const [], results: [ValueTy.i64])),
    WasmImport('hal', 'msg_available',
        i32fn(() => inbox.isEmpty ? 0 : 1, const [])),
    WasmImport('hal', 'msg_recv', i32fn((int p, int cap) {
      if (inbox.isEmpty) return 0;
      final s = Uint8List.fromList(utf8.encode(inbox.removeAt(0)));
      final k = s.length < cap ? s.length : cap;
      final v = view();
      for (var i = 0; i < k; i++) v[p + i] = s[i];
      return k;
    }, [ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'msg_send', vfn((int p, int n) {
      print('MSG->host: ${readStr(p, n)}');
    }, [ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'file_open', i32fn((int p, int n, int mode) {
      final path = readStr(p, n);
      try {
        final b = File(path).readAsBytesSync();
        final fd = nextFd++;
        openFiles[fd] = (buf: b, pos: 0);
        return fd;
      } catch (_) {
        return -1;
      }
    }, [ValueTy.i32, ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'file_read', i32fn((int fd, int p, int cap) {
      final f = openFiles[fd];
      if (f == null) return -1;
      final remain = f.buf.length - f.pos;
      if (remain <= 0) return 0;
      final k = remain < cap ? remain : cap;
      final v = view();
      for (var i = 0; i < k; i++) v[p + i] = f.buf[f.pos + i];
      openFiles[fd] = (buf: f.buf, pos: f.pos + k);
      return k;
    }, [ValueTy.i32, ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'file_close', vfn((int fd) {
      openFiles.remove(fd);
    }, [ValueTy.i32])),
    WasmImport('hal', 'video_config', vfn((int w, int h, int f) {
      print('video_config ${w}x$h fmt$f');
    }, [ValueTy.i32, ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'video_frame',
        vfn((int p, int len, int w, int h, int fmt, int pts) {
      // Read the bytes EXACTLY like the engine's halVideoFrame does, to
      // reproduce any RangeError after wasm memory growth.
      final copy = Uint8List.fromList(view().buffer.asUint8List(p, len));
      frames++;
      if (frames <= 3 || frames % 20 == 0) {
        print('frame $frames: ${w}x$h len=$len pts=${pts}ms bytes=${copy.length} memMB=${(view().lengthInBytes / 1048576).toStringAsFixed(1)}');
      }
    }, [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'audio_pcm',
        vfn((int ptr, int len, int rate, int ch, int fmt, int pts) {
      audioBytes += len;
      audioRate = rate;
      audioCh = ch;
      audioFmt = fmt;
      audioChunks++;
      if (audioChunks <= 3 || audioChunks % 50 == 0) {
        print('audio chunk $audioChunks: ${len}B rate=$rate ch=$ch fmt=$fmt pts=${pts}ms');
      }
    }, [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'video_end', vfn(() => print('video_end'), const [])),
    // music-mode HAL (kv + dir listing): harmless stubs for the harness.
    WasmImport('hal', 'kv_get',
        i32fn((int kp, int kn, int vp, int vc) => 0,
            [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'kv_set',
        i32fn((int kp, int kn, int vp, int vn) => 0,
            [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'fs_listdir',
        i32fn((int pp, int pn, int op, int oc) => 0,
            [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'fs_home',
        i32fn((int op, int oc) => 0, [ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'http_stream_open',
        i32fn((int up, int ul) => -1, [ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'http_stream_read',
        i32fn((int h, int bp, int bl) => -1, [ValueTy.i32, ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'http_stream_meta',
        i32fn((int h, int bp, int bl) => 0, [ValueTy.i32, ValueTy.i32, ValueTy.i32])),
    WasmImport('hal', 'http_stream_close',
        vfn((int h) {}, [ValueTy.i32])),
    // wasi
    WasmImport('wasi_snapshot_preview1', 'clock_time_get',
        i32fn((int a, int b, int c) => 0, [ValueTy.i32, ValueTy.i64, ValueTy.i32])),
    WasmImport('wasi_snapshot_preview1', 'proc_exit', vfn((int c) {}, [ValueTy.i32])),
    WasmImport('wasi_snapshot_preview1', 'fd_close', i32fn((int a) => 0, [ValueTy.i32])),
    WasmImport('wasi_snapshot_preview1', 'fd_fdstat_get',
        i32fn((int a, int b) => 0, [ValueTy.i32, ValueTy.i32])),
    WasmImport('wasi_snapshot_preview1', 'fd_read',
        i32fn((int a, int b, int c, int d) => 0, [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32])),
    WasmImport('wasi_snapshot_preview1', 'fd_write',
        i32fn((int a, int b, int c, int d) => 0, [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32])),
    WasmImport('wasi_snapshot_preview1', 'fd_seek',
        i32fn((int a, int b, int c, int d) => 29, [ValueTy.i32, ValueTy.i64, ValueTy.i32, ValueTy.i32])),
    WasmImport('wasi_snapshot_preview1', 'fd_prestat_get',
        i32fn((int a, int b) => 8, [ValueTy.i32, ValueTy.i32])),
    WasmImport('wasi_snapshot_preview1', 'fd_prestat_dir_name',
        i32fn((int a, int b, int c) => 8, [ValueTy.i32, ValueTy.i32, ValueTy.i32])),
    WasmImport('wasi_snapshot_preview1', 'poll_oneoff',
        i32fn((int a, int b, int c, int d) => 0, [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32])),
  ];
  for (final imp in imports) {
    try {
      builder.addImports([imp]);
    } catch (e) {
      print('skip import ${imp.name}: $e');
    }
  }
  final instance = await builder.build();
  mem = instance.exports['memory'] as WasmMemory;

  void call(String fn) => (instance.getFunction(fn))?.call(const []);

  print('--- init ---');
  call('module_init');
  print('--- handle_event (file.open) ---');
  call('module_handle_event');
  print('--- ticking ---');
  for (var i = 0; i < 2000 && frames < 80; i++) {
    clock += 16;
    call('module_tick');
  }
  final audioFrames = (audioCh > 0 && audioFmt == 0)
      ? audioBytes ~/ (2 * audioCh)
      : 0;
  final audioSecs = audioRate > 0 ? audioFrames / audioRate : 0;
  print('RESULT: frames=$frames audioChunks=$audioChunks audioBytes=$audioBytes '
      'rate=$audioRate ch=$audioCh fmt=$audioFmt ~${audioSecs.toStringAsFixed(1)}s');
}
