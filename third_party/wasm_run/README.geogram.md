# Why this package is vendored

Fork of `wasm_run 0.1.0+2` (pub.dev, published 2023 — still the newest release,
so there is no upstream fix to wait for). Everything is upstream except two
edits in `lib/src/wasm_bindings/_wasm_interop_native.dart`, both marked
`PATCHED (geogram)`.

## 1. The host-callback ABI was wrong on 32-bit ARM

Rust declares the wasm→host trampoline as

```rust
// native/src/api_wasmi.rs:634 (also api.rs / api_wasmtime.rs:1014)
type WasmFunction =
    unsafe extern "C" fn(function_id: u32, args: *mut DartAbi) -> *mut wire_list_wasm_val;
```

but the Dart typedef declared the first parameter as `ffi.Int64`.

* **AAPCS64** (arm64 phones, x86_64 desktop): every integral argument gets its
  own register, so Dart read `w0`/`x1` and Rust had written `w0`/`x1`. Correct
  by luck.
* **AAPCS32** (armeabi-v7a): a 64-bit argument must occupy an even-aligned
  *core register pair*. Dart's trampoline therefore expected the id in `r0:r1`
  and the args pointer in **r2**, while Rust passed that pointer in **r1**.

Dart then dereferenced a stale register as a `Dart_CObject*`:

```
_globalWasmFunction error: Exception: Can't read invalid data type -509558769
Fatal signal 11 (SIGSEGV), fault addr 0x0
```

`-509558769` is `0xE1A0C00F`, the ARM32 encoding of `mov ip, pc` — the first
word of a PLT veneer. The "type" field it read was executable code, which is
what proves this was a wrong-register read and not a struct-layout problem
(`Dart_CObject`'s layout is pointer-size correct on both ABIs).

Every wasm→host call was broken on 32-bit ARM, whatever the function's
signature. Observed on a Lenovo TB300FU (Android 13, `abilist64` empty): the
app crash-looped seconds after each launch, because a background wapp engine
starts on boot and Chat calls `hal_time_epoch` several times a second.

The fix is `ffi.Uint32`, matching Rust. 64-bit targets are unaffected.

## 2. A failing host function segfaulted the process

The callback caught, printed and **rethrew**. An exception escaping an FFI
callback yields the default return — `nullptr` — and Rust immediately does
`box_from_leak_ptr(result)` (`bridge_generated.rs:4085`), dereferencing address
0. So any host-side error was a native crash on *every* ABI, uncatchable from
Dart. It now returns an empty `wire_list_wasm_val`, which Rust sees as an empty
`Vec<WasmVal>` and reports as an ordinary wasm trap.

## Upgrading

If a newer `wasm_run` ever ships, diff these two hunks against it; if upstream
has fixed both, drop the `dependency_overrides` entry in `pubspec.yaml` and
delete this directory. `example/` and `test/` were removed to keep the tree
small; `native/` is kept for reference only — the prebuilt
`libwasm_run_dart.so` comes from `wasm_run_flutter` and is NOT rebuilt here
(these patches are Dart-side only).
