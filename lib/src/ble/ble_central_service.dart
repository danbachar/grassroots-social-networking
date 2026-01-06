import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:logger/logger.dart';

/// Discovered BLE device info
class DiscoveredDevice {
  final String deviceId;
  final String? name;
  final String serviceUuid;
  final int rssi;
  final DateTime discoveredAt;
  final BluetoothDevice device;
  
  DiscoveredDevice({
    required this.deviceId,
    this.name,
    required this.serviceUuid,
    required this.rssi,
    required this.device,
  }) : discoveredAt = DateTime.now();
}

/// Connected peer via Central role
class ConnectedPeer {
  final String deviceId;
  final BluetoothDevice device;
  final BluetoothCharacteristic characteristic;
  final int rssi;
  DateTime lastActivity;
  
  ConnectedPeer({
    required this.deviceId,
    required this.device,
    required this.characteristic,
    required this.rssi,
  }) : lastActivity = DateTime.now();
}

/// Callback when data is received from a peripheral
typedef CentralDataCallback = void Function(String deviceId, Uint8List data, int rssi);

/// Callback when a peripheral is discovered
typedef DeviceDiscoveredCallback = void Function(DiscoveredDevice device);

/// Callback for connection state changes
typedef CentralConnectionCallback = void Function(String deviceId, bool connected);

/// BLE Central service - scans for and connects to peripherals.
/// 
/// Scans for devices advertising our service UUID pattern and
/// connects to them for mesh communication.
class BleCentralService {
  final Logger _log = Logger();
  
  /// Our service UUID (to filter scan results and identify peers)
  final String serviceUuid;
  
  /// Characteristic UUID (must match peripheral)
  static const String characteristicUuid = '0000ff01-0000-1000-8000-00805f9b34fb';
  
  /// Scan timeout
  static const Duration scanTimeout = Duration(seconds: 10);
  
  /// Connection timeout
  static const Duration connectionTimeout = Duration(seconds: 15);
  
  /// Whether scanning is active
  bool _isScanning = false;
  
  /// Discovered devices, keyed by device ID
  final Map<String, DiscoveredDevice> _discovered = {};
  
  /// Connected peripherals, keyed by device ID
  final Map<String, ConnectedPeer> _connected = {};
  
  /// Stream subscriptions
  final List<StreamSubscription> _subscriptions = [];
  
  /// Callback when data is received
  CentralDataCallback? onDataReceived;
  
  /// Callback when a device is discovered
  DeviceDiscoveredCallback? onDeviceDiscovered;
  
  /// Callback for connection changes
  CentralConnectionCallback? onConnectionChanged;
  
  BleCentralService({required this.serviceUuid});
  
  /// Whether scanning is active
  bool get isScanning => _isScanning;
  
  /// Number of connected peripherals
  int get connectedCount => _connected.length;
  
  /// Get discovered devices sorted by RSSI (strongest signal first)
  List<DiscoveredDevice> get discoveredDevices {
    final devices = _discovered.values.toList();
    // Sort by RSSI descending (higher RSSI = stronger signal, e.g., -40 > -80)
    devices.sort((a, b) => b.rssi.compareTo(a.rssi));
    return devices;
  }
  
  /// Get connected peers sorted by RSSI (strongest signal first)
  List<ConnectedPeer> get connectedPeers {
    final peers = _connected.values.toList();
    peers.sort((a, b) => b.rssi.compareTo(a.rssi));
    return peers;
  }
  
  /// Initialize the central service
  Future<void> initialize() async {
    _log.i('Initializing BLE central service');
    
    // Check if Bluetooth is available
    if (!await FlutterBluePlus.isSupported) {
      throw UnsupportedError('Bluetooth not supported on this device');
    }
    
    // Wait for Bluetooth to be on
    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) {
      _log.w('Bluetooth is not on: $state');
      // Could prompt user to enable Bluetooth
    }
    
