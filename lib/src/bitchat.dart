import 'dart:async';
import 'dart:typed_data';
import 'package:logger/logger.dart';
import 'package:redux/redux.dart';
import 'package:uuid/uuid.dart';
import 'ble/permission_handler.dart';
import 'transport/ble_transport_service.dart';
import 'transport/libp2p_transport_service.dart';
import 'models/identity.dart';
import 'models/peer.dart';
import 'models/packet.dart';
import 'protocol/protocol_handler.dart';
import 'routing/message_router.dart';
import 'store/store.dart';

/// Transport status
enum TransportStatus {
  /// Not initialized
  uninitialized,
  
  /// Permissions not granted
  permissionDenied,
  
  /// Initializing
  initializing,
  
  /// Ready but not active
  ready,
  
  /// Actively scanning/advertising
  active,
  
  /// Error state
  error,
}

/// Configuration for Bitchat transport
class BitchatConfig {
  /// Whether to auto-connect to discovered peers
  final bool autoConnect;
  
  /// Whether to start scanning/advertising on init
  final bool autoStart;
  
  /// Scan duration (null for continuous)
  final Duration? scanDuration;

  /// Local name for BLE advertising
  final String? localName;
  
  /// Interval for sending periodic ANNOUNCE packets
  final Duration announceInterval;
  
  /// Interval for periodic BLE scanning (to discover new devices)
  final Duration scanInterval;
  
  /// Whether to enable BLE transport (can be overridden by TransportSettingsStore)
  final bool enableBle;
  
  /// Whether to enable libp2p transport (can be overridden by TransportSettingsStore)
  final bool enableLibp2p;
  
  const BitchatConfig({
    this.autoConnect = true,
    this.autoStart = true,
    this.scanDuration,
    this.localName,
    this.announceInterval = const Duration(seconds: 10),
    this.scanInterval = const Duration(seconds: 10),
    this.enableBle = true,
    this.enableLibp2p = true,
  });
}

/// Main Bitchat transport API.
/// 
/// This is the entry point for GSG to use Bitchat as a transport layer.
/// 
/// Usage:
/// ```dart
/// final identity = BitchatIdentity(
///   publicKey: myPubKey,
///   privateKey: myPrivKey,
///   nickname: 'Alice',
/// );
/// 
/// final bitchat = Bitchat(identity: identity);
/// 
/// bitchat.onMessageReceived = (senderPubkey, payload) {
///   // Handle incoming GSG block
/// };
/// 
/// bitchat.onPeerConnected = (peer) {
///   // Send ANNOUNCE, start cordial dissemination
/// };
/// 
/// await bitchat.initialize();
/// await bitchat.start();
/// 
/// // Send a message
/// await bitchat.send(recipientPubkey, gsgBlockData);
/// ```
class Bitchat {
  final Logger _log = Logger();
  
  /// Our identity (from GSG layer)
  final BitchatIdentity identity;
  
  /// Configuration
  final BitchatConfig config;

  /// Redux store for app state
  final Store<AppState> store;

  /// Subscription for listening to store changes
  StreamSubscription<AppState>? _storeSubscription;

  /// Last known settings state for detecting changes
  SettingsState? _lastSettingsState;
  
  /// Permission handler
  final PermissionHandler _permissions = PermissionHandler();
  
  /// BLE transport service (null if BLE is disabled or unavailable)
  BleTransportService? _bleService;
  
  /// LibP2P transport service (null if libp2p is disabled)
  LibP2PTransportService? _libp2pService;

  /// Timer for periodic ANNOUNCE broadcasts
  Timer? _announceTimer;
  
  /// Timer for periodic BLE scanning
  Timer? _scanTimer;
  
  /// Current transport status
  TransportStatus _status = TransportStatus.uninitialized;
  
  /// Stream controller for status changes
  final _statusController = StreamController<TransportStatus>.broadcast();
  
  /// Whether BLE transport is available and enabled
  bool _bleAvailable = false;
  
  /// Whether libp2p transport is available and enabled
  bool _libp2pAvailable = false;

  /// Peers currently being connected to via libp2p (guards against concurrent attempts)
  final _pendingLibp2pConnections = <String>{};

  /// Protocol handler for encoding/decoding packets
  late final ProtocolHandler _protocolHandler;

  /// Message router for incoming packet processing
  late final MessageRouter _messageRouter;

  // ===== Public callbacks =====

  /// Called when an application message is received.
  /// Parameters: messageId, senderPubkey, payload (raw GSG block data)
  void Function(String messageId, Uint8List senderPubkey, Uint8List payload)?
      onMessageReceived;
  
  /// Called when a new peer connects and exchanges ANNOUNCE
  void Function(Peer peer)? onPeerConnected;
  
