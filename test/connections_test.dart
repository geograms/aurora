// Tests for the connections subsystem: the capability model, the registry,
// and that relocating the transport HAL ABI left it byte-for-byte intact.

import 'package:flutter_test/flutter_test.dart';

import 'package:aurora/connections/connections.dart';
import 'package:aurora/connections/hal/connection_functionalities.dart';
import 'package:aurora/wapp/functionality_registry.dart';

void main() {
  group('ConnectionCapabilities', () {
    test('toJson round-trips the declared characteristics', () {
      const caps = ConnectionCapabilities(
        maxBandwidthBitsPerSecond: 27000,
        typicalLatency: Duration(seconds: 2),
        deliveryMode: DeliveryMode.storeAndForward,
        reach: ConnectionReach.mesh,
        reliable: false,
        maxPayloadBytes: 256,
        isMetered: true,
      );
      final json = caps.toJson();
      expect(json['maxBandwidthBitsPerSecond'], 27000);
      expect(json['typicalLatencyMs'], 2000);
      expect(json['deliveryMode'], 'storeAndForward');
      expect(json['reach'], 'mesh');
      expect(json['reliable'], false);
      expect(json['maxPayloadBytes'], 256);
      expect(json['isMetered'], true);
    });

    test('null bandwidth/payload are omitted', () {
      const caps = ConnectionCapabilities(
        deliveryMode: DeliveryMode.immediate,
        reach: ConnectionReach.internet,
      );
      final json = caps.toJson();
      expect(json.containsKey('maxBandwidthBitsPerSecond'), false);
      expect(json.containsKey('maxPayloadBytes'), false);
      expect(json['reliable'], true); // default
    });
  });

  group('ConnectionRegistry', () {
    setUp(() => ConnectionRegistry.instance.clear());
    tearDown(() => ConnectionRegistry.instance.clear());

    test('registerBuiltinConnections wires the expected transports', () {
      registerBuiltinConnections();
      final kinds = ConnectionRegistry.instance.all.map((c) => c.kind).toSet();
      expect(
        kinds,
        containsAll(<ConnectionKind>[
          ConnectionKind.internet,
          ConnectionKind.lan,
          ConnectionKind.bluetooth,
          ConnectionKind.lora,
          ConnectionKind.usb,
        ]),
      );
    });

    test('only internet is available; stubs report unavailable', () {
      registerBuiltinConnections();
      final available = ConnectionRegistry.instance.available;
      expect(available.map((c) => c.kind), [ConnectionKind.internet]);
    });

    test('byKind and byId look transports up', () {
      registerBuiltinConnections();
      expect(ConnectionRegistry.instance.byKind(ConnectionKind.lora), hasLength(1));
      expect(ConnectionRegistry.instance.byId('internet'), isNotNull);
      expect(ConnectionRegistry.instance.byId('nope'), isNull);
    });

    test('firstWhereCapable only returns available transports', () {
      registerBuiltinConnections();
      // LoRa is store-and-forward but unavailable → must not match.
      final sf = ConnectionRegistry.instance.firstWhereCapable(
          (c) => c.deliveryMode == DeliveryMode.storeAndForward);
      expect(sf, isNull);
      // Internet is immediate and available → matches.
      final immediate = ConnectionRegistry.instance.firstWhereCapable(
          (c) => c.deliveryMode == DeliveryMode.immediate);
      expect(immediate?.kind, ConnectionKind.internet);
    });
  });

  group('Transport HAL ABI relocation', () {
    test('connectionFunctionalities still defines hal.http/lora/ble', () {
      expect(connectionFunctionalities.keys,
          containsAll(<String>['hal.http', 'hal.lora', 'hal.ble']));
    });

    test('registry core functionalities still advertise the transport HAL', () {
      // The defs moved into lib/connections/ but must still be spread back
      // into the core functionalities the registry exposes to WASM modules.
      final core = FunctionalityRegistry.coreFunctionalities;
      expect(core.containsKey('hal.http'), true);
      expect(core.containsKey('hal.lora'), true);
      expect(core.containsKey('hal.ble'), true);
      expect(identical(core['hal.http'], connectionFunctionalities['hal.http']),
          true);
    });

    test('hal.http endpoint signatures are unchanged', () {
      final http = connectionFunctionalities['hal.http']!;
      expect(http.endpoints.map((e) => e.name), [
        'hal_http_request',
        'hal_http_poll',
        'hal_http_read_response',
        'hal_http_status',
        'hal_http_free',
      ]);
      final request = http.endpoints.first;
      expect(request.params.map((p) => p.name), ['method', 'url', 'body']);
      expect(request.returns.type, 'int');
    });
  });
}