    _log.i('BLE central initialized');
  }
  
  /// Start scanning for peers
  Future<void> startScan({Duration? timeout}) async {
    if (_isScanning) {
      _log.w('Already scanning');
      return;
    }
    
    _isScanning = true;
    _log.i('Starting BLE scan for service: $serviceUuid');
    
    try {
      // Listen for scan results
      _subscriptions.add(
        FlutterBluePlus.scanResults.listen(_onScanResults),
      );
      
      // Start scanning
      // Note: We scan for all devices and filter manually because
      // some platforms have issues with service UUID filtering
      await FlutterBluePlus.startScan(
        timeout: timeout ?? scanTimeout,
        androidScanMode: AndroidScanMode.lowLatency,
      );
      
      // Mark as not scanning when done
      FlutterBluePlus.isScanning.listen((scanning) {
        if (!scanning) {
          _isScanning = false;
          _log.i('Scan completed');
        }
      });
    } catch (e) {
      _isScanning = false;
      _log.e('Failed to start scan: $e');
      rethrow;
    }
  }
  
  /// Stop scanning
  Future<void> stopScan() async {
    if (!_isScanning) return;
    
    await FlutterBluePlus.stopScan();
    _isScanning = false;
    _log.i('Scan stopped');
  }
  
  /// Connect to a discovered device
  Future<bool> connectToDevice(String deviceId) async {
    final discovered = _discovered[deviceId];
    if (discovered == null) {
      _log.w('Device not found: $deviceId');
      return false;
    }
    
    if (_connected.containsKey(deviceId)) {
      _log.w('Already connected to: $deviceId');
      return true;
    }
    
    _log.i('Connecting to: $deviceId');
    
    try {
      final device = discovered.device;
      
      // Connect with timeout
      await device.connect(timeout: connectionTimeout);
      
      // Listen for disconnection
      _subscriptions.add(
        device.connectionState.listen((state) {
          if (state == BluetoothConnectionState.disconnected) {
            _onDeviceDisconnected(deviceId);
          }
        }),
      );
      
      // Discover services
      final services = await device.discoverServices();
      
      // Find our service
      BluetoothService? targetService;
      for (final service in services) {
        if (service.uuid.toString().toLowerCase() == 
            discovered.serviceUuid.toLowerCase()) {
          targetService = service;
          break;
        }
      }
      
      if (targetService == null) {
        await device.disconnect();
        return false;
      }
      
      // Find our characteristic
      // Note: flutter_blue_plus may return short-form UUIDs (e.g., "ff01")
      // while we define full 128-bit UUIDs, so we need to compare the short form
      final shortCharUuid = characteristicUuid.substring(4, 8).toLowerCase(); // Extract "ff01" from "0000ff01-..."
      BluetoothCharacteristic? targetChar;
      for (final char in targetService.characteristics) {
        final charUuidStr = char.uuid.toString().toLowerCase();
        // Match either the full UUID or the short form
        if (charUuidStr == characteristicUuid.toLowerCase() ||
            charUuidStr == shortCharUuid) {
          targetChar = char;
          break;
        }
      }
      
      if (targetChar == null) {
        await device.disconnect();
        return false;
      }

      // Enable notifications to receive data
      await targetChar.setNotifyValue(true);
      
      // Listen for incoming data
      _subscriptions.add(
        targetChar.onValueReceived.listen((data) {
          _onDataReceived(deviceId, Uint8List.fromList(data));
        }),
      );
      
      // Store connection with RSSI from discovery
      _connected[deviceId] = ConnectedPeer(
        deviceId: deviceId,
        device: device,
        characteristic: targetChar,
        rssi: discovered.rssi,
      );
      
      _log.i('Connected to: $deviceId');
      onConnectionChanged?.call(deviceId, true);
      
      return true;
    } catch (e) {
      _log.e('Failed to connect to $deviceId: $e');
      return false;
    }
  }
  
  /// Disconnect from a device
  Future<void> disconnectFromDevice(String deviceId) async {
    final peer = _connected[deviceId];
    if (peer == null) return;
    
    try {
      await peer.device.disconnect();
    } catch (e) {
      _log.e('Error disconnecting from $deviceId: $e');
    }
    
    _onDeviceDisconnected(deviceId);
  }
  
  /// Send data to a connected peripheral
  Future<bool> sendData(String deviceId, Uint8List data) async {
    final peer = _connected[deviceId];
    if (peer == null) {
      _log.w('Cannot send to disconnected device: $deviceId');
      return false;
    }
    
    try {
      await peer.characteristic.write(data, withoutResponse: true);
      peer.lastActivity = DateTime.now();
      return true;
    } catch (e) {
      _log.e('Failed to send data to $deviceId: $e');
      return false;
    }
  }
  
  /// Send data to all connected peripherals (sorted by signal strength)
  Future<void> broadcastData(Uint8List data, {String? excludeDevice}) async {
    // Sort by RSSI descending (strongest signal first)
    final peers = _connected.values.toList();
    peers.sort((a, b) => b.rssi.compareTo(a.rssi));
    
    for (final peer in peers) {
      if (peer.deviceId == excludeDevice) continue;
      await sendData(peer.deviceId, data);
    }
  }
  
  // ===== Event handlers =====
  
  void _onScanResults(List<ScanResult> results) {
    for (final result in results) {
      // Check if this device advertises any service UUID
      // Each Bitchat device advertises a unique UUID derived from its public key
      // We discover all devices and filter after ANNOUNCE exchange
      if (result.advertisementData.serviceUuids.isNotEmpty) {
        final uuidStr = result.advertisementData.serviceUuids.first.toString().toLowerCase();
        final deviceId = result.device.remoteId.str;
        
        if (!_discovered.containsKey(deviceId)) {
          final discovered = DiscoveredDevice(
            deviceId: deviceId,
            name: result.advertisementData.advName,
            serviceUuid: uuidStr,
            rssi: result.rssi,
            device: result.device,
          );
          
          _discovered[deviceId] = discovered;
          _log.d('Discovered: $deviceId (${result.advertisementData.advName})');
          onDeviceDiscovered?.call(discovered);
        }
      }
    }
  }
  
  void _onDataReceived(String deviceId, Uint8List data) {
    _log.d('Data received from $deviceId: ${data.length} bytes');
    
    final peer = _connected[deviceId];
    if (peer != null) {
      peer.lastActivity = DateTime.now();
      // Pass RSSI along with the data
      onDataReceived?.call(deviceId, data, peer.rssi);
    } else {
      _log.w('Data received from unknown device: $deviceId');
    }
  }
  
  void _onDeviceDisconnected(String deviceId) {
    _connected.remove(deviceId);
    _log.i('Disconnected from: $deviceId');
    onConnectionChanged?.call(deviceId, false);
  }
  
  /// Clean up resources
  Future<void> dispose() async {
    await stopScan();
    
    // Disconnect all
    for (final peer in _connected.values.toList()) {
      try {
        await peer.device.disconnect();
      } catch (_) {}
    }
    
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    
    _subscriptions.clear();
    _connected.clear();
    _discovered.clear();
  }
}