  /// Called when an existing peer sends an ANNOUNCE update
  void Function(Peer peer)? onPeerUpdated;
  
  /// Called when a peer disconnects
  void Function(Peer peer)? onPeerDisconnected;
  
  /// Called when transport status changes
  void Function(TransportStatus status)? onStatusChanged;

  /// Called when libp2p transport becomes available
  void Function()? onLibp2pInitialized;

  // ===== Convenience accessors for Redux state =====
  
  PeersState get _peersState => store.state.peers;
  
  Bitchat({
    required this.identity,
    this.config = const BitchatConfig(),
    required this.store,
  }) {
    _protocolHandler = ProtocolHandler(identity: identity);
    _messageRouter = MessageRouter(
      identity: identity,
      store: store,
      protocolHandler: _protocolHandler,
    );
    _setupRouterCallbacks();

    // Listen to Redux store changes for settings updates
    _lastSettingsState = store.state.settings;
    _storeSubscription = store.onChange.listen((state) {
      if (state.settings != _lastSettingsState) {
        _lastSettingsState = state.settings;
        _onTransportSettingsChanged();
      }
    });
  }
  
  /// Current transport status
  TransportStatus get status => _status;
  
  /// Stream of status changes
  Stream<TransportStatus> get statusStream => _statusController.stream;
  
  /// All known peers - from Redux store
  List<PeerState> get peers => _peersState.peersList;
  
  /// Connected peers only - from Redux store
  List<PeerState> get connectedPeers => _peersState.connectedPeers;
  
  /// Check if a peer is reachable via any transport
  bool isPeerReachable(Uint8List pubkey) => _peersState.isPeerReachable(pubkey);
  
  /// Get peer by public key - from Redux store
  PeerState? getPeer(Uint8List pubkey) => _peersState.getPeerByPubkey(pubkey);
  
  /// Get latest RSSI for a peer (BLE only)
  int? getRssiForPeer(Uint8List pubkey) {
    final peer = _peersState.getPeerByPubkey(pubkey);
    return peer?.rssi;
  }
  
  /// Whether BLE is currently enabled and available
  bool get isBleEnabled => _bleAvailable && _isBleEnabledInSettings;
  
  /// Whether libp2p is currently enabled and available  
  bool get isLibp2pEnabled => _libp2pAvailable && _isLibp2pEnabledInSettings;
  
  /// Whether currently scanning for BLE devices
  bool get isScanning => _bleService?.isScanning ?? false;

  /// Get the libp2p host ID (PeerId) - null if not initialized
  String? get libp2pHostId => _libp2pService?.hostId;

  /// Get the libp2p host addresses - empty if not initialized
  List<String> get libp2pHostAddrs => _libp2pService?.hostAddrs ?? [];

  /// Routable public multiaddr (public IPv6 + listen port) - null if unavailable
  String? get publicLibp2pMultiaddr => _libp2pService?.publicMultiaddr;

  /// Re-fetch the public IPv6 address (call after network connectivity changes)
  Future<void> refreshLibp2pAddress() async {
    await _libp2pService?.refreshPublicAddress();
  }

  /// Connect to a libp2p peer using their host info
  /// Used when accepting a friend request or receiving acceptance
  /// Returns the successful address on success, null on failure
  Future<String?> connectToLibp2pHost({required String hostId, required List<String> hostAddrs}) async {
    if (_libp2pService == null) {
      _log.w('Cannot connect: libp2p service not initialized');
      return null;
    }
    return await _libp2pService!.connectToHost(hostId: hostId, hostAddrs: hostAddrs);
  }

  bool get _isBleEnabledInSettings =>
      store.state.settings.bluetoothEnabled;

  bool get _isLibp2pEnabledInSettings =>
      store.state.settings.libp2pEnabled;
  
  // ===== Lifecycle =====
  
  /// Initialize the transport layer.
  /// 
  /// This will:
  /// 1. Request required permissions
  /// 2. Initialize enabled transports (BLE and/or libp2p)
  /// 3. Set up routing
  /// 
  /// Call [start] after this to begin scanning/advertising.
  Future<bool> initialize() async {
    if (_status != TransportStatus.uninitialized) {
      _log.w('Already initialized');
      return _status == TransportStatus.ready || _status == TransportStatus.active;
    }
    
    _setStatus(TransportStatus.initializing);
    _log.i('Initializing Bitchat transport');
    
    bool anyTransportInitialized = false;
    
    try {
      // Initialize BLE if enabled
      if (_isBleEnabledInSettings) {
        anyTransportInitialized = await _initializeBle() || anyTransportInitialized;
      }
      
      // Initialize libp2p if enabled
      if (_isLibp2pEnabledInSettings) {
        anyTransportInitialized = await _initializeLibp2p() || anyTransportInitialized;
      }
      
      if (!anyTransportInitialized) {
        _log.e('No transports could be initialized');
        _setStatus(TransportStatus.error);
        return false;
      }
      
      _setStatus(TransportStatus.ready);
      _log.i('Bitchat transport initialized (BLE: $_bleAvailable, libp2p: $_libp2pAvailable)');
      
      // Auto-start if configured
      if (config.autoStart) {
        await start();
      }
      
      return true;
    } catch (e) {
      _log.e('Failed to initialize: $e');
      _setStatus(TransportStatus.error);
      return false;
    }
  }
  
