import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:redux/redux.dart';

import '../transport/transport_service.dart';
import '../ble/ble_central_service.dart';
import '../ble/ble_peripheral_service.dart';
import '../models/identity.dart';
import '../models/packet.dart';
import '../models/peer.dart';
import '../store/store.dart';

/// Default display info for BLE transport
const _defaultBleDisplayInfo = TransportDisplayInfo(
  icon: Icons.bluetooth,
  name: 'Bluetooth',
  description: 'Bluetooth Low Energy direct P2P transport',
  color: Colors.blue,
);

/// BLE-based implementation of the transport service.
///
/// Provides direct peer-to-peer communication over Bluetooth Low Energy.
/// Each device runs both Central (scanner) and Peripheral (advertiser) modes
/// to maximize connectivity.
///
/// ## Architecture
///
/// - **Peripheral mode**: Advertises presence, accepts incoming connections
/// - **Central mode**: Scans for peers, initiates outgoing connections
///
/// ## IMPORTANT: No Mesh/Forwarding
///
/// This is a **direct P2P transport only**:
/// - Messages are sent directly to recipients
/// - NO relaying/forwarding through intermediate peers
/// - NO store-and-forward for offline peers
/// - All routing/forwarding logic belongs in the GSG layer above
class BleTransportService extends TransportService {
  final Logger _log = Logger();

  /// BLE Service UUID (derived from user's public key)
  final String serviceUuid;

  /// Local device name for advertising
  final String? localName;

  /// Our identity
  final BitchatIdentity identity;

  /// Redux store for state management
  final Store<AppState> store;

  /// Central service (scanner/connector)
  late final BleCentralService _central;

  /// Peripheral service (advertiser)
  late final BlePeripheralService _peripheral;

  /// Flag to block packet processing after stop() is called
  /// This prevents race conditions where packets were already in the event queue
  bool _stopped = false;

  /// Stream controllers
  final _dataController = StreamController<TransportDataEvent>.broadcast();
  final _connectionController = StreamController<TransportConnectionEvent>.broadcast();

  // ===== Public callbacks =====

  /// Called when a BLE packet is deserialized and ready for routing.
  /// The coordinator wires this to MessageRouter.processPacket().
  void Function(BitchatPacket packet, {String? bleDeviceId, int rssi, BleRole? bleRole})?
      onBlePacketReceived;

  /// Called when a peer disconnects at the BLE level.
  void Function(Peer peer)? onPeerDisconnected;

  // ===== Convenience getters for Redux state =====

  /// Get peers state from Redux store
  PeersState get _peersState => store.state.peers;

