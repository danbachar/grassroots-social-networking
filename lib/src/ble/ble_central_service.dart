import 'dart:async';
import 'package:collection/collection.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/identity.dart';
import 'package:flutter/foundation.dart';

/// Discovered BLE device info (transient DTO for callbacks, not stored)
class DiscoveredDevice {
  final String deviceId;
  final String? name;
  final String serviceUuid;
  final int rssi;

  DiscoveredDevice({
    required this.deviceId,
    this.name,
    required this.serviceUuid,
    required this.rssi,
  });
}

/// Connected peer via Central role
class ConnectedPeer {
  final String deviceId;
  final BluetoothDevice device;
  BluetoothCharacteristic characteristic;
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
///
/// Discovery state is managed externally via Redux. This service only
/// holds connected peer state (with GATT handles) and delegates all
/// discovery tracking to the caller via [onDeviceDiscovered].
class BleCentralService {

  /// Our service UUID (to filter scan results and identify peers)
  final String serviceUuid;

  /// Characteristic UUID (must match peripheral)
  static const String characteristicUuid = '0000ff01-0000-1000-8000-00805f9b34fb';

  /// Scan timeout
  static const Duration scanTimeout = Duration(seconds: 10);

  /// Connection timeout (kept short to avoid blocking connections to actual peers)
  static const Duration connectionTimeout = Duration(seconds: 5);

  /// Connected peripherals, keyed by device ID
  final Map<String, ConnectedPeer> _connected = {};

  /// Stream subscriptions
  final List<StreamSubscription> _subscriptions = [];

  /// Scan results subscription (tracked separately to avoid duplicates)
  StreamSubscription? _scanSubscription;

  /// Callback when data is received
  CentralDataCallback? onDataReceived;

  /// Callback when a device is discovered
  DeviceDiscoveredCallback? onDeviceDiscovered;

  /// Callback for connection changes
  CentralConnectionCallback? onConnectionChanged;

  BleCentralService({required this.serviceUuid});

  /// Whether scanning is active
  bool get isScanning => FlutterBluePlus.isScanningNow;

  /// Number of connected peripherals
  int get connectedCount => _connected.length;

  /// Get connected peers sorted by RSSI (strongest signal first)
  List<ConnectedPeer> get connectedPeers {
    final peers = _connected.values.toList();
    peers.sort((a, b) => b.rssi.compareTo(a.rssi));
    return peers;
  }

  /// Initialize the central service
  Future<void> initialize() async {
    debugPrint('Initializing BLE central service');

    // Check if Bluetooth is available
    if (!await FlutterBluePlus.isSupported) {
      throw UnsupportedError('Bluetooth not supported on this device');
    }

    // Wait for Bluetooth to be on
    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) {
      debugPrint('Bluetooth is not on: $state');
      // Could prompt user to enable Bluetooth
    }

    debugPrint('BLE central initialized');
  }

  /// Start scanning for peers
  Future<void> startScan({Duration? timeout}) async {
    if (isScanning) {
      debugPrint('Already scanning, ignoring startScan call');
      return;
    }

    try {
      // Cancel previous scan subscription to prevent duplicate callbacks
      if (_scanSubscription != null) {
        await _scanSubscription!.cancel();
        _subscriptions.remove(_scanSubscription);
        _scanSubscription = null;
      }

      // Listen for scan results
      _scanSubscription = FlutterBluePlus.scanResults.listen(_onScanResults);
      _subscriptions.add(_scanSubscription!);

      // Start scanning
      // Note: We scan for all devices and filter manually because
      // some platforms have issues with service UUID filtering
      await FlutterBluePlus.startScan(
        timeout: timeout ?? scanTimeout,
        androidScanMode: AndroidScanMode.lowLatency,
      );

      // Wait for scan to actually complete by listening to isScanning stream
      await FlutterBluePlus.isScanning.firstWhere((scanning) => !scanning);
    } catch (e) {
      debugPrint('Failed to start scan: $e');
      rethrow;
    }
  }

  /// Stop scanning
  Future<void> stopScan() async {
    if (!isScanning) return;

    await FlutterBluePlus.stopScan();
    debugPrint('Scan stopped');
  }