  /// Initialize BLE transport
  Future<bool> _initializeBle() async {
    try {
      _log.i('Initializing BLE transport');
      
      // Request BLE permissions
      final permResult = await _permissions.requestPermissions();
      if (permResult != PermissionResult.granted) {
        _log.e('BLE permissions not granted: $permResult');
        return false;
      }
      
      // Create BLE transport service (manages BLE manager + router)
      _bleService = BleTransportService(
        serviceUuid: identity.bleServiceUuid,
        identity: identity,
        store: store,
        localName: config.localName ?? identity.nickname,
      );
      
      // Initialize the service
      final success = await _bleService!.initialize();
      if (!success) {
        _log.w('BLE service initialization returned false');
        _bleAvailable = false;
        _bleService = null;
        return false;
      }
      
      // Wire up callbacks
      _setupBleServiceCallbacks();
      
      _bleAvailable = true;
      _log.i('BLE transport initialized successfully');
      return true;
    } catch (e, stack) {
      _log.e('Failed to initialize BLE transport: $e');
      _log.d('Stack trace: $stack');
      _bleAvailable = false;
      _bleService = null;
      return false;
    }
  }
  
  /// Initialize libp2p transport
  Future<bool> _initializeLibp2p() async {
    try {
      _log.i('Initializing libp2p transport');
      
      // Create libp2p transport service
      _libp2pService = LibP2PTransportService(
        identity: identity,
        store: store,
        protocolHandler: _protocolHandler,
        config: const LibP2PConfig(enableMdns: true),
      );
      
      // Initialize the service
      final success = await _libp2pService!.initialize();
      if (!success) {
        _log.w('libp2p service initialization returned false');
        _libp2pAvailable = false;
        _libp2pService = null;
        return false;
      }
      
      // Wire up callbacks
      _setupLibp2pServiceCallbacks();

      _libp2pAvailable = true;
      _log.i('libp2p transport initialized successfully');
      onLibp2pInitialized?.call();
      return true;
    } catch (e, stack) {
      _log.e('Failed to initialize libp2p transport: $e');
      _log.d('Stack trace: $stack');
      _libp2pAvailable = false;
      _libp2pService = null;
      return false;
    }
  }
  
  /// Start scanning and advertising.
  Future<void> start() async {
    if (_status != TransportStatus.ready) {
      _log.w('Cannot start: status is $_status');
      return;
    }
    
    _log.i('Starting Bitchat transport');
    
    // Start BLE if available
    if (_bleAvailable && _bleService != null) {
      try {
        await _bleService!.start();
        _log.i('BLE transport started');
      } catch (e) {
        _log.e('Failed to start BLE: $e');
      }
    }
    
    // Start libp2p if available
    if (_libp2pAvailable && _libp2pService != null) {
      try {
        await _libp2pService!.start();
        _log.i('libp2p transport started');
      } catch (e) {
        _log.e('Failed to start libp2p: $e');
      }
    }
    
    _startAnnounceTimer();
    _startScanTimer();
    _setStatus(TransportStatus.active);
  }
  
  /// Stop scanning and advertising.
  Future<void> stop() async {
    if (_status != TransportStatus.active) return;
    
    _log.i('Stopping Bitchat transport');
    _announceTimer?.cancel();
    _announceTimer = null;
    _scanTimer?.cancel();
    _scanTimer = null;
    
    if (_bleService != null) {
      try {
        await _bleService!.stop();
      } catch (e) {
        _log.e('Error stopping BLE: $e');
      }
    }
    
    if (_libp2pService != null) {
      try {
        await _libp2pService!.stop();
      } catch (e) {
        _log.e('Error stopping libp2p: $e');
      }
    }
    
    _setStatus(TransportStatus.ready);
  }
  
  /// Handle transport settings changes
  void _onTransportSettingsChanged() {
    _log.i('Transport settings changed');
    _updateTransportsFromSettings();
  }
  
