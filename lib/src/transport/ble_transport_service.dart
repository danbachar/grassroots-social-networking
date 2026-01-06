import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

import '../transport/transport_service.dart';
import '../ble/ble_central_service.dart';
import '../ble/ble_peripheral_service.dart';

/// Default display info for BLE transport
const _defaultBleDisplayInfo = TransportDisplayInfo(
  icon: Icons.bluetooth,
  name: 'Bluetooth',
  description: 'Bluetooth Low Energy mesh transport',
  color: Colors.blue,
);

/// BLE-based implementation of the transport service.
/// 
/// Combines Central (scanner) and Peripheral (advertiser) roles to create
/// a mesh-capable BLE transport layer. Devices can both discover and be
/// discovered by other mesh participants.
/// 
/// ## BLE Mesh Architecture
/// 
/// Each device runs both modes simultaneously:
/// - **Peripheral mode**: Advertises presence, accepts incoming connections
/// - **Central mode**: Scans for peers, initiates outgoing connections
/// 
/// This dual-role approach maximizes connectivity in the mesh.
class BleTransportService extends TransportService with TransportServiceMixin {
  final Logger _log = Logger();

  /// BLE Service UUID (typically derived from user's public key)
  final String serviceUuid;

  /// Local device name for advertising
  final String? localName;

  /// Central service (scanner/connector)
  late final BleCentralService _central;

  /// Peripheral service (advertiser)
  late final BlePeripheralService _peripheral;

  /// Current transport state
  TransportState _state = TransportState.uninitialized;

  /// Known peers on this transport
  final Map<String, TransportPeer> _peers = {};

  /// Stream controllers
  final _stateController = StreamController<TransportState>.broadcast();
  final _dataController = StreamController<TransportDataEvent>.broadcast();
  final _connectionController = StreamController<TransportConnectionEvent>.broadcast();
  final _discoveryController = StreamController<TransportDiscoveryEvent>.broadcast();

  BleTransportService({
    required this.serviceUuid,
    this.localName,
  }) {
    _central = BleCentralService(serviceUuid: serviceUuid);
    _peripheral = BlePeripheralService(serviceUuid: serviceUuid);
  }

  // ===== TransportService Implementation =====

  @override
  TransportType get type => TransportType.ble;

  @override
  TransportDisplayInfo get displayInfo => _defaultBleDisplayInfo;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportState> get stateStream => _stateController.stream;

  @override
  Stream<TransportDataEvent> get dataStream => _dataController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionStream =>
      _connectionController.stream;

  @override
  Stream<TransportDiscoveryEvent> get discoveryStream =>
      _discoveryController.stream;

  @override
  List<TransportPeer> get peers => _peers.values.toList();

  @override
  List<TransportPeer> get connectedPeers =>
      _peers.values.where((p) => _isConnected(p.peerId)).toList();

  @override
  int get connectedCount =>
      _central.connectedCount + _peripheral.connectedCount;

  @override
  bool get isActive =>
      _state == TransportState.active &&
      (_central.isScanning || _peripheral.isAdvertising);

  @override
  Future<bool> initialize() async {
    if (_state != TransportState.uninitialized) {
      _log.w('BLE transport already initialized');
      return _state == TransportState.ready || _state == TransportState.active;
    }

    _setState(TransportState.initializing);
    _log.i('Initializing BLE transport service');

    try {
      // Set up central callbacks
      _central.onDataReceived = _onCentralDataReceived;
      _central.onConnectionChanged = _onCentralConnectionChanged;
      _central.onDeviceDiscovered = _onDeviceDiscovered;

      // Set up peripheral callbacks
      _peripheral.onDataReceived = _onPeripheralDataReceived;
      _peripheral.onConnectionChanged = _onPeripheralConnectionChanged;

      // Initialize both services
      await _central.initialize();
      await _peripheral.initialize();

      _setState(TransportState.ready);
      _log.i('BLE transport initialized successfully');
      return true;
    } catch (e) {
      _log.e('Failed to initialize BLE transport: $e');
      _setState(TransportState.error);
      return false;
    }
  }

  @override
  Future<void> start() async {
    if (_state != TransportState.ready && _state != TransportState.active) {
      _log.w('Cannot start BLE transport in state: $_state');
      return;
    }

    _log.i('Starting BLE transport');

    // Start advertising first (so others can find us)
    await _peripheral.startAdvertising(localName: localName);

    // Then start scanning (to find others)
    await _central.startScan();

    _setState(TransportState.active);
    _log.i('BLE transport started');
  }

  @override
  Future<void> stop() async {
    _log.i('Stopping BLE transport');

    await _central.stopScan();
    await _peripheral.stopAdvertising();

    if (_state == TransportState.active) {
      _setState(TransportState.ready);
    }

    _log.i('BLE transport stopped');
  }

  @override
  Future<bool> connectToPeer(String peerId) async {
    _log.d('Connecting to peer: $peerId');
    return await _central.connectToDevice(peerId);
  }

  @override
  Future<void> disconnectFromPeer(String peerId) async {
    _log.d('Disconnecting from peer: $peerId');
    await _central.disconnectFromDevice(peerId);
  }

