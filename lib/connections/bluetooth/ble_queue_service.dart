/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'ble_parcel.dart';

// Adapted from geogram: housekeeping runs on a plain periodic Timer (Aurora has
// no MonitoredPeriodicTimer) and logging goes through debugPrint.
void _log(String m) => debugPrint(m);

/// Callback for sending a parcel over BLE
typedef SendParcelCallback = Future<void> Function(
  String deviceId,
  Uint8List data,
);

/// Callback for receiving data from BLE
typedef ReceiveCallback = void Function(String deviceId, Uint8List data);

/// Retention and timeout constants for parcel protocol
class BLERetentionConstants {
  /// How long to keep sent messages for potential retransmission requests (2 minutes)
  static const Duration sentMessageRetention = Duration(minutes: 2);

  /// How long to wait for missing parcels before requesting them (5 seconds)
  static const Duration missingParcelRequestDelay = Duration(seconds: 5);

  /// How long to keep incomplete incoming messages before discarding (60 seconds)
  static const Duration incompleteMessageTimeout = Duration(seconds: 60);

  /// Interval for the housekeeping timer (10 seconds)
  static const Duration housekeepingInterval = Duration(seconds: 10);
}

/// Service for managing BLE transmission queue with reliable delivery
class BLEQueueService {
  static final BLEQueueService _instance = BLEQueueService._internal();
  factory BLEQueueService() => _instance;
  BLEQueueService._internal();

  /// Outgoing message queue per device
  final Map<String, Queue<BLEOutgoingMessage>> _outgoingQueues = {};

  /// Incoming message buffers per device
  final Map<String, Map<String, BLEIncomingMessage>> _incomingBuffers = {};

  /// Sent messages retained for retransmission (msgId -> SentMessageRecord)
  final Map<String, _SentMessageRecord> _sentMessages = {};

  /// Currently sending flag per device
  final Map<String, bool> _isSending = {};

  /// Pending receipt completers per message
  final Map<String, Completer<BLEReceipt>> _pendingReceipts = {};

  /// Callback to actually send data over BLE
  SendParcelCallback? _sendCallback;

  /// Stream controller for completed incoming messages
  final _incomingController = StreamController<BLECompletedMessage>.broadcast();

  /// Housekeeping timer for cleanup and missing parcel requests
  Timer? _housekeepingTimer;

  /// Stream of completed incoming messages
  Stream<BLECompletedMessage> get incomingMessages => _incomingController.stream;

  /// Set the callback used to send data over BLE
  void setSendCallback(SendParcelCallback callback) {
    _sendCallback = callback;
    // Start housekeeping when callback is set
    _startHousekeeping();
  }

  /// Start the housekeeping timer
  void _startHousekeeping() {
    _housekeepingTimer?.cancel();
    _housekeepingTimer = Timer.periodic(
      BLERetentionConstants.housekeepingInterval,
      (_) => _performHousekeeping(),
    );
  }

  /// Perform periodic housekeeping tasks
  void _performHousekeeping() {
    _cleanupSentMessages();
    _requestMissingParcelsForStalled();
    _cleanupStaleIncomingMessages();
  }

  /// Clean up sent messages that have exceeded retention period
  void _cleanupSentMessages() {
    final now = DateTime.now();
    final expiredIds = <String>[];

    for (final entry in _sentMessages.entries) {
      if (now.difference(entry.value.sentAt) > BLERetentionConstants.sentMessageRetention) {
        expiredIds.add(entry.key);
      }
    }

    for (final msgId in expiredIds) {
      _sentMessages.remove(msgId);
      _log('BLEQueue: Expired sent message $msgId from retention cache');
    }
  }