  /// Update transports based on current settings
  Future<void> _updateTransportsFromSettings() async {
    final wasActive = _status == TransportStatus.active;

    // Handle BLE enable/disable
    if (_isBleEnabledInSettings && !_bleAvailable) {
      // BLE was enabled, try to initialize
      await _initializeBle();
      if (wasActive && _bleAvailable && _bleService != null) {
        await _bleService!.start();
      }
    } else if (!_isBleEnabledInSettings && _bleAvailable) {
      // BLE was disabled, stop it and clean up state
      _log.i('BLE disabled from settings, cleaning up...');

      // Stop the BLE service
      if (_bleService != null) {
        await _bleService!.stop();
      }

      // Mark BLE as unavailable
      _bleAvailable = false;

      // Clear all discovered BLE peers from Redux
      store.dispatch(ClearDiscoveredBlePeersAction());

      // Disconnect all peers that were connected via BLE
      // This clears their bleDeviceId and updates connection state
      for (final peer in _peersState.peersList) {
        if (peer.hasBleConnection) {
          store.dispatch(PeerBleDisconnectedAction(peer.publicKey));
        }
      }

      _log.i('BLE cleanup complete');
    }
    
    // Handle libp2p enable/disable
    if (_isLibp2pEnabledInSettings && !_libp2pAvailable) {
      // libp2p was enabled, try to initialize
      await _initializeLibp2p();
      if (wasActive && _libp2pAvailable && _libp2pService != null) {
        await _libp2pService!.start();
      }
    } else if (!_isLibp2pEnabledInSettings && _libp2pAvailable) {
      // libp2p was disabled, stop it and clean up state
      _log.i('libp2p disabled from settings, cleaning up...');

      // Stop the libp2p service
      if (_libp2pService != null) {
        await _libp2pService!.stop();
      }

      // Mark libp2p as unavailable
      _libp2pAvailable = false;

      // Clear all discovered libp2p peers from Redux
      store.dispatch(ClearDiscoveredLibp2pPeersAction());

      // Disconnect all peers that were connected via libp2p
      // This clears their libp2pAddress and updates connection state
      for (final peer in _peersState.peersList) {
        if (peer.libp2pAddress != null) {
          store.dispatch(PeerLibp2pDisconnectedAction(peer.publicKey));
        }
      }

      _log.i('libp2p cleanup complete');
    }
  }
  
  // ===== Identity =====
  
  /// Update the user's nickname and broadcast to all peers
  Future<void> updateNickname(String newNickname) async {
    if (newNickname.isEmpty) return;
    
    _log.i('Updating nickname to: $newNickname');
    identity.nickname = newNickname;
    
    // Broadcast ANNOUNCE with new nickname to all connected peers
    await _broadcastAnnounce();
  }
  
  static const _uuid = Uuid();

  // ===== Messaging =====

  /// Send a message to a specific peer.
  ///
  /// Routes through the best available transport:
  /// 1. Bluetooth (if peer is nearby and BLE is enabled)
  /// 2. libp2p (if peer has libp2p address and libp2p is enabled)
  ///
  /// Returns the message ID if sent successfully, null if failed.
  /// The message status can be tracked via store.state.messages.
  Future<String?> send(Uint8List recipientPubkey, Uint8List payload, {String? messageId}) async {
    final peer = _peersState.getPeerByPubkey(recipientPubkey);

    // Use provided message ID or generate one
    messageId ??= _uuid.v4().substring(0, 8);

    // Determine which transport will be used
    MessageTransport? transport;
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null &&
        peer != null && peer.isReachable && peer.hasBleConnection) {
      transport = MessageTransport.ble;
    } else if (_isLibp2pEnabledInSettings && _libp2pAvailable && _libp2pService != null &&
        peer?.libp2pHostId != null && peer!.libp2pHostId!.isNotEmpty) {
      transport = MessageTransport.libp2p;
    }

    // If no transport available, return null immediately (don't dispatch sending)
    if (transport == null) {
      _log.w('No transport available to send message - peer is offline');
      return null;
    }

    // Dispatch sending action (clock icon)
    store.dispatch(MessageSendingAction(
      messageId: messageId,
      transport: transport,
      recipientPubkey: recipientPubkey,
      payloadSize: payload.length,
    ));

    // Create the message packet at coordinator level
    final packet = _protocolHandler.createMessagePacket(
      payload: payload,
      recipientPubkey: recipientPubkey,
    );