  BleTransportService({
    required this.serviceUuid,
    required this.identity,
    required this.store,
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
  TransportState get state => store.state.transports.bleState;

  @override
  Stream<TransportDataEvent> get dataStream => _dataController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionStream => _connectionController.stream;

  @override
  int get connectedCount => _central.connectedCount + _peripheral.connectedCount;

  @override
  bool get isActive =>
      store.state.transports.bleState == TransportState.active &&
      (_central.isScanning || _peripheral.isAdvertising);

  /// Whether currently scanning for devices
  bool get isScanning => _central.isScanning;

  /// Get all known peers from Redux store
  List<PeerState> get knownPeers => _peersState.peersList;

  /// Get connected peers from Redux store
  List<PeerState> get connectedKnownPeers => _peersState.connectedPeers;

  /// Check if a peer is reachable
  bool isPeerReachable(Uint8List pubkey) => _peersState.isPeerReachable(pubkey);

  /// Get peer by public key
  PeerState? getPeer(Uint8List pubkey) => _peersState.getPeerByPubkey(pubkey);

  /// Get all discovered BLE peers (before ANNOUNCE)
  List<DiscoveredPeerState> get discoveredPeers => _peersState.discoveredBlePeersList;

  // ===== Lifecycle =====

  @override
  Future<bool> initialize() async {
    if (state != TransportState.uninitialized) {
      _log.w('BLE transport already initialized');
      return state == TransportState.ready || state == TransportState.active;
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
    if (state != TransportState.ready && state != TransportState.active) {
      _log.w('Cannot start BLE transport in state: $state');
      return;
    }

    _log.i('Starting BLE transport');

    // Clear stopped flag to allow packet processing
    _stopped = false;

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

    // Set stopped flag FIRST to block any packets in the event queue
    _stopped = true;

    // Stop scanning for new devices
    await _central.stopScan();

    // Disconnect all connected devices explicitly
    await _central.disconnectAll();

    // Stop advertising and disconnect all centrals
    await _peripheral.stopAdvertising();

    if (state == TransportState.active) {
      _setState(TransportState.ready);
    }

    _log.i('BLE transport stopped');
  }

  /// Trigger a new scan for peers
  Future<void> scan({Duration? timeout}) async {
    await _central.startScan(timeout: timeout);
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
    // Dispatch action to associate the device with pubkey in Redux store
    // Redux store is the single source of truth
    // Note: role is determined by the caller (central or peripheral callback)
    store.dispatch(AssociateBleDeviceAction(publicKey: pubkey, deviceId: peerId, role: BleRole.central));
  }

  @override
  String? getPeerIdForPubkey(Uint8List pubkey) {
    // Look up in Redux store — prefer central ID (tried first by sendToPeer)
    final peer = store.state.peers.getPeerByPubkey(pubkey);
    return peer?.bleDeviceId;
  }

  @override
  Uint8List? getPubkeyForPeerId(String peerId) {
    // Look up in Redux store - find peer with matching BLE device ID (either role)
    for (final peer in store.state.peers.peersList) {
      if (peer.bleCentralDeviceId == peerId || peer.blePeripheralDeviceId == peerId) {
        return peer.publicKey;
      }
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    _log.i('Disposing BLE transport');

    await stop();
    await _central.dispose();
    await _peripheral.dispose();

    _setState(TransportState.disposed);

    await _dataController.close();
    await _connectionController.close();
  }

  /// Process an incoming raw BLE packet.
  ///
  /// Deserializes and forwards to the MessageRouter via [onBlePacketReceived].
  /// The router handles dedup, ANNOUNCE processing, message targeting, etc.
  void onPacketReceived(Uint8List data, {String? fromDeviceId, required int rssi, BleRole? bleRole}) {
    // Block processing if BLE has been stopped
    if (_stopped) {
      _log.d('Ignoring packet received after BLE stopped');
      return;
    }

    try {
      final packet = BitchatPacket.deserialize(data);
      onBlePacketReceived?.call(packet, bleDeviceId: fromDeviceId, rssi: rssi, bleRole: bleRole);
    } catch (e) {
      _log.e('Failed to deserialize packet: $e');
    }
  }

  // ===== Peer Management =====

  void onPeerBleConnected(String bleDeviceId, {int? rssi}) {
    _log.d('BLE peer connected: $bleDeviceId');
  }

  void onPeerBleDisconnected(Uint8List pubkey, {BleRole? role}) {
    final peer = _peersState.getPeerByPubkey(pubkey);
    if (peer != null) {
      store.dispatch(PeerBleDisconnectedAction(pubkey, role: role));
      _log.i('Peer disconnected (${role?.name ?? "all"}): ${peer.displayName}');
      onPeerDisconnected?.call(_peerStateToLegacyPeer(peer));
    }
  }

  // ===== BLE Callbacks =====

  void _onCentralDataReceived(String deviceId, Uint8List data, int rssi) {
    onPacketReceived(data, fromDeviceId: deviceId, rssi: rssi, bleRole: BleRole.central);

    _dataController.add(TransportDataEvent(
      peerId: deviceId,
      transport: TransportType.ble,
      data: data,
    ));
  }

  void _onPeripheralDataReceived(String deviceId, Uint8List data, int rssi) {
    onPacketReceived(data, fromDeviceId: deviceId, rssi: rssi, bleRole: BleRole.peripheral);

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
    // Check if this is a new discovery
    final existing = _peersState.getDiscoveredBlePeer(device.deviceId);
    final isNew = existing == null;

    if (isNew) {
      store.dispatch(BleDeviceDiscoveredAction(
        deviceId: device.deviceId,
        displayName: device.name,
        rssi: device.rssi,
        serviceUuid: device.serviceUuid,
      ));
    }

    // Also update RSSI for connected Peers (those who have sent ANNOUNCE)
    final pubkey = getPubkeyForPeerId(device.deviceId);
    if (pubkey != null) {
      store.dispatch(PeerRssiUpdatedAction(publicKey: pubkey, rssi: device.rssi));
    }

    if (!isNew && (existing.isConnected || existing.isConnecting)) return;

    // Check if we're in backoff period
    if (existing != null && existing.isInBackoff) {
      return; // Skip connection attempt — still in backoff
    }

    _autoConnectToPeer(device.deviceId);
  }

  /// Automatically connect to a discovered peer and send ANNOUNCE
  Future<bool> _autoConnectToPeer(String deviceId) async {
    // Skip if already connected
    if (_isConnected(deviceId)) {
      return false;
    }

    // Skip if already connecting
    final discovered = _peersState.getDiscoveredBlePeer(deviceId);
    if (discovered?.isConnecting == true) {
      return false;
    }

    // Mark as connecting in store
    store.dispatch(BleDeviceConnectingAction(deviceId));

    try {
      final success = await _central.connectToDevice(deviceId);

      if (success) {
        _log.i('Successfully connected to $deviceId');
        store.dispatch(BleDeviceConnectedAction(deviceId));
        return true;
      } else {
        store.dispatch(BleDeviceConnectionFailedAction(deviceId, error: 'Connection failed'));
        return false;
      }
    } catch (e) {
      store.dispatch(BleDeviceConnectionFailedAction(deviceId, error: e.toString()));
      return false;
    }
  }

  void _handleConnectionChange(String deviceId, bool connected, {required bool isCentral}) {
    final role = isCentral ? BleRole.central : BleRole.peripheral;

    if (connected) {
      store.dispatch(BleDeviceConnectedAction(deviceId));
    } else {
      store.dispatch(BleDeviceDisconnectedAction(deviceId));
      final pubkey = getPubkeyForPeerId(deviceId);
      if (pubkey != null) {
        onPeerBleDisconnected(pubkey, role: role);
      }
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
    if (store.state.transports.bleState != newState) {
      store.dispatch(BleTransportStateChangedAction(newState));
    }
  }

  bool _isConnected(String peerId) {
    final centralConnected = _central.connectedPeers.any((p) => p.deviceId == peerId);
    final peripheralConnected = _peripheral.isDeviceConnected(peerId);
    return centralConnected || peripheralConnected;
  }

  /// Convert PeerState to Peer for callbacks
  Peer _peerStateToLegacyPeer(PeerState state) {
    return Peer(
      publicKey: state.publicKey,
      nickname: state.nickname,
      connectionState: state.connectionState,
      transport: state.transport,
      bleDeviceId: state.bleDeviceId,
      libp2pAddress: state.libp2pAddress,
      rssi: state.rssi,
      protocolVersion: state.protocolVersion,
    );
  }
}
