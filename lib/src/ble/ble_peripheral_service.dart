import 'dart:async';
import 'package:ble_peripheral_bondless/ble_peripheral_bondless.dart';
import 'package:flutter/foundation.dart';

/// Callback when data is received from a connected central
typedef PeripheralDataCallback = void Function(
    String deviceId, Uint8List data, int rssi);

/// Callback when a central connects/disconnects
typedef PeripheralConnectionCallback = void Function(
    String deviceId, bool connected);

/// BLE Peripheral service - advertises our presence and accepts connections.
///
/// In Bitchat mesh, every device acts as both Central (scanner) and
/// Peripheral (advertiser) simultaneously. This allows maximum connectivity.
///
/// Uses the ble_peripheral package for peripheral mode.
///
/// The service UUID is derived from the user's public key (last 128 bits).
/// Identity details are exchanged via ANNOUNCE packets after connection.
class BlePeripheralService {
  /// BLE Service UUID (derived from public key)
  final String serviceUuid;

  /// Characteristic UUID for data transfer
  static const String characteristicUuid =
      '0000ff01-0000-1000-8000-00805f9b34fb';

  /// Maximum characteristic value size
  static const int maxCharacteristicSize = 512;

  /// Whether peripheral mode is currently active
  bool _isAdvertising = false;

  /// Whether the peripheral service is active and should process data
  /// Set to false when BLE is disabled to block ALL incoming data
  bool _active = false;

  /// Connected centrals, keyed by device ID
  final Set<String> _connectedCentrals = {};

  /// Completer for waiting for BLE to be powered on
  final Completer<void> _bleReadyCompleter = Completer<void>();

  /// Callback when data is received
  PeripheralDataCallback? onDataReceived;

  /// Callback for connection events
  PeripheralConnectionCallback? onConnectionChanged;

  BlePeripheralService({required this.serviceUuid});

  /// Whether we're currently advertising
  bool get isAdvertising => _isAdvertising;

  /// Number of connected centrals
  int get connectedCount => _connectedCentrals.length;

  /// Connected centrals as device IDs.
  Set<String> get connectedDeviceIds => Set.unmodifiable(_connectedCentrals);

  /// Whether a specific device is connected as a central
  bool isDeviceConnected(String deviceId) =>
      _connectedCentrals.contains(deviceId);

  /// Initialize the peripheral service
  Future<void> initialize() async {
    debugPrint('Initializing BLE peripheral service');

    try {
      // Initialize the peripheral
      await BlePeripheral.initialize();

      // Set up BLE state change callback to know when powered on.
      // On iOS cold start, CoreBluetooth reports 'unknown' initially and
      // transitions to 'poweredOn' asynchronously. We MUST wait for the
      // actual callback — isSupported() returns true even when the adapter
      // is in 'unknown' state, and addService() will time out if called
      // before CoreBluetooth is truly ready.
      BlePeripheral.setBleStateChangeCallback((bool state) {
        debugPrint('BLE peripheral state changed: $state');
        if (state && !_bleReadyCompleter.isCompleted) {
          _bleReadyCompleter.complete();
        }
      });

      // Set up connection state callback (Android only, but safe to call on all platforms)
      BlePeripheral.setConnectionStateChangeCallback(_onConnectionStateChanged);

      // Set up characteristic subscription callback (iOS/Mac/Windows)
      BlePeripheral.setCharacteristicSubscriptionChangeCallback(
        _onCharacteristicSubscriptionChange,
      );

      // Set up read request callback
      BlePeripheral.setReadRequestCallback(_onReadRequest);

      // Set up write request callback
      BlePeripheral.setWriteRequestCallback(_onWriteRequest);

      debugPrint('BLE peripheral initialized');
    } catch (e) {
      debugPrint('Failed to initialize BLE peripheral: $e');
      rethrow;
    }
  }

  /// Start advertising our service.
  ///
  /// Waits for CoreBluetooth to be powered on, then adds the GATT service
  /// and starts advertising. If the initial attempt fails (iOS cold-start
  /// race), retries once after the BLE state callback fires.
  Future<void> startAdvertising({String? localName}) async {
    if (_isAdvertising) {
      debugPrint('Already advertising');
      return;
    }

    try {
      // Wait for BLE to be powered on (important for iOS cold start).
      // The completer is resolved by the BleStateChangeCallback.
      debugPrint('Waiting for BLE to be powered on...');
      await _bleReadyCompleter.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw Exception('Timeout waiting for BLE to power on');
        },
      );
      debugPrint('BLE is powered on, adding service...');