    // Try BLE first if that's the selected transport
    if (transport == MessageTransport.ble) {
      _log.d('Sending via BLE to ${peer!.displayName}');

      final bleId = peer.bleDeviceId;
      if (bleId == null) {
        _log.w('BLE transport selected but no BLE device ID available');
        return null;
      }

      await _protocolHandler.signPacket(packet);
      final success = await _bleService!.sendToPeer(bleId, packet.serialize());

      if (success) {
        store.dispatch(MessageSentAction(
          messageId: messageId,
          transport: MessageTransport.ble,
          recipientPubkey: recipientPubkey,
          payloadSize: payload.length,
        ));
        // BLE write-with-response confirms delivery (2 green ✓✓)
        store.dispatch(MessageDeliveredAction(messageId: messageId));
        return messageId;
      }
      _log.w('BLE send failed, trying libp2p fallback...');

      // Try libp2p fallback if available
      if (_isLibp2pEnabledInSettings && _libp2pAvailable && _libp2pService != null &&
          peer.libp2pHostId != null && peer.libp2pHostId!.isNotEmpty) {
        await _ensureLibp2pAddresses(peer);
        await _protocolHandler.signPacket(packet);
        final libp2pSuccess = await _libp2pService!.sendToPeer(
          peer.libp2pHostId!,
          packet.serialize(),
        );
        if (libp2pSuccess) {
          store.dispatch(MessageSentAction(
            messageId: messageId,
            transport: MessageTransport.libp2p,
            recipientPubkey: recipientPubkey,
            payloadSize: payload.length,
          ));
          return messageId;
        }
      }

      // Both transports failed
      store.dispatch(MessageFailedAction(messageId: messageId));
      _log.w('All transports failed to send message');
      return messageId;
    }

    // Try libp2p if that's the selected transport
    if (transport == MessageTransport.libp2p) {
      _log.d('Sending via libp2p to ${peer!.displayName}');

      await _ensureLibp2pAddresses(peer);
      await _protocolHandler.signPacket(packet);
      final success = await _libp2pService!.sendToPeer(
        peer.libp2pHostId!,
        packet.serialize(),
      );
      if (success) {
        store.dispatch(MessageSentAction(
          messageId: messageId,
          transport: MessageTransport.libp2p,
          recipientPubkey: recipientPubkey,
          payloadSize: payload.length,
        ));
        return messageId;
      }

      store.dispatch(MessageFailedAction(messageId: messageId));
      _log.w('libp2p send failed');
      return messageId;
    }