  /// Request missing parcels for stalled incoming messages
  void _requestMissingParcelsForStalled() {
    final now = DateTime.now();

    for (final deviceEntry in _incomingBuffers.entries) {
      final deviceId = deviceEntry.key;
      for (final msgEntry in deviceEntry.value.entries) {
        final incoming = msgEntry.value;

        // Check if message has been waiting long enough without new parcels
        if (!incoming.isComplete &&
            now.difference(incoming.lastParcelReceivedAt) > BLERetentionConstants.missingParcelRequestDelay) {
          // Request missing parcels
          final missing = incoming.missingParcels;
          if (missing.isNotEmpty) {
            _log('BLEQueue: Requesting ${missing.length} missing parcels for ${incoming.msgId}');
            _sendReceipt(deviceId, BLEReceipt.missing(incoming.msgId, missing));
            // Update last request time to avoid spamming
            incoming.markParcelRequestSent();
          }
        }
      }
    }
  }

  /// Clean up stale incoming messages that have timed out
  void _cleanupStaleIncomingMessages() {
    for (final deviceBuffers in _incomingBuffers.values) {
      deviceBuffers.removeWhere((msgId, incoming) {
        if (incoming.isStale(timeout: BLERetentionConstants.incompleteMessageTimeout)) {
          _log('BLEQueue: Removing stale incomplete message $msgId '
              '(received ${incoming.receivedCount}/${incoming.totalParcels} parcels)');
          return true;
        }
        return false;
      });
    }
  }

  /// Enqueue a message for transmission
  Future<bool> enqueue(BLEOutgoingMessage message) async {
    final deviceId = message.targetDeviceId;

    // Initialize queue if needed
    _outgoingQueues.putIfAbsent(deviceId, () => Queue());
    _outgoingQueues[deviceId]!.add(message);

    _log('BLEQueue: Enqueued message ${message.msgId} '
        'for $deviceId (${message.payload.length} bytes)');

    // Start processing if not already sending
    if (_isSending[deviceId] != true) {
      _processQueue(deviceId);
    }

    return true;
  }

  /// Process the outgoing queue for a device
  Future<void> _processQueue(String deviceId) async {
    if (_isSending[deviceId] == true) return;
    if (_sendCallback == null) {
      _log('BLEQueue: No send callback configured');
      return;
    }

    final queue = _outgoingQueues[deviceId];
    if (queue == null || queue.isEmpty) return;

    _isSending[deviceId] = true;

    try {
      while (queue.isNotEmpty) {
        final message = queue.first;

        final success = await _sendMessage(deviceId, message);

        if (success) {
          queue.removeFirst();
          _log('BLEQueue: Message ${message.msgId} sent successfully');
        } else {
          message.retryCount++;
          if (message.retryCount >= BLEParcelConstants.maxRetries) {
            queue.removeFirst();
            _log('BLEQueue: Message ${message.msgId} failed after '
                '${message.retryCount} retries, dropping');
          } else {
            _log('BLEQueue: Message ${message.msgId} failed, '
                'retry ${message.retryCount}/${BLEParcelConstants.maxRetries}');
            // Wait before retry
            await Future.delayed(const Duration(milliseconds: 1000));
          }
        }
      }
    } finally {
      _isSending[deviceId] = false;
    }
  }

