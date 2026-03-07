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
import 'protocol/fragment_handler.dart';
import 'routing/message_router.dart';
import 'store/store.dart';
import 'transport/transport_service.dart';

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
  
  /// Whether the coordinator has been initialized
  bool _initialized = false;

  /// Whether the coordinator has been started
  bool _started = false;

  /// Lock to serialize transport settings changes (prevents overlapping init/dispose)
  Future<void>? _transportUpdateLock;

  /// Protocol handler for encoding/decoding packets
  late final ProtocolHandler _protocolHandler;

  /// Fragment handler for large BLE messages
  late final FragmentHandler _fragmentHandler;

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
    _fragmentHandler = FragmentHandler();
    _messageRouter = MessageRouter(
      identity: identity,
      store: store,
      protocolHandler: _protocolHandler,
      fragmentHandler: _fragmentHandler,
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
  
  /// Whether BLE transport is available (initialized and usable)
  bool get _bleAvailable =>
      _bleService != null && store.state.transports.bleState.isUsable;

  /// Whether libp2p transport is available (initialized and usable)
  bool get _libp2pAvailable =>
      _libp2pService != null && store.state.transports.libp2pState.isUsable;

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
    if (_initialized) {
      _log.w('Already initialized');
      return _bleAvailable || _libp2pAvailable;
    }

    _initialized = true;
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
        return false;
      }

      _log.i('Bitchat transport initialized (BLE: $_bleAvailable, libp2p: $_libp2pAvailable)');

      // Auto-start if configured
      if (config.autoStart) {
        await start();
      }

      return true;
    } catch (e) {
      _log.e('Failed to initialize: $e');
      return false;
    }
  }
  
  /// Initialize BLE transport
  Future<bool> _initializeBle() async {
    try {
      _log.i('Initializing BLE transport');

      // Reset Redux state so the service sees uninitialized
      store.dispatch(BleTransportStateChangedAction(TransportState.uninitialized));

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

      // Initialize the service (dispatches state to Redux)
      final success = await _bleService!.initialize();
      if (!success) {
        _log.w('BLE service initialization returned false');
        _bleService = null;
        return false;
      }

      // Wire up callbacks
      _setupBleServiceCallbacks();

      _log.i('BLE transport initialized successfully');
      return true;
    } catch (e, stack) {
      _log.e('Failed to initialize BLE transport: $e');
      _log.d('Stack trace: $stack');
      _bleService = null;
      return false;
    }
  }
  
  /// Initialize libp2p transport
  Future<bool> _initializeLibp2p() async {
    try {
      _log.i('Initializing libp2p transport');

      // Reset Redux state so the service sees uninitialized
      store.dispatch(LibP2PTransportStateChangedAction(TransportState.uninitialized));

      // Create libp2p transport service
      _libp2pService = LibP2PTransportService(
        identity: identity,
        store: store,
        protocolHandler: _protocolHandler,
        config: const LibP2PConfig(),
      );

      // Initialize the service (dispatches state to Redux)
      final success = await _libp2pService!.initialize();
      if (!success) {
        _log.w('libp2p service initialization returned false');
        _libp2pService = null;
        return false;
      }

      // Wire up callbacks
      _setupLibp2pServiceCallbacks();

      _log.i('libp2p transport initialized successfully');
      onLibp2pInitialized?.call();
      return true;
    } catch (e, stack) {
      _log.e('Failed to initialize libp2p transport: $e');
      _log.d('Stack trace: $stack');
      _libp2pService = null;
      return false;
    }
  }
  
  /// Start scanning and advertising.
  Future<void> start() async {
    if (_started) {
      _log.w('Already started');
      return;
    }
    if (!_bleAvailable && !_libp2pAvailable) {
      _log.w('Cannot start: no transports available');
      return;
    }

    _log.i('Starting Bitchat transport');

    // Start BLE if available
    if (_bleAvailable) {
      try {
        await _bleService!.start();
        _log.i('BLE transport started');
      } catch (e) {
        _log.e('Failed to start BLE: $e');
      }
    }

    // Start libp2p if available
    if (_libp2pAvailable) {
      try {
        await _libp2pService!.start();
        _log.i('libp2p transport started');
      } catch (e) {
        _log.e('Failed to start libp2p: $e');
      }
    }

    _started = true;
    _startAnnounceTimer();
    _startScanTimer();
  }

  /// Stop scanning and advertising.
  Future<void> stop() async {
    if (!_started) return;

    _log.i('Stopping Bitchat transport');
    _started = false;
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
  }
  
  /// Handle transport settings changes.
  /// Serializes updates so overlapping init/dispose sequences cannot occur.
  void _onTransportSettingsChanged() {
    _log.i('Transport settings changed');
    final previous = _transportUpdateLock ?? Future.value();
    _transportUpdateLock = previous.then((_) => _updateTransportsFromSettings());
  }
  
  /// Update transports based on current settings
  Future<void> _updateTransportsFromSettings() async {
    final wasStarted = _started;

    // Handle BLE enable/disable
    if (_isBleEnabledInSettings && !_bleAvailable) {
      // BLE was enabled, try to initialize
      // Dispose old service first to clean up native state (GATT server, subscriptions)
      if (_bleService != null) {
        _log.i('Disposing old BLE service before re-initialization');
        await _bleService!.dispose();
        _bleService = null;
      }
      await _initializeBle();
      if (wasStarted && _bleAvailable) {
        await _bleService!.start();
      }
    } else if (!_isBleEnabledInSettings && _bleAvailable) {
      // BLE was disabled, dispose service and clean up
      _log.i('BLE disabled from settings, cleaning up...');

      if (_bleService != null) {
        await _bleService!.dispose();
        _bleService = null;
      }

      // Reset Redux state so _bleAvailable returns false
      store.dispatch(BleTransportStateChangedAction(TransportState.uninitialized));

      // Clear all discovered BLE peers from Redux
      store.dispatch(ClearDiscoveredBlePeersAction());

      // Disconnect all peers that were connected via BLE
      for (final peer in _peersState.peersList) {
        if (peer.bleDeviceId != null) {
          store.dispatch(PeerBleDisconnectedAction(peer.publicKey));
        }
      }

      _log.i('BLE cleanup complete');
    }

    // Handle libp2p enable/disable
    if (_isLibp2pEnabledInSettings && !_libp2pAvailable) {
      // libp2p was enabled, try to initialize
      await _initializeLibp2p();
      if (wasStarted && _libp2pAvailable) {
        await _libp2pService!.start();
      }
    } else if (!_isLibp2pEnabledInSettings && _libp2pAvailable) {
      // libp2p was disabled, dispose service and clean up
      _log.i('libp2p disabled from settings, cleaning up...');

      if (_libp2pService != null) {
        await _libp2pService!.dispose();
        _libp2pService = null;
      }

      // Reset Redux state so _libp2pAvailable returns false
      store.dispatch(LibP2PTransportStateChangedAction(TransportState.uninitialized));

      // Clear all discovered libp2p peers from Redux
      store.dispatch(ClearDiscoveredLibp2pPeersAction());

      // Disconnect all peers that were connected via libp2p
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
        peer != null && peer.isReachable && peer.bleDeviceId != null) {
      transport = MessageTransport.ble;
    } else {
      final peerHostId = peer?.libp2pHostId;
      if (_isLibp2pEnabledInSettings && _libp2pAvailable && _libp2pService != null &&
          peerHostId != null && peerHostId.isNotEmpty) {
        transport = MessageTransport.libp2p;
      }
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

    // Create the message packet at coordinator level and sign it once
    final packet = _protocolHandler.createMessagePacket(
      payload: payload,
      recipientPubkey: recipientPubkey,
    );

    // Sign once before any send attempt (fragments are signed individually)
    if (!_fragmentHandler.needsFragmentation(payload)) {
      await _protocolHandler.signPacket(packet);
    }

    // peer is guaranteed non-null here since transport selection checks it
    final resolvedPeer = peer!;

    // Try BLE first if that's the selected transport
    if (transport == MessageTransport.ble) {
      final bleDeviceId = resolvedPeer.bleDeviceId!;
      _log.d('Sending via BLE to ${resolvedPeer.displayName}');

      bool success;
      if (_fragmentHandler.needsFragmentation(payload)) {
        success = await _sendFragmentedViaBle(
          payload: payload,
          recipientPubkey: recipientPubkey,
          bleDeviceId: bleDeviceId,
        );
      } else {
        success = await _bleService!.sendToPeer(bleDeviceId, packet.serialize());
      }

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
      final hostId = resolvedPeer.libp2pHostId;
      if (_isLibp2pEnabledInSettings && _libp2pAvailable && _libp2pService != null &&
          hostId != null && hostId.isNotEmpty) {
        await _ensureLibp2pAddresses(resolvedPeer);
        final libp2pSuccess = await _libp2pService!.sendToPeer(
          hostId,
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
      _log.d('Sending via libp2p to ${resolvedPeer.displayName}');

      await _ensureLibp2pAddresses(resolvedPeer);
      final libp2pHostId = resolvedPeer.libp2pHostId!;
      final success = await _libp2pService!.sendToPeer(
        libp2pHostId,
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
      final bleDeviceId = peer?.bleDeviceId;
      if (peer != null && bleDeviceId != null) {
        if (await _bleService!.sendToPeer(bleDeviceId, bytes)) return true;
      }
    }

    // Fall back to libp2p
    if (_isLibp2pEnabledInSettings && _libp2pAvailable && _libp2pService != null) {
      final libp2pHostId = peer?.libp2pHostId;
      if (peer != null && libp2pHostId != null && libp2pHostId.isNotEmpty) {
        await _ensureLibp2pAddresses(peer);
        if (await _libp2pService!.sendToPeer(libp2pHostId, bytes)) return true;
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

    // Broadcast via BLE (handle fragmentation)
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null) {
      try {
        if (_fragmentHandler.needsFragmentation(payload)) {
          await _broadcastFragmentedViaBle(payload: payload);
        } else {
          await _bleService!.broadcast(bytes);
        }
      } catch (e) {
        _log.e('BLE broadcast failed: $e');
      }
    }

    // Broadcast via libp2p (no size limit)
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
    _messageRouter.onPeerAnnounced = (data, transport, {bool isNew = false}) {
      if (isNew) {
        final peerState = store.state.peers.getPeerByPubkey(data.publicKey);
        if (peerState != null) {
          onPeerConnected?.call(_peerStateToLegacyPeer(peerState));
        }
      } else {
        final peerState = store.state.peers.getPeerByPubkey(data.publicKey);
        if (peerState != null) {
          onPeerUpdated?.call(_peerStateToLegacyPeer(peerState));
        }
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

  /// Set up callbacks for BLE transport service
  void _setupBleServiceCallbacks() {
    if (_bleService == null) return;

    // Forward BLE packets to the MessageRouter for processing
    _bleService!.onBlePacketReceived = (packet, {String? bleDeviceId, int rssi = -100}) {
      _messageRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        bleDeviceId: bleDeviceId,
        rssi: rssi,
      );
    };

    // Peer disconnected at BLE level
    _bleService!.onPeerDisconnected = (peer) {
      _log.i('BLE Peer disconnected: ${peer.displayName}');
      onPeerDisconnected?.call(peer);
    };

    // Listen to connection events for ANNOUNCE broadcasts
    _bleService!.connectionStream.listen((event) {
      if (event.connected) {
        _log.i('BLE device connected: ${event.peerId}');
        _broadcastAnnounce();
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
  
  /// Clean up resources
  Future<void> dispose() async {
    _storeSubscription?.cancel();
    _storeSubscription = null;
    _announceTimer?.cancel();
    _scanTimer?.cancel();

    // Wait for any in-flight transport update to finish before disposing
    if (_transportUpdateLock != null) {
      await _transportUpdateLock;
      _transportUpdateLock = null;
    }

    await stop();

    _messageRouter.dispose();

    if (_bleService != null) {
      await _bleService!.dispose();
    }

    if (_libp2pService != null) {
      await _libp2pService!.dispose();
    }
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
    if (!_bleAvailable) return;
    try {
      store.dispatch(BleScanningChangedAction(true));
      await _bleService!.scan(timeout: config.scanDuration);
    } catch (e) {
      _log.e('Periodic scan failed: $e');
    } finally {
      store.dispatch(BleScanningChangedAction(false));
    }
  }
  
  /// Broadcast ANNOUNCE to all connected BLE devices
  Future<void> _broadcastAnnounce() async {
    if (_bleService == null || !_bleAvailable) return;

    final payload = _protocolHandler.createAnnouncePayload();
    final packet = BitchatPacket(
      type: PacketType.announce,
      ttl: 0,
      senderPubkey: identity.publicKey,
      payload: payload,
      signature: Uint8List(64),
    );
    await _protocolHandler.signPacket(packet);
    await _bleService!.broadcast(packet.serialize());
  }

  /// Broadcast ANNOUNCE via libp2p (uses BitchatPacket format, same as BLE)
  Future<void> _broadcastAnnounceViaLibp2p() async {
    if (_libp2pService == null || !_libp2pAvailable) return;

    // Include our libp2p address so peers can connect to us
    final addrs = libp2pHostAddrs;
    final addr = addrs.isNotEmpty ? addrs.first : null;
    final payload = _protocolHandler.createAnnouncePayload(address: addr);
    final packet = BitchatPacket(
      type: PacketType.announce,
      ttl: 0,
      senderPubkey: identity.publicKey,
      payload: payload,
      signature: Uint8List(64),
    );
    await _protocolHandler.signPacket(packet);
    await _libp2pService!.broadcast(packet.serialize());
  }

  /// Send ANNOUNCE with address to a specific friend.
  ///
  /// This is the unified presence mechanism - friends receive our libp2p address
  /// in the ANNOUNCE so they can connect to us over the internet.
  ///
  /// Works over both BLE and libp2p transports.
  Future<bool> sendAnnounceToFriend({
    required Uint8List friendPubkey,
    required String myAddress,
  }) async {
    var sent = false;

    // Create signed ANNOUNCE packet with our address
    final payload = _protocolHandler.createAnnouncePayload(address: myAddress);
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
  
  // ===== BLE Fragmentation Helpers =====

  /// Send a large payload via BLE using fragmentation.
  /// Each fragment is individually signed.
  Future<bool> _sendFragmentedViaBle({
    required Uint8List payload,
    required Uint8List recipientPubkey,
    required String bleDeviceId,
  }) async {
    final fragmented = _fragmentHandler.fragment(
      payload: payload,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
    );

    for (final fragment in fragmented.fragments) {
      await _protocolHandler.signPacket(fragment);
      final sent = await _bleService!.sendToPeer(bleDeviceId, fragment.serialize());
      if (!sent) return false;
      await Future.delayed(FragmentHandler.fragmentDelay);
    }
    return true;
  }

  /// Broadcast a large payload via BLE using fragmentation.
  /// Each fragment is individually signed.
  Future<void> _broadcastFragmentedViaBle({required Uint8List payload}) async {
    final fragmented = _fragmentHandler.fragment(
      payload: payload,
      senderPubkey: identity.publicKey,
    );

    for (final fragment in fragmented.fragments) {
      await _protocolHandler.signPacket(fragment);
      await _bleService!.broadcast(fragment.serialize());
      await Future.delayed(FragmentHandler.fragmentDelay);
    }
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