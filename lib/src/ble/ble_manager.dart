import 'dart:async';
import 'dart:typed_data';
import 'package:logger/logger.dart';
import 'ble_central_service.dart';
import 'ble_peripheral_service.dart';

/// Unified BLE service combining Central and Peripheral roles.
/// 
/// In Bitchat mesh, devices run both modes simultaneously:
/// - Peripheral: Advertise presence, accept incoming connections
/// - Central: Scan for peers, initiate outgoing connections
/// 
/// This manager coordinates both and provides a unified interface.
class BleManager {
  final Logger _log = Logger();
  
  /// Our BLE service UUID (derived from public key)
  final String serviceUuid;
  
  /// Local name for advertising
  final String? localName;
  
  /// Central service (scanner/connector)
  late final BleCentralService _central;
  
  /// Peripheral service (advertiser)
  late final BlePeripheralService _peripheral;
  
  /// Map from BLE device ID to pubkey (set after ANNOUNCE)
  final Map<String, Uint8List> _deviceToPubkey = {};
  
  /// Map from pubkey to BLE device ID
  final Map<String, String> _pubkeyToDevice = {};
  
  /// Map from device ID to latest RSSI value (from last data reception)
  final Map<String, int> _deviceRssi = {};
  
  /// Callback when data is received (regardless of role)
  void Function(String deviceId, Uint8List data, int rssi)? onDataReceived;
  
  /// Callback when a device connects (regardless of role)
  void Function(String deviceId, bool isCentral)? onDeviceConnected;
  
  /// Callback when a device disconnects
  void Function(String deviceId)? onDeviceDisconnected;
  
  /// Callback when a new device is discovered
  void Function(DiscoveredDevice device)? onDeviceDiscovered;
  
  BleManager({
    required this.serviceUuid,
    this.localName,
  }) {
    _central = BleCentralService(serviceUuid: serviceUuid);
    _peripheral = BlePeripheralService(serviceUuid: serviceUuid);
  }
  
  /// Whether any BLE activity is active
  bool get isActive => _central.isScanning || _peripheral.isAdvertising;
  
  /// Total connected peers (both roles)
  int get connectedCount => _central.connectedCount + _peripheral.connectedCount;
  
  /// All connected device IDs
  Set<String> get connectedDevices {
    final devices = <String>{};
    devices.addAll(_central.connectedPeers.map((p) => p.deviceId));
    // Note: peripheral's connected centrals are tracked separately
    return devices;
  }
  
  /// Initialize both services
  Future<void> initialize() async {
    _log.i('Initializing BLE manager');
    
    // Set up central callbacks
    _central.onDataReceived = (deviceId, data, rssi) {
      _updateRssiFromData(deviceId, rssi);
      onDataReceived?.call(deviceId, data, rssi);
    };
    _central.onConnectionChanged = (deviceId, connected) {
      if (connected) {
        onDeviceConnected?.call(deviceId, true);
      } else {
        _onDeviceDisconnected(deviceId);
      }
    };
    _central.onDeviceDiscovered = (device) {
      onDeviceDiscovered?.call(device);
    };
    
    // Set up peripheral callbacks
    _peripheral.onDataReceived = (deviceId, data, rssi) {
      _updateRssiFromData(deviceId, rssi);
      onDataReceived?.call(deviceId, data, rssi);
    };
    _peripheral.onConnectionChanged = (deviceId, connected) {
      if (connected) {
        onDeviceConnected?.call(deviceId, false);
      } else {
        _onDeviceDisconnected(deviceId);
      }
    };
    
    // Initialize services
    await _central.initialize();
    await _peripheral.initialize();
    
    _log.i('BLE manager initialized');
  }
  
  /// Start both advertising and scanning
  Future<void> start() async {
    _log.i('Starting BLE services');
    
    // Start advertising first
    await _peripheral.startAdvertising(localName: localName);
    
    // Then start scanning
    await _central.startScan();
  }
  