  /// Send a single message with parcel protocol
  Future<bool> _sendMessage(String deviceId, BLEOutgoingMessage message) async {
    final parcels = message.toParcels();
    _log('BLEQueue: Sending message ${message.msgId} '
        'in ${parcels.length} parcels');

    // Retain the parcels for potential retransmission requests
    _sentMessages[message.msgId] = _SentMessageRecord(
      msgId: message.msgId,
      targetDeviceId: deviceId,
      parcels: parcels,
      sentAt: DateTime.now(),
    );

    // Track which parcels need to be sent
    var parcelsToSend = List<int>.generate(parcels.length, (i) => i);
    int attempts = 0;

    while (parcelsToSend.isNotEmpty && attempts < BLEParcelConstants.maxRetries) {
      attempts++;

      // Register the receipt waiter BEFORE sending — a fast peer (the ESP32)
      // can answer before the post-send delays finish, and the receipt would
      // otherwise be dropped, forcing a needless retry. The timeout must cover
      // the whole SEND duration (each parcel takes ~interParcelDelay, plus a
      // listen window every parcelsBeforePause) and then the base receipt window
      // — otherwise large messages (e.g. 30 parcels) time out mid-send and never
      // complete.
      final sendMs = parcelsToSend.length *
              (BLEParcelConstants.interParcelDelayMs + 60) +
          (parcelsToSend.length ~/ BLEParcelConstants.parcelsBeforePause) *
              BLEParcelConstants.listenWindowMs;
      final receiptFuture = _awaitReceipt(message.msgId,
          timeoutMs: sendMs + BLEParcelConstants.receiptTimeoutMs);

      // Send parcels
      int parcelsSent = 0;
      for (final parcelIdx in parcelsToSend) {
        final parcel = parcels[parcelIdx];

        try {
          await _sendCallback!(deviceId, parcel.toBytes());
          parcelsSent++;

          // Intra-parcel delay
          await Future.delayed(
            Duration(milliseconds: BLEParcelConstants.interParcelDelayMs),
          );

          // Listen window every N parcels
          if (parcelsSent % BLEParcelConstants.parcelsBeforePause == 0) {
            _log('BLEQueue: Listen window after $parcelsSent parcels');
            await _listenWindow();
          }
        } catch (e) {
          _log('BLEQueue: Failed to send parcel $parcelIdx: $e');
          // Continue with remaining parcels, will retry failed ones
        }
      }

      // Wait for the receipt registered above.
      final receipt = await receiptFuture;

      if (receipt == null) {
        _log('BLEQueue: No receipt received for ${message.msgId}');
        return false;
      }

      switch (receipt.status) {
        case BLEReceiptStatus.complete:
          _log('BLEQueue: Message ${message.msgId} confirmed complete');
          // Keep in retention cache for a while in case of delayed retransmit requests
          return true;

        case BLEReceiptStatus.missing:
          parcelsToSend = receipt.missingParcels ?? [];
          _log('BLEQueue: Retransmitting ${parcelsToSend.length} '
              'missing parcels: $parcelsToSend');
          break;

        case BLEReceiptStatus.checksumFailed:
          _log('BLEQueue: Checksum failed, retransmitting all');
          parcelsToSend = List<int>.generate(parcels.length, (i) => i);
          break;
      }
    }

    return false;
  }

  /// Pause to allow incoming data
  Future<void> _listenWindow() async {
    await Future.delayed(
      Duration(milliseconds: BLEParcelConstants.listenWindowMs),
    );
  }

  /// Register a receipt waiter immediately (synchronously) and return a future
  /// that resolves with the receipt or null on timeout. Registering before the
  /// parcels are sent avoids losing a receipt from a fast peer.
  Future<BLEReceipt?> _awaitReceipt(String msgId, {int? timeoutMs}) {
    final completer = Completer<BLEReceipt>();
    _pendingReceipts[msgId] = completer;
    return completer.future
        .timeout(Duration(
            milliseconds: timeoutMs ?? BLEParcelConstants.receiptTimeoutMs))
        .then<BLEReceipt?>((r) => r)
        .catchError((_) {
          _log('BLEQueue: Receipt timeout for $msgId');
          return null;
        })
        .whenComplete(() => _pendingReceipts.remove(msgId));
  }

  /// Handle incoming data from BLE
  void onDataReceived(String deviceId, Uint8List data) {
    // First, try to parse as receipt
    try {
      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;

      if (json.containsKey('msg_id') && json.containsKey('status')) {
        final receipt = BLEReceipt.fromJson(json);
        _handleReceipt(receipt);
        return;
      }
    } catch (_) {
      // Not a receipt, try as parcel
    }

    // Try to parse as parcel
    _handleIncomingParcel(deviceId, data);
  }

