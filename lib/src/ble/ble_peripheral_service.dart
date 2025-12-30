import 'dart:async';
import 'dart:typed_data';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:logger/logger.dart';

/// Callback when data is received from a connected central
typedef PeripheralDataCallback = void Function(String deviceId, Uint8List data);

/// Callback when a central connects/disconnects
typedef PeripheralConnectionCallback = void Function(String deviceId, bool connected);

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
  final Logger _log = Logger();
  
  /// BLE Service UUID (derived from public key)
  final String serviceUuid;
  
  /// Characteristic UUID for data transfer
  static const String characteristicUuid = '0000ff01-0000-1000-8000-00805f9b34fb';
  
  /// Maximum characteristic value size
  static const int maxCharacteristicSize = 512;
  
  /// Whether peripheral mode is currently active
  bool _isAdvertising = false;
  
  /// Connected centrals, keyed by device ID
  final Set<String> _connectedCentrals = {};
  
  /// Callback when data is received
  PeripheralDataCallback? onDataReceived;
  
  /// Callback for connection events
  PeripheralConnectionCallback? onConnectionChanged;
  
  BlePeripheralService({required this.serviceUuid});
  
  /// Whether we're currently advertising
  bool get isAdvertising => _isAdvertising;
  
  /// Number of connected centrals
  int get connectedCount => _connectedCentrals.length;
  
  /// Initialize the peripheral service
  Future<void> initialize() async {
    _log.i('Initializing BLE peripheral service');
    
    try {
      // Initialize the peripheral
      await BlePeripheral.initialize();
      
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
      
      _log.i('BLE peripheral initialized');
    } catch (e) {
      _log.e('Failed to initialize BLE peripheral: $e');
      rethrow;
    }
  }
  
  /// Start advertising our service
  Future<void> startAdvertising({String? localName}) async {
    if (_isAdvertising) {
      _log.w('Already advertising');
      return;
    }
    
    try {
      // Add the GATT service with our characteristic
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
      _log.i('Started advertising: $serviceUuid');
    } catch (e) {
      _log.e('Failed to start advertising: $e');
      rethrow;
    }
  }
  
  /// Stop advertising
  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;
    
    try {
      await BlePeripheral.stopAdvertising();
      _isAdvertising = false;
      _log.i('Stopped advertising');
    } catch (e) {
      _log.e('Failed to stop advertising: $e');
    }
  }
  
  /// Send data to a connected central via notification
  Future<bool> sendData(String deviceId, Uint8List data) async {
    if (!_connectedCentrals.contains(deviceId)) {
      _log.w('Cannot send to disconnected central: $deviceId');
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
      _log.e('Failed to send data to $deviceId: $e');
      return false;
    }
  }
  
  /// Send data to all connected centrals
  Future<void> broadcastData(Uint8List data, {String? excludeDevice}) async {
    for (final deviceId in _connectedCentrals) {
      if (deviceId == excludeDevice) continue;
      await sendData(deviceId, data);
    }
  }
  
  // ===== Event handlers =====
  
  void _onConnectionStateChanged(String deviceId, bool connected) {
    if (connected) {
      _connectedCentrals.add(deviceId);
      _log.i('Central connected: $deviceId');
    } else {
      _connectedCentrals.remove(deviceId);
      _log.i('Central disconnected: $deviceId');
    }
    
    onConnectionChanged?.call(deviceId, connected);
  }
  
  void _onCharacteristicSubscriptionChange(
    String deviceId,
    String characteristicId,
    bool isSubscribed,
    String? name,
  ) {
    // On iOS/Mac/Windows, subscription change indicates device availability
    if (isSubscribed) {
      _connectedCentrals.add(deviceId);
      _log.i('Central subscribed: $deviceId (char: $characteristicId)');
    } else {
      _connectedCentrals.remove(deviceId);
      _log.i('Central unsubscribed: $deviceId (char: $characteristicId)');
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
    _log.d('Read request from $deviceId');
    
    // Respond with empty data
    return ReadRequestResult(value: Uint8List(0));
  }
  
  WriteRequestResult? _onWriteRequest(
    String deviceId,
    String characteristicId,
    int offset,
    Uint8List? value,
  ) {
    _log.d('Write request from $deviceId: ${value?.length ?? 0} bytes');
    
    // Deliver data to callback
    if (value != null && value.isNotEmpty) {
      onDataReceived?.call(deviceId, Uint8List.fromList(value));
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