  /// Stop all BLE activity
  Future<void> stop() async {
    await _central.stopScan();
    await _peripheral.stopAdvertising();
    _log.i('BLE services stopped');
  }
  
  /// Start scanning (can be called repeatedly)
  Future<void> startScan({Duration? timeout}) async {
    await _central.startScan(timeout: timeout);
  }
  
  /// Connect to a discovered device by device ID
  Future<bool> connectToDevice(String deviceId) async {
    return await _central.connectToDevice(deviceId);
  }
  
  /// Associate a BLE device ID with a pubkey (after ANNOUNCE)
  void associateDeviceWithPubkey(String deviceId, Uint8List pubkey) {
    final hex = _pubkeyToHex(pubkey);
    _deviceToPubkey[deviceId] = pubkey;
    _pubkeyToDevice[hex] = deviceId;
    _log.d('Associated device $deviceId with pubkey ${hex.substring(0, 8)}...');
  }
  
  /// Get pubkey for a device ID (if known)
  Uint8List? getPubkeyForDevice(String deviceId) => _deviceToPubkey[deviceId];
  
  /// Get device ID for a pubkey (if known)
  String? getDeviceForPubkey(Uint8List pubkey) {
    return _pubkeyToDevice[_pubkeyToHex(pubkey)];
  }
  
  /// Get latest RSSI for a device
  int? getRssiForDevice(String deviceId) => _deviceRssi[deviceId];
  
  /// Get latest RSSI for a pubkey
  int? getRssiForPubkey(Uint8List pubkey) {
    final deviceId = getDeviceForPubkey(pubkey);
    return deviceId != null ? _deviceRssi[deviceId] : null;
  }
  
  /// Update RSSI when data is received
  void _updateRssiFromData(String deviceId, int rssi) {
    _deviceRssi[deviceId] = rssi;
  }
  
  /// Send data to a device by device ID
  Future<bool> sendToDevice(String deviceId, Uint8List data) async {
    // Try central first (we initiated connection)
    if (await _central.sendData(deviceId, data)) {
      return true;
    }
    
    // Try peripheral (they initiated connection)
    return await _peripheral.sendData(deviceId, data);
  }
  
  /// Send data to a peer by pubkey
  Future<bool> sendToPubkey(Uint8List pubkey, Uint8List data) async {
    final deviceId = getDeviceForPubkey(pubkey);
    if (deviceId == null) {
      _log.w('No device ID for pubkey ${_pubkeyToHex(pubkey).substring(0, 8)}...');
      return false;
    }
    return await sendToDevice(deviceId, data);
  }
  
  /// Broadcast data to all connected peers
  Future<void> broadcast(Uint8List data, {String? excludeDevice}) async {
    await _central.broadcastData(data, excludeDevice: excludeDevice);
    await _peripheral.broadcastData(data, excludeDevice: excludeDevice);
  }
  
  /// Broadcast data, excluding a peer by pubkey
  Future<void> broadcastExcludingPubkey(Uint8List data, Uint8List excludePubkey) async {
    final excludeDevice = getDeviceForPubkey(excludePubkey);
    await broadcast(data, excludeDevice: excludeDevice);
  }
  
  void _onDeviceDisconnected(String deviceId) {
    // Clean up mappings
    final pubkey = _deviceToPubkey.remove(deviceId);
    if (pubkey != null) {
      _pubkeyToDevice.remove(_pubkeyToHex(pubkey));
    }
    _deviceRssi.remove(deviceId);
    
    onDeviceDisconnected?.call(deviceId);
  }
  
  String _pubkeyToHex(Uint8List pubkey) {
    return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
  
  /// Clean up resources
  Future<void> dispose() async {
    await _central.dispose();
    await _peripheral.dispose();
    _deviceToPubkey.clear();
    _pubkeyToDevice.clear();
    _deviceRssi.clear();
  }
}