  /// Handle an incoming receipt
  void _handleReceipt(BLEReceipt receipt) {
    _log('BLEQueue: Received receipt for ${receipt.msgId}: '
        '${receipt.status.name}');

    // First check if we're waiting for this receipt (during active send)
    final completer = _pendingReceipts[receipt.msgId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(receipt);
      return;
    }

    // If not waiting, this might be a delayed retransmission request
    // Check if we still have the sent message in retention
    if (receipt.status == BLEReceiptStatus.missing) {
      _handleRetransmissionRequest(receipt);
    }
  }

  /// Handle a retransmission request for a previously sent message
  Future<void> _handleRetransmissionRequest(BLEReceipt receipt) async {
    final record = _sentMessages[receipt.msgId];
    if (record == null) {
      _log('BLEQueue: Cannot retransmit ${receipt.msgId} - message not in retention');
      return;
    }

    final missingIndices = receipt.missingParcels ?? [];
    if (missingIndices.isEmpty) return;

    _log('BLEQueue: Retransmitting ${missingIndices.length} parcels '
        'for ${receipt.msgId} (delayed request)');

    for (final idx in missingIndices) {
      if (idx >= 0 && idx < record.parcels.length) {
        try {
          await _sendCallback!(record.targetDeviceId, record.parcels[idx].toBytes());
          await Future.delayed(
            Duration(milliseconds: BLEParcelConstants.interParcelDelayMs),
          );
        } catch (e) {
          _log('BLEQueue: Failed to retransmit parcel $idx: $e');
        }
      }
    }
  }

  /// Handle an incoming parcel.
  ///
  /// The wire format gives NO explicit header/data type flag, and
  /// [BLEParcel.fromBytesAsHeader] never returns null for a >=9-byte buffer (it
  /// always yields parcelNum 0 / isHeader true). So we MUST distinguish by
  /// state: the FIRST parcel seen for a msgId is its header; any subsequent
  /// parcel for that msgId is a data parcel. (Delivery is ordered — the sender's
  /// queue writes the header first and retransmits only data parcels — so the
  /// header always arrives before its data.)
  void _handleIncomingParcel(String deviceId, Uint8List data) {
    _incomingBuffers.putIfAbsent(deviceId, () => {});
    final deviceBuffers = _incomingBuffers[deviceId]!;

    if (data.length < BLEParcelConstants.dataOverhead) {
      _log('BLEQueue: Incoming data too short to be a parcel (${data.length}B)');
      return;
    }
    final msgId = String.fromCharCodes(data.sublist(0, 2));
    final existing = deviceBuffers[msgId];

    if (existing == null) {
      // First parcel for this message → header.
      final header = BLEParcel.fromBytesAsHeader(data);
      if (header == null) {
        _log('BLEQueue: Failed to parse incoming data as header');
        return;
      }
      final incoming = BLEIncomingMessage(
        msgId: header.msgId,
        totalParcels: header.totalParcels,
        expectedChecksum: header.checksum,
        flags: header.flags,
        sourceDeviceId: deviceId,
      );
      incoming.addParcel(header);
      deviceBuffers[msgId] = incoming;
      final compressionInfo = header.isCompressed
          ? ', compressed with algorithm ${header.compressionAlgorithm}'
          : '';
      _log('BLEQueue: Started receiving ${header.msgId} '
          '(${header.totalParcels} parcels expected$compressionInfo)');
      if (incoming.isComplete) _finalizeIncomingMessage(deviceId, incoming);
      return;
    }

    // Subsequent parcel for a known message → data parcel.
    final dp = BLEParcel.fromBytesAsData(data);
    if (dp == null || dp.parcelNum == 0) {
      _log('BLEQueue: Failed to parse incoming data parcel for $msgId');
      return;
    }
    existing.addParcel(dp);
    _log('BLEQueue: Received parcel ${dp.parcelNum} for $msgId');
    if (existing.isComplete) _finalizeIncomingMessage(deviceId, existing);
  }