      await _addServiceAndStartAdvertising();
    } catch (e) {
      debugPrint('First advertising attempt failed: $e');

      // On iOS, the BLE state callback can arrive before CoreBluetooth
      // is fully ready to accept GATT services. Wait briefly and retry.
      debugPrint('Retrying service addition in 2 seconds...');
      await Future.delayed(const Duration(seconds: 2));

      try {
        await _addServiceAndStartAdvertising();
      } catch (retryError) {
        debugPrint('Retry also failed: $retryError');
        rethrow;
      }
    }
  }

  /// Add the GATT service and start BLE advertising.
  Future<void> _addServiceAndStartAdvertising() async {
    await BlePeripheral.addService(
      BleService(
        uuid: serviceUuid,
        primary: true,
        characteristics: [
          BleCharacteristic(
            uuid: characteristicUuid,
            properties: [
              CharacteristicProperties.read.index,
              CharacteristicProperties.write.index,
              CharacteristicProperties.writeWithoutResponse.index,
              CharacteristicProperties.notify.index,
            ],
            permissions: [
              AttributePermissions.readable.index,
              AttributePermissions.writeable.index,
            ],
          ),
        ],
      ),
    );

    // Start advertising - NO local name to keep packet small
    // The 128-bit UUID derived from pubkey is used for discovery
    // Identity exchange happens via ANNOUNCE after connection
    await BlePeripheral.startAdvertising(
      services: [serviceUuid],
      // localName omitted to fit in legacy advertising packet
    );

    _isAdvertising = true;
    _active = true; // Enable data processing
    debugPrint('Started advertising: $serviceUuid');
  }

  /// Stop advertising
  Future<void> stopAdvertising() async {
    // Disable data processing FIRST - this blocks all incoming writes
    // even if stopAdvertising() fails or takes time
    _active = false;

    if (!_isAdvertising) return;

    try {
      await BlePeripheral.stopAdvertising();
      _isAdvertising = false;

      // Clear callbacks to stop receiving data
      // This prevents processing packets after BLE is disabled
      onDataReceived = null;
      onConnectionChanged = null;

      // Disconnect all connected centrals
      await disconnectAllCentrals();

      debugPrint('Stopped advertising');
    } catch (e) {
      debugPrint('Failed to stop advertising: $e');
    }
  }

  /// Disconnect all connected centrals
  Future<void> disconnectAllCentrals() async {
    if (_connectedCentrals.isEmpty) return;

    debugPrint(
        'Disconnecting all ${_connectedCentrals.length} connected centrals');
    final deviceIds = _connectedCentrals.toList();

    // Notify disconnection for each central
    for (final deviceId in deviceIds) {
      onConnectionChanged?.call(deviceId, false);
    }

    // Clear the connection set
    _connectedCentrals.clear();
  }

  /// Send data to a connected central via notification
  Future<bool> sendData(String deviceId, Uint8List data) async {
    if (!_connectedCentrals.contains(deviceId)) {
      debugPrint('Cannot send to disconnected central: $deviceId');
      return false;
    }

    try {
      // Send via characteristic notification
      await BlePeripheral.updateCharacteristic(
        characteristicId: characteristicUuid,
        value: data,
        deviceId: deviceId,
      );
      return true;
    } catch (e) {
      debugPrint('Failed to send data to $deviceId: $e');
      return false;
    }
  }

  /// Send data to all connected centrals
  Future<void> broadcastData(Uint8List data,
      {Set<String>? excludeDevices}) async {
    for (final deviceId in _connectedCentrals) {
      if (excludeDevices != null && excludeDevices.contains(deviceId)) continue;
      await sendData(deviceId, data);
    }
  }

  // ===== Event handlers =====

  void _onConnectionStateChanged(String deviceId, bool connected) {
    if (!_active) return;

    if (connected) {
      // Track the raw connection but DON'T fire onConnectionChanged yet.
      // The central hasn't subscribed to notifications, so we can't send
      // data to it. Wait for the subscription event (_onCharacteristicSubscriptionChange)
      // to fire onConnectionChanged — that's when communication is actually possible.
      _connectedCentrals.add(deviceId);
      debugPrint('Central connected: $deviceId (waiting for subscription)');
    } else {
      _connectedCentrals.remove(deviceId);
      debugPrint('Central disconnected: $deviceId');
      // Fire disconnect immediately — we need to clean up state
      onConnectionChanged?.call(deviceId, false);
    }
  }

  void _onCharacteristicSubscriptionChange(
    String deviceId,
    String characteristicId,
    bool isSubscribed,
    String? name,
  ) {
    if (!_active) return;

    // On iOS/Mac/Windows, subscription change indicates device availability
    if (isSubscribed) {
      _connectedCentrals.add(deviceId);
      debugPrint('Central subscribed: $deviceId (char: $characteristicId)');
    } else {
      _connectedCentrals.remove(deviceId);
      debugPrint('Central unsubscribed: $deviceId (char: $characteristicId)');
    }

    onConnectionChanged?.call(deviceId, isSubscribed);
  }

  ReadRequestResult? _onReadRequest(
    String deviceId,
    String characteristicId,
    int offset,
    Uint8List? value,
  ) {
    // We don't use read requests - data flows via write + notify
    debugPrint('Read request from $deviceId');

    // Respond with empty data
    return ReadRequestResult(value: Uint8List(0));
  }

  WriteRequestResult? _onWriteRequest(
    String deviceId,
    String characteristicId,
    int offset,
    Uint8List? value,
  ) {
    // Block ALL writes when peripheral is inactive (BLE disabled)
    if (!_active) {
      debugPrint('Ignoring write request - peripheral inactive');
      return WriteRequestResult(); // Acknowledge but ignore
    }

    // debugPrint('Write request from $deviceId: ${value?.length ?? 0} bytes');

    // Deliver data to callback
    if (value != null && value.isNotEmpty) {
      // Peripheral doesn't have RSSI data, use placeholder value
      onDataReceived?.call(deviceId, Uint8List.fromList(value), -100);
    }

    // Acknowledge the write (return null or WriteRequestResult for success)
    return WriteRequestResult();
  }

  /// Clean up resources
  Future<void> dispose() async {
    await stopAdvertising();
    _connectedCentrals.clear();
  }
}