  @override
  Future<bool> sendToPeer(String peerId, Uint8List data) async {
    // Try central first (we initiated connection)
    if (await _central.sendData(peerId, data)) {
      return true;
    }

    // Try peripheral (they initiated connection)
    return await _peripheral.sendData(peerId, data);
  }

  @override
  Future<void> broadcast(Uint8List data, {String? excludePeerId}) async {
    await _central.broadcastData(data, excludeDevice: excludePeerId);
    await _peripheral.broadcastData(data, excludeDevice: excludePeerId);
  }

  @override
  void associatePeerWithPubkey(String peerId, Uint8List pubkey) {
    associatePeerWithPubkeyImpl(peerId, pubkey);

    // Update the peer object if it exists
    final peer = _peers[peerId];
    if (peer != null) {
      peer.publicKey = pubkey;
    }

    _log.d('Associated peer $peerId with pubkey');
  }

  @override
  String? getPeerIdForPubkey(Uint8List pubkey) => getPeerIdForPubkeyImpl(pubkey);

  @override
  Uint8List? getPubkeyForPeerId(String peerId) => getPubkeyForPeerIdImpl(peerId);

  @override
  Future<void> dispose() async {
    _log.i('Disposing BLE transport');

    await stop();
    await _central.dispose();
    await _peripheral.dispose();

    clearPubkeyAssociations();
    _peers.clear();

    await _stateController.close();
    await _dataController.close();
    await _connectionController.close();
    await _discoveryController.close();

    _setState(TransportState.disposed);
  }

  // ===== BLE-Specific Methods =====

  /// Start scanning for a specific duration
  Future<void> startScan({Duration? timeout}) async {
    await _central.startScan(timeout: timeout);
  }

  /// Get the underlying central service (for advanced use)
  BleCentralService get centralService => _central;

  /// Get the underlying peripheral service (for advanced use)
  BlePeripheralService get peripheralService => _peripheral;

  // ===== Internal Callbacks =====

  void _onCentralDataReceived(String deviceId, Uint8List data, int rssi) {
    _updatePeerLastSeen(deviceId);
    _dataController.add(TransportDataEvent(
      peerId: deviceId,
      transport: TransportType.ble,
      data: data,
    ));
  }

  void _onPeripheralDataReceived(String deviceId, Uint8List data, int rssi) {
    _updatePeerLastSeen(deviceId);
    _dataController.add(TransportDataEvent(
      peerId: deviceId,
      transport: TransportType.ble,
      data: data,
    ));
  }

  void _onCentralConnectionChanged(String deviceId, bool connected) {
    _handleConnectionChange(deviceId, connected, isCentral: true);
  }

  void _onPeripheralConnectionChanged(String deviceId, bool connected) {
    _handleConnectionChange(deviceId, connected, isCentral: false);
  }

  void _onDeviceDiscovered(DiscoveredDevice device) {
    final isNew = !_peers.containsKey(device.deviceId);

    final peer = _getOrCreatePeer(device.deviceId);
    peer.displayName = device.name;
    peer.signalQuality = _rssiToQuality(device.rssi);
    peer.metadata['rssi'] = device.rssi;
    peer.metadata['bleDevice'] = device;
    peer.lastSeen = DateTime.now();

    _discoveryController.add(TransportDiscoveryEvent(
      peer: peer,
      isNew: isNew,
    ));
  }

  void _handleConnectionChange(String deviceId, bool connected,
      {required bool isCentral}) {
    if (connected) {
      _getOrCreatePeer(deviceId);
      _log.i('Peer connected: $deviceId (via ${isCentral ? "central" : "peripheral"})');
    } else {
      removePeerPubkeyAssociation(deviceId);
      _log.i('Peer disconnected: $deviceId');
    }

    _connectionController.add(TransportConnectionEvent(
      peerId: deviceId,
      transport: TransportType.ble,
      connected: connected,
      reason: isCentral ? 'central' : 'peripheral',
    ));
  }

  // ===== Helpers =====

  void _setState(TransportState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  TransportPeer _getOrCreatePeer(String peerId) {
    return _peers.putIfAbsent(
      peerId,
      () => TransportPeer(
        peerId: peerId,
        transport: TransportType.ble,
      ),
    );
  }

  void _updatePeerLastSeen(String peerId) {
    final peer = _peers[peerId];
    if (peer != null) {
      peer.lastSeen = DateTime.now();
    }
  }

  bool _isConnected(String peerId) {
    // Check both central and peripheral connections
    final centralConnected = _central.connectedPeers
        .any((p) => p.deviceId == peerId);
    final peripheralConnected = _peripheral.connectedCount > 0;
    // Note: peripheral doesn't expose device IDs easily, 
    // so we rely on the connection event tracking
    return centralConnected || peripheralConnected;
  }

  double _rssiToQuality(int rssi) {
    // Map RSSI (-100 to -30 dBm typical) to quality (0.0 to 1.0)
    const minRssi = -100;
    const maxRssi = -30;
    final clamped = rssi.clamp(minRssi, maxRssi);
    return (clamped - minRssi) / (maxRssi - minRssi);
  }
}