  /// Finalize a complete incoming message
  void _finalizeIncomingMessage(String deviceId, BLEIncomingMessage incoming) {
    final assembled = incoming.assemble();

    if (assembled != null) {
      _log('BLEQueue: Message ${incoming.msgId} complete, '
          'checksum verified (${assembled.length} bytes)');

      // Send complete receipt
      _sendReceipt(deviceId, BLEReceipt.complete(incoming.msgId));

      // Emit completed message
      _incomingController.add(BLECompletedMessage(
        msgId: incoming.msgId,
        sourceDeviceId: deviceId,
        payload: assembled,
      ));
    } else {
      _log('BLEQueue: Message ${incoming.msgId} checksum failed');
      _sendReceipt(deviceId, BLEReceipt.checksumFailed(incoming.msgId));
    }

    // Clean up buffer
    _incomingBuffers[deviceId]?.remove(incoming.msgId);
  }

  /// Send a receipt to the sender
  Future<void> _sendReceipt(String deviceId, BLEReceipt receipt) async {
    if (_sendCallback == null) return;

    try {
      final data = utf8.encode(jsonEncode(receipt.toJson()));
      await _sendCallback!(deviceId, Uint8List.fromList(data));
      _log('BLEQueue: Sent receipt for ${receipt.msgId}: '
          '${receipt.status.name}');
    } catch (e) {
      _log('BLEQueue: Failed to send receipt: $e');
    }
  }

  /// Request missing parcels for a stalled message
  void requestMissingParcels(String deviceId, String msgId) {
    final incoming = _incomingBuffers[deviceId]?[msgId];
    if (incoming == null) return;

    final missing = incoming.missingParcels;
    if (missing.isNotEmpty) {
      _sendReceipt(deviceId, BLEReceipt.missing(msgId, missing));
    }
  }

  /// Clean up stale incoming messages
  void cleanupStaleMessages() {
    const staleTimeout = Duration(seconds: 60);

    for (final deviceBuffers in _incomingBuffers.values) {
      deviceBuffers.removeWhere((msgId, incoming) {
        if (incoming.isStale(timeout: staleTimeout)) {
          _log('BLEQueue: Removing stale message $msgId');
          return true;
        }
        return false;
      });
    }
  }

  /// Get queue length for a device
  int getQueueLength(String deviceId) {
    return _outgoingQueues[deviceId]?.length ?? 0;
  }

  /// Check if currently sending to a device
  bool isSending(String deviceId) {
    return _isSending[deviceId] ?? false;
  }

  /// Cancel all pending messages for a device
  void cancelDevice(String deviceId) {
    _outgoingQueues.remove(deviceId);
    _incomingBuffers.remove(deviceId);
    _isSending.remove(deviceId);
  }

  /// Dispose service
  void dispose() {
    _housekeepingTimer?.cancel();
    _housekeepingTimer = null;
    _outgoingQueues.clear();
    _incomingBuffers.clear();
    _sentMessages.clear();
    _isSending.clear();
    for (final completer in _pendingReceipts.values) {
      if (!completer.isCompleted) {
        completer.completeError('Service disposed');
      }
    }
    _pendingReceipts.clear();
    _incomingController.close();
  }
}

/// Record of a sent message retained for potential retransmission
class _SentMessageRecord {
  final String msgId;
  final String targetDeviceId;
  final List<BLEParcel> parcels;
  final DateTime sentAt;

  _SentMessageRecord({
    required this.msgId,
    required this.targetDeviceId,
    required this.parcels,
    required this.sentAt,
  });
}

/// Represents a completed incoming message
class BLECompletedMessage {
  final String msgId;
  final String sourceDeviceId;
  final Uint8List payload;
  final DateTime receivedAt;

  BLECompletedMessage({
    required this.msgId,
    required this.sourceDeviceId,
    required this.payload,
  }) : receivedAt = DateTime.now();

  @override
  String toString() {
    return 'BLECompletedMessage(msgId=$msgId, from=$sourceDeviceId, '
        'size=${payload.length})';
  }
}