    return null;
  }

  /// Send a read receipt to the original sender of a message.
  /// Call this when the user has read/viewed a message.
  /// Returns true if the read receipt was sent successfully.
  Future<bool> sendReadReceipt({
    required String messageId,
    required Uint8List senderPubkey,
  }) async {
    final peer = _peersState.getPeerByPubkey(senderPubkey);

    // Create and sign read receipt packet at coordinator level
    final packet = _protocolHandler.createReadReceiptPacket(
      messageId: messageId,
      recipientPubkey: senderPubkey,
    );
    await _protocolHandler.signPacket(packet);
    final bytes = packet.serialize();

    // Try BLE first
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null) {
      if (peer != null && peer.hasBleConnection) {
        final bleId = peer.bleDeviceId;
        if (bleId != null && await _bleService!.sendToPeer(bleId, bytes)) return true;
      }
    }

    // Fall back to libp2p
    if (_isLibp2pEnabledInSettings && _libp2pAvailable && _libp2pService != null) {
      if (peer?.libp2pHostId != null && peer!.libp2pHostId!.isNotEmpty) {
        await _ensureLibp2pAddresses(peer);
        if (await _libp2pService!.sendToPeer(peer.libp2pHostId!, bytes)) return true;
      }
    }

    _log.w('No transport available to send read receipt');
    return false;
  }

  /// Broadcast a message to all peers on all enabled transports.
  Future<void> broadcast(Uint8List payload) async {
    // Create and sign the packet at coordinator level
    final packet = _protocolHandler.createMessagePacket(payload: payload);
    await _protocolHandler.signPacket(packet);
    final bytes = packet.serialize();

    // Broadcast via BLE
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null) {
      try {
        await _bleService!.broadcast(bytes);
      } catch (e) {
        _log.e('BLE broadcast failed: $e');
      }
    }

    // Broadcast via libp2p
    if (_isLibp2pEnabledInSettings && _libp2pAvailable && _libp2pService != null) {
      try {
        await _libp2pService!.broadcast(bytes);
      } catch (e) {
        _log.e('libp2p broadcast failed: $e');
      }
    }
  }
  
  // ===== Internal setup =====
  
  /// Set up MessageRouter callbacks to dispatch to Redux and application layer
  void _setupRouterCallbacks() {
    // Message received from any transport
    _messageRouter.onMessageReceived = (messageId, senderPubkey, payload) {
      // Determine transport from peer state
      final peer = store.state.peers.getPeerByPubkey(senderPubkey);
      // TODO: why determine transport from peer state instead of passing it from the message?
      final transport = peer?.activeTransport == PeerTransport.libp2p
          ? MessageTransport.libp2p
          : MessageTransport.ble;

      store.dispatch(MessageReceivedAction(
        messageId: messageId,
        transport: transport,
        senderPubkey: senderPubkey,
        payloadSize: payload.length,
      ));
      onMessageReceived?.call(messageId, senderPubkey, payload);
    };

    // ACK received (libp2p delivery confirmation)
    _messageRouter.onAckReceived = (messageId) {
      _log.d('ACK received for message $messageId');
      store.dispatch(MessageDeliveredAction(messageId: messageId));
    };

    // Read receipt received
    _messageRouter.onReadReceiptReceived = (messageId) {
      _log.d('Read receipt received for message $messageId');
      store.dispatch(MessageReadAction(messageId: messageId));
    };

    // Peer ANNOUNCE processed
    _messageRouter.onPeerAnnounced =
        (data, transport, {bool isNew = false, String? previousLibp2pAddress}) {
      final peerState = store.state.peers.getPeerByPubkey(data.publicKey);
      if (peerState != null) {
        if (isNew) {
          onPeerConnected?.call(_peerStateToPeer(peerState));
        } else {
          onPeerUpdated?.call(_peerStateToPeer(peerState));
        }
      }

      // Detect stale connection: if old address was dropped from ANNOUNCE,
      // disconnect and reconnect via new addresses.
      if (previousLibp2pAddress != null &&
          peerState != null &&
          peerState.libp2pAddress != previousLibp2pAddress) {
        // Old address is no longer valid — disconnect stale connection
        final hostId = peerState.libp2pHostId;
        if (hostId != null && _libp2pService != null) {
          _log.i(
              'Stale connection: ${peerState.nickname} address changed '
              '$previousLibp2pAddress → ${peerState.libp2pAddress}, disconnecting');
          _libp2pService!.disconnectFromPeer(hostId);
          // Clear libp2pAddress so _tryLibp2pConnectionForPeer doesn't bail
          store.dispatch(PeerLibp2pDisconnectedAction(data.publicKey));
        }
        _log.i('Reconnecting to ${peerState.nickname} with '
            '${peerState.libp2pHostAddrs?.length ?? 0} new addresses');
        _tryLibp2pConnectionForPeer(data.publicKey);
      } else {
        // No stale connection — just try connecting if not yet connected
        final addrsCount = peerState?.libp2pHostAddrs?.length ?? 0;
        _log.d('libp2p connection check for ${peerState?.nickname}: '
            '${peerState?.libp2pAddress != null ? "already connected" : "$addrsCount addresses available"}');
        _tryLibp2pConnectionForPeer(data.publicKey);
      }

    };

    // ACK request (router asks us to send ACK back to sender)
    _messageRouter.onAckRequested = (transport, peerId, messageId) async {
      final ackPacket = _protocolHandler.createAckPacket(messageId: messageId);
      await _protocolHandler.signPacket(ackPacket);
      final bytes = ackPacket.serialize();
      if (transport == PeerTransport.libp2p) {
        await _libp2pService?.sendToPeer(peerId, bytes);
      } else if (transport == PeerTransport.bleDirect) {
        await _bleService?.sendToPeer(peerId, bytes);
      }
    };
  }

  /// Convert PeerState to Peer for application callbacks
  Peer _peerStateToPeer(PeerState state) {
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

  /// Try to establish a libp2p connection to a peer using their advertised addresses.
  /// Called as a side-effect after processing an ANNOUNCE. If the peer already has
  /// a verified libp2p connection (libp2pAddress set), this is a no-op.
  void _tryLibp2pConnectionForPeer(Uint8List publicKey) {
    if (_libp2pService == null) return;

    final peer = store.state.peers.getPeerByPubkey(publicKey);
    if (peer == null) return;
    if (peer.libp2pAddress != null) return; // already connected
    if (peer.libp2pHostId == null || peer.libp2pHostAddrs == null || peer.libp2pHostAddrs!.isEmpty) return;

    final pubkeyHex = peer.pubkeyHex;
    if (_pendingLibp2pConnections.contains(pubkeyHex)) return; // attempt already in progress
    _pendingLibp2pConnections.add(pubkeyHex);

    final hostId = peer.libp2pHostId!;
    final hostAddrs = List<String>.from(peer.libp2pHostAddrs!);
    final pubkey = Uint8List.fromList(publicKey);

    _log.i('_tryLibp2pConnectionForPeer: ${peer.displayName} — '
        'trying ${hostAddrs.length} addresses in hierarchy order');
    for (var i = 0; i < hostAddrs.length; i++) {
      _log.d('  [${i + 1}] ${hostAddrs[i]}');
    }

    // Fire-and-forget: try connecting in the background
    _libp2pService!.connectToHost(hostId: hostId, hostAddrs: hostAddrs).then((successAddr) {
      if (successAddr != null) {
        _log.i('✓ ${peer.displayName} connected via libp2p: $successAddr');
        store.dispatch(AssociateLibp2pAddressAction(
          publicKey: pubkey,
          address: '$successAddr/p2p/$hostId',
        ));
      } else {
        _log.w('✗ ${peer.displayName}: all ${hostAddrs.length} libp2p addresses failed');
      }
    }).whenComplete(() {
      _pendingLibp2pConnections.remove(pubkeyHex);
    });
  }

  /// Set up callbacks for BLE transport service
  void _setupBleServiceCallbacks() {
    if (_bleService == null) return;

    // Forward BLE packets to the MessageRouter for processing
    _bleService!.onBlePacketReceived = (packet, {String? bleDeviceId, int rssi = -100, BleRole? bleRole}) {
      _messageRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        bleDeviceId: bleDeviceId,
        bleRole: bleRole,
        rssi: rssi,
      );
    };

    // Peer disconnected at BLE level
    _bleService!.onPeerDisconnected = (peer) {
      _log.i('BLE Peer disconnected: ${peer.displayName}');
      onPeerDisconnected?.call(peer);
    };

    // Listen to connection events for ANNOUNCE broadcasts.
    // Delay briefly so the remote device can finish its BLE setup
    // (MTU negotiation, service discovery, characteristic subscription)
    // before we try to send the ANNOUNCE packet.
    _bleService!.connectionStream.listen((event) {
      if (event.connected) {
        _log.i('BLE device connected: ${event.peerId}');
        Future.delayed(const Duration(seconds: 2), () {
          _broadcastAnnounce();
        });
      } else {
        _log.i('BLE device disconnected: ${event.peerId}');
      }
    });
  }
  
  /// Set up callbacks for libp2p transport service
  void _setupLibp2pServiceCallbacks() {
    if (_libp2pService == null) return;

    // Forward libp2p data to the MessageRouter for processing
    _libp2pService!.onLibp2pDataReceived = (peerId, data) {
      try {
        final packet = BitchatPacket.deserialize(data);
        _messageRouter.processPacket(
          packet,
          transport: PeerTransport.libp2p,
          libp2pPeerId: peerId,
        );
      } catch (e) {
        _log.e('Failed to deserialize libp2p packet from $peerId: $e');
      }
    };

    // Listen to connection events for ANNOUNCE broadcasts
    _libp2pService!.connectionStream.listen((event) {
      if (event.connected) {
        _log.i('libp2p peer connected: ${event.peerId}');
        _broadcastAnnounceViaLibp2p();
      } else {
        _log.i('libp2p peer disconnected: ${event.peerId}');
      }
    });
  }
  
  void _setStatus(TransportStatus newStatus) {
    if (_status == newStatus) return;
    _status = newStatus;
    _statusController.add(newStatus);
    onStatusChanged?.call(newStatus);
  }
  
  /// Clean up resources
  Future<void> dispose() async {
    _storeSubscription?.cancel();
    _announceTimer?.cancel();
    _scanTimer?.cancel();
    await stop();

    _messageRouter.dispose();

    if (_bleService != null) {
      await _bleService!.dispose();
    }

    if (_libp2pService != null) {
      await _libp2pService!.dispose();
    }

    await _statusController.close();
  }
  
  /// Start the periodic ANNOUNCE timer
  void _startAnnounceTimer() {
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(config.announceInterval, (_) {
      // _log.d('Timer is up! time to ANNOUNCE again 📢');
      _broadcastAnnounce();
      _broadcastAnnounceViaLibp2p();
      _removeStalePeers();
    });
  }
  
  /// Start the periodic scan timer
  void _startScanTimer() {
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(config.scanInterval, (_) {
      // _log.d('Scan timer is up! Scanning for new devices 📡');
      _periodicScan();
    });
  }
  
  /// Perform a periodic scan for new BLE devices
  Future<void> _periodicScan() async {
    if (_bleService == null || !_bleAvailable) return;
    // _log.i('Performing periodic BLE scan for new devices');
    try {
      // Dispatch to redux store
      store.dispatch(ScanStartedAction());
      
      await _bleService!.scan(timeout: config.scanDuration);
    } catch (e) {
      _log.e('Periodic scan failed: $e');
    } finally {
      // Dispatch to redux store
      store.dispatch(ScanCompletedAction());
    }
  }
  
  /// Build a signed ANNOUNCE packet and return serialized bytes.
  Future<Uint8List> _buildSignedAnnounceBytes(
      {List<String> addresses = const []}) async {
    final payload =
        _protocolHandler.createAnnouncePayload(addresses: addresses);
    final packet = BitchatPacket(
      type: PacketType.announce,
      ttl: 0,
      senderPubkey: identity.publicKey,
      payload: payload,
      signature: Uint8List(64),
    );
    await _protocolHandler.signPacket(packet);
    return packet.serialize();
  }

  /// Broadcast ANNOUNCE to all connected BLE devices.
  /// Friends receive ANNOUNCE with libp2p addresses (including local);
  /// strangers receive ANNOUNCE without addresses.
  Future<void> _broadcastAnnounce() async {
    if (_bleService == null || !_bleAvailable) return;

    // Basic ANNOUNCE (no addresses) for strangers + unidentified devices
    final basicBytes = await _buildSignedAnnounceBytes();

    if (_libp2pService == null || !_libp2pAvailable) {
      await _bleService!.broadcast(basicBytes);
      return;
    }

    final addresses = _libp2pService!.getRoutableAddresses(includeLocal: true);
    final friendPeers = store.state.peers.peersList
        .where((p) => p.isFriend && p.hasBleConnection)
        .toList();

    if (addresses.isEmpty || friendPeers.isEmpty) {
      await _bleService!.broadcast(basicBytes);
      return;
    }

    _log.d('ANNOUNCE: ${addresses.length} addrs, ${friendPeers.length} friends');

    final friendBytes = await _buildSignedAnnounceBytes(addresses: addresses);
    final friendDeviceIds = friendPeers.map((p) => p.bleDeviceId).whereType<String>().toSet();
    await _bleService!.broadcast(
      basicBytes,
      friendData: friendBytes,
      friendDeviceIds: friendDeviceIds,
    );
  }

  /// Broadcast ANNOUNCE via libp2p (uses BitchatPacket format, same as BLE)
  Future<void> _broadcastAnnounceViaLibp2p() async {
    if (_libp2pService == null || !_libp2pAvailable) return;

    final bytes = await _buildSignedAnnounceBytes(
        addresses: _libp2pService!.getRoutableAddresses());
    await _libp2pService!.broadcast(bytes);
  }

  /// Send ANNOUNCE with addresses to a specific friend.
  ///
  /// This is the unified presence mechanism - friends receive our libp2p addresses
  /// in the ANNOUNCE so they can connect to us over the internet.
  ///
  /// Works over both BLE and libp2p transports.
  Future<bool> sendAnnounceToFriend({
    required Uint8List friendPubkey,
    required List<String> myAddresses,
  }) async {
    var sent = false;

    // Create signed ANNOUNCE packet with our addresses
    final payload = _protocolHandler.createAnnouncePayload(addresses: myAddresses);
    final packet = BitchatPacket(
      type: PacketType.announce,
      ttl: 0,
      senderPubkey: identity.publicKey,
      recipientPubkey: friendPubkey,
      payload: payload,
      signature: Uint8List(64),
    );
    await _protocolHandler.signPacket(packet);
    final bytes = packet.serialize();

    // Try BLE first if available
    if (_bleService != null && _bleAvailable) {
      final peerId = _bleService!.getPeerIdForPubkey(friendPubkey);
      if (peerId != null) {
        sent = await _bleService!.sendToPeer(peerId, bytes);
      }
    }

    // Also try libp2p if available
    if (_libp2pService != null && _libp2pAvailable) {
      final peerId = _libp2pService!.getPeerIdForPubkey(friendPubkey);
      if (peerId != null) {
        final libp2pSent = await _libp2pService!.sendToPeer(peerId, bytes);
        sent = sent || libp2pSent;
      }
    }

    return sent;
  }

  /// Remove peers that haven't sent an ANNOUNCE within the interval
  void _removeStalePeers() {
    final staleThreshold = config.announceInterval * 2; // Give 2x grace period
    
    // Dispatch action to remove stale peers via Redux
    store.dispatch(StaleDiscoveredBlePeersRemovedAction(staleThreshold));
    store.dispatch(StalePeersRemovedAction(staleThreshold));
    
    // _log.d('Dispatched stale peer cleanup actions');
  }
  
  // ===== LibP2P Helpers =====

  /// Ensure libp2p peer addresses are in the peerstore before dialing.
  Future<void> _ensureLibp2pAddresses(PeerState peer) async {
    if (_libp2pService == null) return;
    final hostId = peer.libp2pHostId;
    final hostAddrs = peer.libp2pHostAddrs;
    if (hostId != null && hostAddrs != null && hostAddrs.isNotEmpty) {
      await _libp2pService!.ensureAddressesInPeerstore(hostId, hostAddrs);
    }
  }
}