  /// Connect to a device by its ID.
  ///
  /// Uses [BluetoothDevice.fromId] to obtain the device handle — no local
  /// discovery cache is needed because Redux is the single source of truth
  /// for discovery state.
  ///
  /// After connecting, searches ALL GATT services for the Bitchat characteristic
  /// UUID (0000ff01-...). This correctly identifies Bitchat peers regardless of
  /// their advertised service UUID.
  Future<bool> connectToDevice(String deviceId) async {
    if (_connected.containsKey(deviceId)) {
      return true;
    }

    try {
      final device = BluetoothDevice.fromId(deviceId);

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

      // Search ALL services for the Bitchat characteristic UUID.
      // Per architecture: we can't know if a device is a Bitchat peer until
      // after connection and service discovery. The characteristic UUID is
      // fixed across all Bitchat peers.
      final shortCharUuid = characteristicUuid.substring(4, 8).toLowerCase(); // "ff01"
      BluetoothCharacteristic? targetChar;
      for (final service in services) {
        for (final char in service.characteristics) {
          final charUuidStr = char.uuid.toString().toLowerCase();
          if (charUuidStr == characteristicUuid.toLowerCase() ||
              charUuidStr == shortCharUuid) {
            targetChar = char;
            break;
          }
        }
        if (targetChar != null) break;
      }

      if (targetChar == null) {
        // Not a Bitchat peer (e.g., headphones, smartwatch)
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

      // Store connection (RSSI defaults to -100, will be updated on next scan)
      _connected[deviceId] = ConnectedPeer(
        deviceId: deviceId,
        device: device,
        characteristic: targetChar,
        rssi: -100,
      );

      onConnectionChanged?.call(deviceId, true);

      return true;
    } catch (e) {
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
      // debugPrint('Error disconnecting from $deviceId: $e');
    }

    _onDeviceDisconnected(deviceId);
  }

  /// Disconnect from all connected devices
  Future<void> disconnectAll() async {
    debugPrint('Disconnecting all ${_connected.length} connected devices');

    // Clear callbacks first to stop receiving data
    // This prevents processing packets after BLE is disabled
    onDataReceived = null;
    onConnectionChanged = null;
    onDeviceDiscovered = null;

    if (_connected.isEmpty) return;

    final deviceIds = _connected.keys.toList();
    for (final deviceId in deviceIds) {
      await disconnectFromDevice(deviceId);
    }
  }

  /// Send data to a connected peripheral.
  /// Uses write-without-response to avoid GATT busy errors from queued writes.
  ///
  /// On iOS, CoreBluetooth can invalidate GATT service handles between
  /// discoverServices() and a later write(). If the write fails, we
  /// re-discover services to get a fresh characteristic handle and retry once.
  Future<bool> sendData(String deviceId, Uint8List data) async {
    final peer = _connected[deviceId];
    if (peer == null) {
      debugPrint('Cannot send to disconnected device: $deviceId');
      return false;
    }

    try {
      await peer.characteristic.write(data, withoutResponse: true);
      peer.lastActivity = DateTime.now();
      return true;
    } catch (e) {
      debugPrint('Write failed for $deviceId, refreshing GATT services: $e');

      // Re-discover services to get a fresh characteristic handle.
      // iOS can invalidate the old handle between connection and first write.
      final freshChar = await _refreshCharacteristic(peer);
      if (freshChar == null) {
        debugPrint('Service refresh failed for $deviceId, disconnecting');
        _connected.remove(deviceId);
        onConnectionChanged?.call(deviceId, false);
        return false;
      }

      // Retry once with the fresh handle.
      try {
        peer.characteristic = freshChar;
        await freshChar.write(data, withoutResponse: true);
        peer.lastActivity = DateTime.now();
        debugPrint('Retry write succeeded for $deviceId after service refresh');
        return true;
      } catch (retryError) {
        debugPrint('Retry write also failed for $deviceId, disconnecting');
        _connected.remove(deviceId);
        onConnectionChanged?.call(deviceId, false);
        return false;
      }
    }
  }

  /// Re-discover GATT services on a connected device and return a fresh
  /// characteristic handle, or null if the service/characteristic is gone.
  Future<BluetoothCharacteristic?> _refreshCharacteristic(
      ConnectedPeer peer) async {
    try {
      final services = await peer.device.discoverServices();
      final shortCharUuid =
          characteristicUuid.substring(4, 8).toLowerCase(); // "ff01"
      for (final service in services) {
        for (final char in service.characteristics) {
          final charUuidStr = char.uuid.toString().toLowerCase();
          if (charUuidStr == characteristicUuid.toLowerCase() ||
              charUuidStr == shortCharUuid) {
            return char;
          }
        }
      }
      return null;
    } catch (e) {
      debugPrint('Failed to refresh services for ${peer.deviceId}: $e');
      return null;
    }
  }

  /// Send data to all connected peripherals (sorted by signal strength)
  Future<void> broadcastData(Uint8List data, {Set<String>? excludeDevices}) async {
    // Sort by RSSI descending (strongest signal first)
    final peers = _connected.values.toList();
    peers.sort((a, b) => b.rssi.compareTo(a.rssi));

    for (final peer in peers) {
      if (excludeDevices != null && excludeDevices.contains(peer.deviceId)) continue;
      await sendData(peer.deviceId, data);
    }
  }

  // ===== Event handlers =====
  // Filter by Grassroots UUID prefix to only discover Grassroots devices.
  // Each device advertises a UUID starting with a static 8-byte prefix
  // (first 8 bytes of SHA-256("grassroots")), followed by 8 bytes from their pubkey.
  Guid? findGrassrootsService(List<Guid> serviceUuids) {
    return serviceUuids.firstWhereOrNull(
      (uuid) {
        final uuidStr = uuid.toString().toLowerCase();
        final uuidHex = uuidStr.replaceAll('-', '');
        return uuidHex.startsWith(BitchatIdentity.grassrootsUuidPrefix);
      });
  }
  bool isGrassrootsDevice(ScanResult result) {
    if (result.advertisementData.serviceUuids.isEmpty) return false;

    final grassrootsService = findGrassrootsService(result.advertisementData.serviceUuids);
    return grassrootsService != null;
  }

  void _onScanResults(List<ScanResult> results) {
    for (final result in results) {
      final isGrassrootsPeer = isGrassrootsDevice(result);
      if (isGrassrootsPeer) {
        final deviceId = result.device.remoteId.str;
        final uuidStr = findGrassrootsService(result.advertisementData.serviceUuids)!.toString().toLowerCase();

        onDeviceDiscovered?.call(DiscoveredDevice(
          deviceId: deviceId,
          name: result.advertisementData.advName,
          serviceUuid: uuidStr,
          rssi: result.rssi,
        ));

      }
    }
  }

  void _onDataReceived(String deviceId, Uint8List data) {
    debugPrint('Data received from $deviceId: ${data.length} bytes');

    final peer = _connected[deviceId];
    if (peer != null) {
      peer.lastActivity = DateTime.now();
      // Pass RSSI along with the data
      onDataReceived?.call(deviceId, data, peer.rssi);
    } else {
      debugPrint('Data received from unknown device: $deviceId');
    }
  }

  void _onDeviceDisconnected(String deviceId) {
    _connected.remove(deviceId);
    debugPrint('Disconnected from: $deviceId');
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
  }
}
