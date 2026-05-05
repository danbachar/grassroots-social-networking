import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:redux/redux.dart';
import 'package:uuid/uuid.dart';
import 'ble/permission_handler.dart';
import 'signaling/signaling_codec.dart';
import 'signaling/signaling_service.dart';
import 'transport/address_utils.dart';
import 'transport/ble_transport_service.dart';
import 'transport/connection_service.dart';
import 'transport/hole_punch_service.dart';
import 'transport/public_address_discovery.dart';
import 'transport/udp_transport_service.dart';
import 'models/identity.dart';
import 'models/peer.dart';
import 'models/packet.dart';
import 'protocol/protocol_handler.dart';
import 'protocol/fragment_handler.dart';
import 'routing/message_router.dart';
import 'store/store.dart';
import 'transport/transport_service.dart';

/// Configuration for Grassroots transport
class GrassrootsNetworkConfig {
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

  /// Whether to enable UDP transport (can be overridden by TransportSettingsStore)
  final bool enableUdp;

  const GrassrootsNetworkConfig({
    this.autoConnect = true,
    this.autoStart = true,
    this.scanDuration,
    this.localName,
    this.announceInterval = const Duration(seconds: 10),
    this.scanInterval = const Duration(seconds: 10),
    this.enableBle = true,
    this.enableUdp = true,
  });
}

class _RendezvousConfig {
  final String address;
  final Uint8List pubkey;
  final String pubkeyHex;

  const _RendezvousConfig({
    required this.address,
    required this.pubkey,
    required this.pubkeyHex,
  });
}

@visibleForTesting
bool shouldAcceptRendezvousReply(
  String pubkeyHex, {
  required SettingsState settings,
  required Iterable<String> pendingResponsePubkeys,
}) {
  final normalizedPubkeyHex = pubkeyHex.toLowerCase();

  for (final server in settings.configuredRendezvousServers) {
    if (server.pubkeyHex.isNotEmpty &&
        server.pubkeyHex.toLowerCase() == normalizedPubkeyHex) {
      return true;
    }
  }

  for (final pendingPubkeyHex in pendingResponsePubkeys) {
    if (pendingPubkeyHex == normalizedPubkeyHex) {
      return true;
    }
  }

  return false;
}

@visibleForTesting
Set<String> computeStaleUdpPeerPubkeys({
  required Iterable<PeerState> peers,
  required Set<String> connectedUdpPubkeys,
  required Duration staleThreshold,
  DateTime? now,
}) {
  final evaluationTime = now ?? DateTime.now();
  final stale = <String>{};

  for (final peer in peers) {
    if (!connectedUdpPubkeys.contains(peer.pubkeyHex)) continue;
    final lastUdpSeen = peer.lastUdpSeen;
    if (lastUdpSeen == null) continue;

    if (evaluationTime.difference(lastUdpSeen) > staleThreshold) {
      stale.add(peer.pubkeyHex);
    }
  }

  return stale;
}

/// Main Grassroots transport API.
///
/// This is the entry point for GSG to use Grassroots as a transport layer.
///
/// Usage:
/// ```dart
/// final identity = GrassrootsIdentity(
///   publicKey: myPubKey,
///   privateKey: myPrivKey,
///   nickname: 'Alice',
/// );
///
/// final grassroots = GrassrootsNetwork(identity: identity);
///
/// grassroots.onMessageReceived = (senderPubkey, payload) {
///   // Handle incoming GSG block
/// };
///
/// grassroots.onPeerConnected = (peer) {
///   // Send ANNOUNCE, start cordial dissemination
/// };
///
/// await grassroots.initialize();
/// await grassroots.start();
///
/// // Send a message
/// await grassroots.send(recipientPubkey, gsgBlockData);
/// ```
class GrassrootsNetwork {
  /// Our identity (from GSG layer)
  final GrassrootsIdentity identity;

  /// Configuration
  final GrassrootsNetworkConfig config;

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

  /// UDP transport service (null if UDP is disabled)
  UdpTransportService? _udpService;

  /// Hole-punch services for NAT traversal, keyed by IP family.
  final Map<InternetAddressType, HolePunchService> _holePunchServices = {};

  /// Signaling service for address registration, queries, and hole-punch coordination
  late final SignalingService _signalingService;

  /// Public address discovery for finding our public ip:port
  final PublicAddressDiscovery _publicAddressDiscovery =
      PublicAddressDiscovery();

  /// Our discovered public address (ip:port), shared with friends
  String? _publicAddress;
  String? _linkLocalAddress;
  Set<String> _publicAddressCandidates = const {};

  final UdpConnectionService _connectionService = const UdpConnectionService();

  /// The in-flight background public-address discovery task.
  Future<void>? _publicAddressDiscoveryFuture;
  int _publicAddressDiscoveryGeneration = 0;

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

  /// Subscription for network connectivity changes
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  /// Last known connectivity results (to detect actual changes)
  List<ConnectivityResult>? _lastConnectivityResults;

  /// Protocol handler for encoding/decoding packets
  late final ProtocolHandler _protocolHandler;

  /// Fragment handler for large BLE messages
  late final FragmentHandler _fragmentHandler;

  /// Message router for incoming packet processing
  late final MessageRouter _messageRouter;

  /// Pending hole-punch completers: pubkeyHex → completer that resolves
  /// to true (connected) or false (failed) when the punch finishes.
  final Map<String, Completer<bool>> _holePunchCompleters = {};

  /// The target address we last punched toward for each peer.
  final Map<String, AddressInfo> _holePunchTargets = {};

  /// Whether we have finished our local punch for the peer.
  final Set<String> _holePunchLocalReady = {};

  /// Whether the remote peer has explicitly reported readiness.
  final Set<String> _holePunchRemoteReady = {};

  /// Prevent duplicate connect attempts while a punch is in flight.
  final Set<String> _holePunchConnectionInProgress = {};

  /// Keep punch traffic flowing while the initiator transitions from
  /// coordination into the actual UDX connect attempt.
  final Set<String> _holePunchKeepAliveInProgress = {};

  /// Deduplicate in-flight UDX connection attempts across all callers.
  final Map<String, Future<bool>> _udpConnectInFlight = {};

  /// Deduplicate proactive auto-UDP workflows kicked off by repeated ANNOUNCEs.
  final Map<String, Future<void>> _autoUdpConnectInFlight = {};
  final Map<String, String> _autoUdpLastAddress = {};
  final Map<String, DateTime> _autoUdpRetryAfter = {};

  /// Tracks when we last attempted discovery for each unreachable friend.
  /// Prevents hammering discovery every announce tick (10s) for the same peer.
  final Map<String, DateTime> _lastDiscoveryAttempt = {};

  /// Minimum interval between discovery attempts for the same peer.
  static const _discoveryRetryInterval = Duration(seconds: 60);

  /// Back off briefly after a failed proactive UDP attempt so repeated BLE
  /// ANNOUNCEs don't start a fresh UDX handshake every few seconds.
  static const _autoUdpRetryBackoff = Duration(seconds: 15);
  static const _holePunchKeepAliveDuration = Duration(seconds: 3);

  /// BLE device IDs that have already received a directed friend ANNOUNCE on
  /// the current connection. Cleared on disconnect so reconnects get a fresh
  /// addressed ANNOUNCE as soon as we know who is on the other side.
  final Set<String> _bleFriendAnnounceSent = {};

  /// Serialize rendezvous connect/re-announce work so a public-address update
  /// cannot race a save-triggered connect or a signaling-triggered re-register.
  Future<void> _rendezvousTaskQueue = Future.value();
  final Map<String, Future<bool>> _rendezvousSyncInFlight = {};
  final Map<String, DateTime> _rendezvousRetryAfter = {};
  final Map<String, UdpConnectFailureKind?> _rendezvousLastFailureKind = {};
  final Map<String, String> _lastRendezvousSuppressionLogKey = {};
  final Map<String, Set<Completer<void>>> _rendezvousResponseWaiters = {};

  static const _rendezvousNetworkUnreachableBackoff = Duration(seconds: 15);
  static const _rendezvousHandshakeTimeoutBackoff = Duration(seconds: 20);

  // ===== Public callbacks =====

  /// Called when an application message is received.
  /// Parameters: messageId, senderPubkey, payload (raw GSG block data), transport
  void Function(
    String messageId,
    Uint8List senderPubkey,
    Uint8List payload,
    MessageTransport transport,
  )? onMessageReceived;

  /// Called when a new peer connects and exchanges ANNOUNCE
  void Function(Peer peer)? onPeerConnected;

  /// Called when an existing peer sends an ANNOUNCE update
  void Function(Peer peer)? onPeerUpdated;

  /// Called when a peer disconnects
  void Function(Peer peer)? onPeerDisconnected;

  /// Called when UDP transport becomes available
  void Function()? onUdpInitialized;

  // ===== Convenience accessors for Redux state =====

  PeersState get _peersState => store.state.peers;

  GrassrootsNetwork({
    required this.identity,
    this.config = const GrassrootsNetworkConfig(),
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
    _signalingService = SignalingService(store: store);
    _setupRouterCallbacks();
    _setupSignalingCallbacks();

    // Listen to network connectivity changes (WiFi ↔ cellular, etc.)
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
          _onConnectivityChanged,
        );
    _seedConnectivityState();

    // Listen to Redux store changes for settings and friendship updates
    _lastSettingsState = store.state.settings;
    _storeSubscription = store.onChange.listen((state) {
      final previousSettings = _lastSettingsState;
      if (previousSettings != null && state.settings != previousSettings) {
        _lastSettingsState = state.settings;
        _onTransportSettingsChanged(previousSettings, state.settings);
      }
    });
  }

  /// Whether BLE transport is available (initialized and usable)
  bool get _bleAvailable =>
      _bleService != null && store.state.transports.bleState.isUsable;

  /// Whether UDP transport is available (initialized and usable)
  bool get _udpAvailable =>
      _udpService != null && store.state.transports.udpState.isUsable;

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

  /// Whether UDP is currently enabled and available
  bool get isUdpEnabled => _udpAvailable && _isUdpEnabledInSettings;

  List<RendezvousServerSettings> get configuredRendezvousServers =>
      store.state.settings.configuredRendezvousServers;

  /// Our UDP address to share with friends.
  ///
  /// Returns the public UDP address discovered for the active IP family.
  /// Never returns a private LAN address. Returns null if public address
  /// discovery failed and we therefore have nothing to advertise.
  String? get udpAddress => _publicAddress;

  /// UDP address candidates to share with trusted peers.
  Set<String> get udpAddressCandidates => Set.unmodifiable(
        _candidateAddresses(includeLinkLocal: _linkLocalAddress != null),
      );

  /// Whether currently scanning for BLE devices
  bool get isScanning => _bleService?.isScanning ?? false;

  bool get _isBleEnabledInSettings => store.state.settings.bluetoothEnabled;

  bool get _isUdpEnabledInSettings => store.state.settings.udpEnabled;

  Future<bool> addRendezvousServer({
    required String address,
    required String pubkeyHex,
  }) async {
    final config = _parseRendezvousConfig(
      address: address,
      pubkeyHex: pubkeyHex,
    );
    if (config == null) return false;

    if (_hasConfiguredRendezvousServer(config)) {
      return true;
    }

    final responded = await _verifyRendezvousServerResponds(config);
    if (!responded) return false;

    store.dispatch(
      AddRendezvousServerAction(
        RendezvousServerSettings(
          address: config.address,
          pubkeyHex: config.pubkeyHex,
        ),
      ),
    );
    return true;
  }

  Future<void> removeRendezvousServer({
    required String address,
    required String pubkeyHex,
  }) async {
    store.dispatch(
      RemoveRendezvousServerAction(
        RendezvousServerSettings(address: address, pubkeyHex: pubkeyHex),
      ),
    );
  }

  /// Explicitly disconnect from a BLE peer
  Future<void> disconnectBlePeer(String pubkeyHex) async {
    final peer = _peersState.getPeerByPubkeyHex(pubkeyHex);
    if (peer != null && _bleService != null) {
      if (peer.bleCentralDeviceId != null) {
        store.dispatch(BleDeviceBlacklistedAction(peer.bleCentralDeviceId!));
        await _bleService!.disconnectFromDevice(peer.bleCentralDeviceId!);
      }
      if (peer.blePeripheralDeviceId != null) {
        store.dispatch(BleDeviceBlacklistedAction(peer.blePeripheralDeviceId!));
        await _bleService!.disconnectFromDevice(peer.blePeripheralDeviceId!);
      }
    }
  }

  /// Explicitly connect to a discovered BLE device
  Future<bool> connectBleDevice(String deviceId) async {
    store.dispatch(BleDeviceUnblacklistedAction(deviceId));
    if (_bleService != null) {
      return await _bleService!.connectToDevice(deviceId, isManual: true);
    }
    return false;
  }

  // ===== Lifecycle =====

  /// Initialize the transport layer.
  ///
  /// This will:
  /// 1. Request required permissions
  /// 2. Initialize enabled transports (BLE and/or UDP)
  /// 3. Set up routing
  ///
  /// Call [start] after this to begin scanning/advertising.
  Future<bool> initialize() async {
    if (_initialized) {
      debugPrint('Already initialized');
      return _bleAvailable || _udpAvailable;
    }

    _initialized = true;
    debugPrint('Initializing Grassroots transport');

    bool anyTransportInitialized = false;

    try {
      // Initialize BLE if enabled
      if (_isBleEnabledInSettings) {
        anyTransportInitialized =
            await _initializeBle() || anyTransportInitialized;
      }

      // Initialize UDP if enabled
      if (_isUdpEnabledInSettings) {
        anyTransportInitialized =
            await _initializeUdp() || anyTransportInitialized;
      }

      if (!anyTransportInitialized) {
        debugPrint('No transports could be initialized');
        return false;
      }

      debugPrint(
        'Grassroots transport initialized (BLE: $_bleAvailable, UDP: $_udpAvailable)',
      );

      // Auto-start if configured
      if (config.autoStart) {
        await start();
      }

      return true;
    } catch (e) {
      debugPrint('Failed to initialize: $e');
      return false;
    }
  }

  /// Initialize BLE transport
  Future<bool> _initializeBle() async {
    try {
      debugPrint('Initializing BLE transport');

      // Reset Redux state so the service sees uninitialized
      store.dispatch(
        BleTransportStateChangedAction(TransportState.uninitialized),
      );

      // Request BLE permissions
      final permResult = await _permissions.requestPermissions();
      if (permResult != PermissionResult.granted) {
        debugPrint('BLE permissions not granted: $permResult');
        return false;
      }

      // Create BLE transport service (manages BLE manager + router)
      _bleService = BleTransportService(
        identity: identity,
        store: store,
        localName: config.localName ?? identity.nickname,
      );

      // Wire up callbacks BEFORE initialize — the connectionStream is a
      // broadcast stream that drops events with no listener. BLE connections
      // can arrive during initialize() (e.g. iOS central connecting to our
      // peripheral), so the listener must be in place first.
      _setupBleServiceCallbacks();

      // Initialize the service (dispatches state to Redux)
      final success = await _bleService!.initialize();
      if (!success) {
        debugPrint('BLE service initialization returned false');
        _bleService = null;
        return false;
      }

      debugPrint('BLE transport initialized successfully');
      return true;
    } catch (e, stack) {
      debugPrint('Failed to initialize BLE transport: $e');
      debugPrint('Stack trace: $stack');
      _bleService = null;
      return false;
    }
  }

  /// Initialize UDP transport
  Future<bool> _initializeUdp() async {
    try {
      debugPrint('Initializing UDP transport');

      // Reset Redux state so the service sees uninitialized
      store.dispatch(
        UdpTransportStateChangedAction(TransportState.uninitialized),
      );

      // Create UDP transport service
      _udpService = UdpTransportService(
        identity: identity,
        store: store,
        protocolHandler: _protocolHandler,
      );

      // Initialize the service (dispatches state to Redux)
      final success = await _udpService!.initialize();
      if (!success) {
        debugPrint('UDP service initialization returned false');
        _udpService = null;
        return false;
      }

      // Wire up callbacks
      _setupUdpServiceCallbacks();

      // Create hole-punch services using each raw socket.
      _holePunchServices
        ..clear()
        ..addEntries(
          _udpService!.rawSocketsByType.entries.map(
            (entry) => MapEntry(
              entry.key,
              HolePunchService(
                socket: entry.value,
                senderPubkey: identity.publicKey,
              ),
            ),
          ),
        );

      // Start multiplexer immediately (punch packets can still be sent via raw socket)
      _udpService!.startMultiplexer();

      // Discover our public UDP address for the active IP family in the
      // background.
      _publicAddressDiscoveryFuture = _discoverPublicAddress();

      // Treat the configured rendezvous server as a UDP peer we keep a
      // session with so it can immediately learn or refresh our address.
      _resetRendezvousBackoff();
      unawaited(_syncConfiguredRendezvous(reason: 'udp-initialized'));

      debugPrint('UDP transport initialized successfully');
      onUdpInitialized?.call();
      return true;
    } catch (e, stack) {
      debugPrint('Failed to initialize UDP transport: $e');
      debugPrint('Stack trace: $stack');
      _udpService = null;
      return false;
    }
  }

  /// Start scanning and advertising.
  Future<void> start() async {
    if (_started) {
      debugPrint('Already started');
      return;
    }
    if (!_bleAvailable && !_udpAvailable) {
      debugPrint('Cannot start: no transports available');
      return;
    }

    debugPrint('Starting Grassroots transport');

    // Start BLE if available
    if (_bleAvailable) {
      try {
        await _bleService!.start();
        debugPrint('BLE transport started');
      } catch (e) {
        debugPrint('Failed to start BLE: $e');
      }
    }

    // Start UDP if available
    if (_udpAvailable) {
      try {
        await _udpService!.start();
        debugPrint('UDP transport started');
      } catch (e) {
        debugPrint('Failed to start UDP: $e');
      }
    }

    _started = true;
    _startAnnounceTimer();
    _startScanTimer();
    if (_udpAvailable) {
      _resetRendezvousBackoff();
      unawaited(_syncConfiguredRendezvous(reason: 'transport-started'));
    }
  }

  /// Stop scanning and advertising.
  Future<void> stop() async {
    if (!_started) return;

    debugPrint('Stopping Grassroots transport');
    _started = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    _scanTimer?.cancel();
    _scanTimer = null;
    _bleFriendAnnounceSent.clear();

    if (_bleService != null) {
      try {
        await _bleService!.stop();
      } catch (e) {
        debugPrint('Error stopping BLE: $e');
      }
    }

    if (_udpService != null) {
      try {
        await _udpService!.stop();
      } catch (e) {
        debugPrint('Error stopping UDP: $e');
      }
    }
  }

  /// Handle transport settings changes.
  /// Serializes updates so overlapping init/dispose sequences cannot occur.
  void _onTransportSettingsChanged(
    SettingsState previousSettings,
    SettingsState currentSettings,
  ) {
    debugPrint('Transport settings changed');
    final previous = _transportUpdateLock ?? Future.value();
    _transportUpdateLock = previous.then(
      (_) => _updateTransportsFromSettings(
        previousSettings: previousSettings,
        currentSettings: currentSettings,
      ),
    );
  }

  static Uint8List _hexToBytes(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  _RendezvousConfig? _parseRendezvousConfig({
    required String address,
    required String pubkeyHex,
  }) {
    final normalizedAddress = _normalizeAnnouncedUdpAddress(
      address,
      context: 'rendezvous',
    );
    if (normalizedAddress == null) {
      debugPrint('[rendezvous] Ignoring invalid configured address: $address');
      return null;
    }

    try {
      final normalizedPubkeyHex = pubkeyHex.toLowerCase();
      return _RendezvousConfig(
        address: normalizedAddress,
        pubkey: _hexToBytes(normalizedPubkeyHex),
        pubkeyHex: normalizedPubkeyHex,
      );
    } catch (e) {
      debugPrint('[rendezvous] Ignoring invalid configured pubkey: $e');
      return null;
    }
  }

  List<_RendezvousConfig> _configuredRendezvousServers([
    SettingsState? settings,
  ]) {
    final configured = settings ?? store.state.settings;
    final configs = <_RendezvousConfig>[];
    final seen = <String>{};

    for (final server in configured.configuredRendezvousServers) {
      final parsed = _parseRendezvousConfig(
        address: server.address,
        pubkeyHex: server.pubkeyHex,
      );
      if (parsed == null) continue;

      final key = _rendezvousConfigKey(parsed);
      if (seen.add(key)) {
        configs.add(parsed);
      }
    }

    return configs;
  }

  _RendezvousConfig? _configuredRendezvousForPubkeyHex(
    String pubkeyHex, {
    SettingsState? settings,
  }) {
    for (final config in _configuredRendezvousServers(settings)) {
      if (config.pubkeyHex == pubkeyHex) {
        return config;
      }
    }
    return null;
  }

  bool _hasConfiguredRendezvousServer(
    _RendezvousConfig config, {
    SettingsState? settings,
  }) {
    final targetKey = _rendezvousConfigKey(config);
    for (final existing in _configuredRendezvousServers(settings)) {
      if (_rendezvousConfigKey(existing) == targetKey) {
        return true;
      }
    }
    return false;
  }

  bool _isRendezvousPubkeyHex(String pubkeyHex, {SettingsState? settings}) {
    return shouldAcceptRendezvousReply(
      pubkeyHex,
      settings: settings ?? store.state.settings,
      pendingResponsePubkeys: _rendezvousResponseWaiters.keys,
    );
  }

  String _rendezvousConfigKey(_RendezvousConfig config) =>
      '${config.pubkeyHex}@${config.address}';

  bool _canDialUdpAddress(AddressInfo address) =>
      _udpService != null &&
      _udpAvailable &&
      _udpService!.canDialAddress(address.ip);

  void _resetRendezvousBackoff([String? configKey]) {
    if (configKey == null) {
      _rendezvousRetryAfter.clear();
      _rendezvousLastFailureKind.clear();
      _lastRendezvousSuppressionLogKey.clear();
      return;
    }

    _rendezvousRetryAfter.remove(configKey);
    _rendezvousLastFailureKind.remove(configKey);
    _lastRendezvousSuppressionLogKey.remove(configKey);
  }

  void _logRendezvousSuppression(String configKey, String key, String message) {
    if (_lastRendezvousSuppressionLogKey[configKey] == key) return;
    _lastRendezvousSuppressionLogKey[configKey] = key;
    debugPrint(message);
  }

  Duration? _rendezvousBackoffForFailure(UdpConnectFailureKind? failureKind) {
    switch (failureKind) {
      case UdpConnectFailureKind.networkUnreachable:
        return _rendezvousNetworkUnreachableBackoff;
      case UdpConnectFailureKind.handshakeTimeout:
        return _rendezvousHandshakeTimeoutBackoff;
      case UdpConnectFailureKind.other:
      case null:
        return null;
    }
  }

  String _describeRendezvousFailure(UdpConnectFailureKind? failureKind) {
    switch (failureKind) {
      case UdpConnectFailureKind.networkUnreachable:
        return 'no usable UDP route';
      case UdpConnectFailureKind.handshakeTimeout:
        return 'UDX handshake timed out';
      case UdpConnectFailureKind.other:
      case null:
        return 'connect failed';
    }
  }

  bool _isRendezvousBackoffActive(_RendezvousConfig rendezvous, String reason) {
    final configKey = _rendezvousConfigKey(rendezvous);
    final retryAfter = _rendezvousRetryAfter[configKey];
    if (retryAfter == null) return false;

    final remaining = retryAfter.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _rendezvousRetryAfter.remove(configKey);
      _lastRendezvousSuppressionLogKey.remove(configKey);
      return false;
    }

    _logRendezvousSuppression(
      configKey,
      'cooldown:${_rendezvousLastFailureKind[configKey] ?? "unknown"}',
      '[rendezvous] Skipping $reason — '
          '${_describeRendezvousFailure(_rendezvousLastFailureKind[configKey])}; '
          'retrying in ${remaining.inSeconds}s',
    );
    return true;
  }

  Future<bool> _enqueueRendezvousTask(Future<bool> Function() task) {
    final completer = Completer<bool>();
    _rendezvousTaskQueue = _rendezvousTaskQueue.catchError((_) {}).then((
      _,
    ) async {
      try {
        completer.complete(await task());
      } catch (e) {
        debugPrint('[rendezvous] Task failed: $e');
        completer.complete(false);
      }
    });
    return completer.future;
  }

  void _completeRendezvousResponseWaiters(String pubkeyHex) {
    final waiters = _rendezvousResponseWaiters.remove(pubkeyHex);
    if (waiters == null) return;

    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }

  void _removeRendezvousResponseWaiter(
    String pubkeyHex,
    Completer<void> waiter,
  ) {
    final waiters = _rendezvousResponseWaiters[pubkeyHex];
    if (waiters == null) return;
    waiters.remove(waiter);
    if (waiters.isEmpty) {
      _rendezvousResponseWaiters.remove(pubkeyHex);
    }
  }

  Future<bool> _verifyRendezvousServerResponds(
    _RendezvousConfig config, {
    Duration timeout = const Duration(seconds: 8),
    String reason = 'settings-save',
  }) async {
    final waiter = Completer<void>();
    _rendezvousResponseWaiters
        .putIfAbsent(config.pubkeyHex, () => <Completer<void>>{})
        .add(waiter);

    try {
      final synced = await _syncConfiguredRendezvous(
        config: config,
        reason: reason,
      );
      if (!synced) {
        return false;
      }

      await waiter.future.timeout(timeout);
      return true;
    } on TimeoutException {
      debugPrint(
        '[rendezvous] Timed out waiting for server response '
        '(${config.pubkeyHex.substring(0, 8)}...)',
      );
      return false;
    } finally {
      _removeRendezvousResponseWaiter(config.pubkeyHex, waiter);
    }
  }

  Future<bool> _syncConfiguredRendezvous({
    List<_RendezvousConfig>? configs,
    _RendezvousConfig? config,
    String reason = 'sync',
  }) async {
    final targets = config != null
        ? <_RendezvousConfig>[config]
        : (configs ?? _configuredRendezvousServers());
    if (targets.isEmpty) {
      return Future.value(false);
    }

    final results = <bool>[];
    for (final rendezvous in targets) {
      final configKey = _rendezvousConfigKey(rendezvous);
      final inFlight = _rendezvousSyncInFlight[configKey];
      if (inFlight != null) {
        results.add(await inFlight);
        continue;
      }

      late final Future<bool> syncFuture;
      syncFuture = _enqueueRendezvousTask(() async {
        if (_udpService == null || !_udpAvailable) {
          debugPrint('[rendezvous] Cannot $reason — UDP unavailable');
          return false;
        }

        final rendezvousAddress = _parseSupportedUdpAddress(
          rendezvous.address,
          context: 'rendezvous',
        );
        if (rendezvousAddress == null) {
          return false;
        }

        if (!_canDialUdpAddress(rendezvousAddress)) {
          _logRendezvousSuppression(
            configKey,
            'no-route:${rendezvousAddress.ip.type.name}',
            '[rendezvous] Skipping $reason for '
                '${rendezvous.pubkeyHex.substring(0, 8)}... — no usable '
                '${rendezvousAddress.ip.type == InternetAddressType.IPv6 ? "IPv6" : "IPv4"} route',
          );
          return false;
        }

        if (_isRendezvousBackoffActive(rendezvous, reason)) {
          return false;
        }

        _lastRendezvousSuppressionLogKey.remove(configKey);

        final announce = await _createSignedAnnounce(address: udpAddress);
        if (await _udpService!.sendToPeer(rendezvous.pubkeyHex, announce)) {
          _resetRendezvousBackoff(configKey);
          debugPrint(
            '[rendezvous] Re-announced via existing session '
            '(${rendezvous.pubkeyHex.substring(0, 8)}..., $reason)',
          );
          return true;
        }

        final success = await _sendViaUdp(
          rendezvous.pubkeyHex,
          rendezvous.address,
          announce,
          isRendezvous: true,
        );
        if (success) {
          _resetRendezvousBackoff(configKey);
          debugPrint(
            '[rendezvous] Connected and announced '
            '(${rendezvous.pubkeyHex.substring(0, 8)}..., $reason)',
          );
          return true;
        }

        final failureKind = _udpService!.lastConnectFailureKind;
        _rendezvousLastFailureKind[configKey] = failureKind;
        final backoff = _rendezvousBackoffForFailure(failureKind);
        if (backoff != null) {
          _rendezvousRetryAfter[configKey] = DateTime.now().add(backoff);
          debugPrint(
            '[rendezvous] Failed to connect '
            '(${rendezvous.pubkeyHex.substring(0, 8)}..., $reason): '
            '${_describeRendezvousFailure(failureKind)}; '
            'backing off for ${backoff.inSeconds}s',
          );
        } else {
          debugPrint(
            '[rendezvous] Failed to connect '
            '(${rendezvous.pubkeyHex.substring(0, 8)}..., $reason)',
          );
        }
        return false;
      }).whenComplete(() {
        if (identical(_rendezvousSyncInFlight[configKey], syncFuture)) {
          _rendezvousSyncInFlight.remove(configKey);
        }
      });

      _rendezvousSyncInFlight[configKey] = syncFuture;
      results.add(await syncFuture);
    }

    return results.any((result) => result);
  }

  Future<bool> _disconnectConfiguredRendezvous({
    List<_RendezvousConfig>? configs,
    _RendezvousConfig? config,
    String reason = 'disconnect',
  }) async {
    final targets = config != null
        ? <_RendezvousConfig>[config]
        : (configs ?? _configuredRendezvousServers());
    if (targets.isEmpty) {
      return Future.value(false);
    }

    final results = <bool>[];
    for (final rendezvous in targets) {
      results.add(
        await _enqueueRendezvousTask(() async {
          if (_udpService == null) return false;
          if (_udpService!.getPeerIdForPubkey(rendezvous.pubkey) == null) {
            return false;
          }

          debugPrint(
            '[rendezvous] Closing UDP session '
            '(${rendezvous.pubkeyHex.substring(0, 8)}..., $reason)',
          );
          await _udpService!.disconnectFromPeer(rendezvous.pubkeyHex);
          return true;
        }),
      );
    }

    return results.any((result) => result);
  }

  Future<void> _handleRendezvousSettingsChange({
    required SettingsState previousSettings,
    required SettingsState currentSettings,
  }) async {
    final previousRendezvous = _configuredRendezvousServers(previousSettings);
    final currentRendezvous = _configuredRendezvousServers(currentSettings);

    final previousByKey = <String, _RendezvousConfig>{
      for (final config in previousRendezvous)
        _rendezvousConfigKey(config): config,
    };
    final currentByKey = <String, _RendezvousConfig>{
      for (final config in currentRendezvous)
        _rendezvousConfigKey(config): config,
    };

    final removed = <_RendezvousConfig>[];
    for (final entry in previousByKey.entries) {
      if (!currentByKey.containsKey(entry.key)) {
        removed.add(entry.value);
      }
    }

    final added = <_RendezvousConfig>[];
    for (final entry in currentByKey.entries) {
      if (!previousByKey.containsKey(entry.key)) {
        added.add(entry.value);
      }
    }

    if (removed.isEmpty && added.isEmpty) return;

    for (final rendezvous in removed) {
      _resetRendezvousBackoff(_rendezvousConfigKey(rendezvous));
    }

    if (removed.isNotEmpty) {
      await _disconnectConfiguredRendezvous(
        configs: removed,
        reason: 'settings-changed',
      );
    }

    if (added.isNotEmpty && _udpService != null && _udpAvailable) {
      await _syncConfiguredRendezvous(configs: added, reason: 'settings-saved');
    }

    // Friends rely on us to tell them which RV agents to contact when we
    // disappear. Re-broadcast whenever the list changes.
    debugPrint("Broadcasting RV list to friends");
    _broadcastRvListToFriends();
  }

  void _seedConnectivityState() {
    unawaited(() async {
      try {
        final results = await Connectivity().checkConnectivity();
        final ipResults = _normalizeConnectivityResults(results);
        _lastConnectivityResults ??= ipResults;
        store.dispatch(
          NetworkConnectionTypeUpdatedAction(
            _connectionTypeFromResults(ipResults),
          ),
        );
      } catch (e) {
        debugPrint('Failed to read initial connectivity state: $e');
      }
    }());
  }

  List<ConnectivityResult> _normalizeConnectivityResults(
    List<ConnectivityResult> results,
  ) {
    final ipResults =
        results.where((r) => r != ConnectivityResult.bluetooth).toList();
    if (ipResults.isEmpty) {
      return [ConnectivityResult.none];
    }
    return ipResults;
  }

  NetworkConnectionType _connectionTypeFromResults(
    List<ConnectivityResult> results,
  ) {
    if (results.contains(ConnectivityResult.none)) {
      return NetworkConnectionType.offline;
    }
    if (results.contains(ConnectivityResult.wifi)) {
      return NetworkConnectionType.wifi;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return NetworkConnectionType.cellular;
    }
    if (results.contains(ConnectivityResult.ethernet)) {
      return NetworkConnectionType.ethernet;
    }
    if (results.contains(ConnectivityResult.vpn)) {
      return NetworkConnectionType.vpn;
    }
    return NetworkConnectionType.other;
  }

  void _clearDiscoveredPublicConnectivity() {
    _publicAddressDiscoveryGeneration++;
    _publicAddress = null;
    _linkLocalAddress = null;
    _publicAddressCandidates = const {};
    _publicAddressDiscovery.invalidateCache();
    _publicAddressDiscoveryFuture = null;
    store.dispatch(ClearPublicConnectivityAction());
  }

  /// Handle network connectivity changes (WiFi ↔ cellular, etc.).
  ///
  /// When the network changes, our UDP socket is bound to the old interface
  /// and all UDX connections are dead. We need to:
  /// 1. Tear down the old UDP service (dead socket, dead connections)
  /// 2. Re-initialize with a new socket on the new interface
  /// 3. Re-discover public address (new IP from new network)
  /// 4. Re-register with well-connected friends
  /// 5. Re-connect to known peers
  ///
  /// Well-connected friends are reachable directly (public IP, no NAT),
  /// so we can always reconnect to them without a third party.
  void _onConnectivityChanged(List<ConnectivityResult> results) {
    // Filter out irrelevant connection types like bluetooth
    // which just indicate a BLE device connected/disconnected, not an IP network change.
    // If we don't filter this, every BLE connection change tears down the UDP transport!
    final ipResults = _normalizeConnectivityResults(results);
    store.dispatch(
      NetworkConnectionTypeUpdatedAction(_connectionTypeFromResults(ipResults)),
    );

    // Ignore the first notification (initial state, not a change)
    if (_lastConnectivityResults == null) {
      _lastConnectivityResults = ipResults;
      return;
    }

    // Ignore if nothing meaningful changed
    if (_connectivityResultsEqual(_lastConnectivityResults!, ipResults)) return;
    _lastConnectivityResults = ipResults;
    _clearDiscoveredPublicConnectivity();

    // If we lost all connectivity, nothing to do — connections will fail naturally.
    if (ipResults.contains(ConnectivityResult.none)) {
      debugPrint('Network lost — UDP connections will fail');
      return;
    }

    if (!_isUdpEnabledInSettings) {
      debugPrint(
        'Network changed while UDP is disabled — cleared cached '
        'public connectivity and will rediscover on re-enable',
      );
      return;
    }

    debugPrint(
      'Network changed: $ipResults (raw: $results) — restarting UDP transport',
    );

    // Serialize with other transport updates to prevent overlapping init/dispose
    final previous = _transportUpdateLock ?? Future.value();
    _transportUpdateLock = previous.then(
      (_) => _restartUdpAfterNetworkChange(),
    );
  }

  /// Restart UDP transport after a network change.
  Future<void> _restartUdpAfterNetworkChange() async {
    if (!_isUdpEnabledInSettings) return;
    if (!_started) return;

    // Remember friends with UDP addresses so we can re-establish UDP sessions.
    final udpFriends = _peersState.friends
        .where(
          (peer) => _udpCandidatesForPeer(peer).isNotEmpty,
        )
        .toList()
      ..sort((a, b) {
        if (a.isWellConnected == b.isWellConnected) return 0;
        return a.isWellConnected ? -1 : 1;
      });

    for (final completer in _holePunchCompleters.values) {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    }
    _holePunchCompleters.clear();
    _holePunchTargets.clear();
    _holePunchLocalReady.clear();
    _holePunchRemoteReady.clear();
    _holePunchConnectionInProgress.clear();

    // Tear down old UDP service completely
    for (final service in _holePunchServices.values) {
      service.dispose();
    }
    _holePunchServices.clear();

    if (_udpService != null) {
      await _udpService!.dispose();
      _udpService = null;
    }

    _clearDiscoveredPublicConnectivity();
    store.dispatch(
      UdpTransportStateChangedAction(TransportState.uninitialized),
    );

    // Mark UDP peers as disconnected (connections are dead)
    for (final peer in _peersState.peersList) {
      if (_udpCandidatesForPeer(peer).isNotEmpty) {
        store.dispatch(PeerUdpDisconnectedAction(peer.publicKey));
      }
    }

    // Re-initialize UDP on the new network interface
    final success = await _initializeUdp();
    if (!success) {
      debugPrint('Failed to re-initialize UDP after network change');
      return;
    }

    if (_udpAvailable) {
      await _udpService!.start();
    }

    await _waitForPublicUdpAddress();

    debugPrint(
      'UDP restarted after network change, re-connecting to ${udpFriends.length} friends',
    );

    for (final friend in udpFriends) {
      final candidates = _udpCandidatesForPeer(friend);
      final friendAddress = friend.udpAddress ??
          (candidates.isNotEmpty ? candidates.first : null);
      if (friendAddress == null) continue;
      await _connectToFriendViaUdp(friend.pubkeyHex, friendAddress);
    }

    // Fan out RECONNECT for friends still unreachable. The facilitator(s)
    // will pair this with the friend's AVAILABLE (which the friend sends
    // when its keepalive for us expires) and coordinate a hole-punch.
    final facilitatorCount = store.state.peers.wellConnectedFriends.length +
        _configuredRendezvousServers().length;
    if (facilitatorCount == 0) return;

    for (final friend in udpFriends) {
      if (_udpService?.getPeerIdForPubkey(friend.publicKey) != null) continue;
      debugPrint(
        '[reconnect] Fanning out RECONNECT for ${friend.displayName} '
        'after IP change',
      );
      unawaited(_signalingService.fanOutReconnect(friend.publicKey));
    }
  }

  /// Check if two connectivity result lists are equivalent.
  static bool _connectivityResultsEqual(
    List<ConnectivityResult> a,
    List<ConnectivityResult> b,
  ) {
    if (a.length != b.length) return false;
    final sortedA = List<ConnectivityResult>.from(a)
      ..sort((x, y) => x.index - y.index);
    final sortedB = List<ConnectivityResult>.from(b)
      ..sort((x, y) => x.index - y.index);
    for (var i = 0; i < sortedA.length; i++) {
      if (sortedA[i] != sortedB[i]) return false;
    }
    return true;
  }

  /// Update transports based on current settings
  Future<void> _updateTransportsFromSettings({
    required SettingsState previousSettings,
    required SettingsState currentSettings,
  }) async {
    final wasStarted = _started;

    // Handle BLE enable/disable
    if (_isBleEnabledInSettings && !_bleAvailable) {
      // BLE was enabled, try to initialize
      // Dispose old service first to clean up native state (GATT server, subscriptions)
      if (_bleService != null) {
        debugPrint('Disposing old BLE service before re-initialization');
        await _bleService!.dispose();
        _bleService = null;
      }
      await _initializeBle();
      if (wasStarted && _bleAvailable) {
        await _bleService!.start();
      }
    } else if (!_isBleEnabledInSettings && _bleAvailable) {
      // BLE was disabled, dispose service and clean up
      debugPrint('BLE disabled from settings, cleaning up...');

      if (_bleService != null) {
        await _bleService!.dispose();
        _bleService = null;
      }

      // Reset Redux state so _bleAvailable returns false
      store.dispatch(
        BleTransportStateChangedAction(TransportState.uninitialized),
      );

      // Clear all discovered BLE peers from Redux
      store.dispatch(ClearDiscoveredBlePeersAction());

      // Disconnect all peers that were connected via BLE
      for (final peer in _peersState.peersList) {
        if (peer.hasBleConnection) {
          store.dispatch(PeerBleDisconnectedAction(peer.publicKey));
        }
      }

      debugPrint('BLE cleanup complete');
    }

    // Handle UDP enable/disable
    if (_isUdpEnabledInSettings && !_udpAvailable) {
      // UDP was enabled, try to initialize
      await _initializeUdp();
      if (wasStarted && _udpAvailable) {
        await _udpService!.start();
      }
    } else if (!_isUdpEnabledInSettings && _udpAvailable) {
      // UDP was disabled, dispose service and clean up
      debugPrint('UDP disabled from settings, cleaning up...');

      for (final service in _holePunchServices.values) {
        service.dispose();
      }
      _holePunchServices.clear();

      if (_udpService != null) {
        await _udpService!.dispose();
        _udpService = null;
      }

      _clearDiscoveredPublicConnectivity();

      // Reset Redux state so _udpAvailable returns false
      store.dispatch(
        UdpTransportStateChangedAction(TransportState.uninitialized),
      );

      // Disconnect all peers that were connected via UDP
      for (final peer in _peersState.peersList) {
        if (_udpCandidatesForPeer(peer).isNotEmpty) {
          store.dispatch(PeerUdpDisconnectedAction(peer.publicKey));
        }
      }

      debugPrint('UDP cleanup complete');
    }

    await _handleRendezvousSettingsChange(
      previousSettings: previousSettings,
      currentSettings: currentSettings,
    );
  }

  // ===== Identity =====

  /// Update the user's nickname and broadcast to all peers
  Future<void> updateNickname(String newNickname) async {
    if (newNickname.isEmpty) return;

    debugPrint('Updating nickname to: $newNickname');
    identity.nickname = newNickname;

    // Broadcast ANNOUNCE with new nickname to all connected peers
    await _broadcastAnnounce();
  }

  /// Apply a debug change to which BLE roles this device runs.
  /// Dispatches a Redux action and restarts the BLE transport so the new
  /// mode takes effect immediately.
  Future<void> setBleRoleMode(BleRoleMode mode) async {
    if (store.state.settings.bleRoleMode == mode) return;
    store.dispatch(SetBleRoleModeAction(mode));
    await _bleService?.applyRoleModeChange();
  }

  static const _uuid = Uuid();

  // ===== Messaging =====

  /// Send a message to a specific peer.
  ///
  /// Routes through the best available transport:
  /// 1. Bluetooth (if peer is nearby and BLE is enabled)
  /// 2. UDP (if peer has UDP address and UDP is enabled)
  ///
  /// Returns the message ID if sent successfully, null if failed.
  /// The message status can be tracked via store.state.messages.
  ///
  /// Transport selection: tries BLE first (preferred for nearby peers),
  /// falls back to UDP, then attempts discovery via well-connected friends.
  /// Delivery is confirmed by an application-level ACK, not the transport write.
  Future<String?> send(
    Uint8List recipientPubkey,
    Uint8List payload, {
    String? messageId,
  }) async {
    final peer = _peersState.getPeerByPubkey(recipientPubkey);
    if (peer == null) {
      debugPrint('Cannot send: peer not found');
      return null;
    }

    // Use provided message ID or generate one
    messageId ??= _uuid.v4().substring(0, 8);

    // Dispatch sending action (clock icon)
    store.dispatch(
      MessageSendingAction(
        messageId: messageId,
        transport: MessageTransport.ble, // Tentative — updated on actual send
        recipientPubkey: recipientPubkey,
        payloadSize: payload.length,
      ),
    );

    // Create the message packet and sign it once
    final packet = _protocolHandler.createMessagePacket(
      payload: payload,
      recipientPubkey: recipientPubkey,
    );
    if (!_fragmentHandler.needsFragmentation(payload)) {
      await _protocolHandler.signPacket(packet);
    }

    final bytes = packet.serialize();

    // --- Try BLE first (preferred for nearby peers) ---
    final bleDeviceId = _connectedBleDeviceIdForPeer(peer);
    if (_isBleEnabledInSettings &&
        _bleAvailable &&
        _bleService != null &&
        bleDeviceId != null) {
      debugPrint('Sending via BLE to ${peer.displayName}');

      bool success;
      if (_fragmentHandler.needsFragmentation(payload)) {
        success = await _sendFragmentedViaBle(
          payload: payload,
          recipientPubkey: recipientPubkey,
          bleDeviceId: bleDeviceId,
        );
      } else {
        success = await _bleService!.sendToPeer(bleDeviceId, bytes);
      }

      if (success) {
        store.dispatch(
          MessageSentAction(
            messageId: messageId,
            transport: MessageTransport.ble,
            recipientPubkey: recipientPubkey,
            payloadSize: payload.length,
          ),
        );
        // Delivery confirmed by ACK, not BLE write success.
        return messageId;
      }
      debugPrint('BLE send failed, falling back to UDP...');
    }

    // --- Try UDP (direct connection or connect-on-demand) ---
    if (_isUdpEnabledInSettings && _udpAvailable && _udpService != null) {
      // Re-read peer — state may have changed during BLE attempt.
      final resolvedPeer = _peersState.getPeerByPubkey(recipientPubkey) ?? peer;

      // Try existing UDX connection first
      if (await _udpService!.sendToPeer(resolvedPeer.pubkeyHex, bytes)) {
        debugPrint(
          'Sent via existing UDP connection to ${resolvedPeer.displayName}',
        );
        store.dispatch(
          MessageSentAction(
            messageId: messageId,
            transport: MessageTransport.udp,
            recipientPubkey: recipientPubkey,
            payloadSize: payload.length,
          ),
        );
        return messageId;
      }

      // No existing connection — try connect-on-demand if we have an address
      final udpCandidates = _udpCandidatesForPeer(resolvedPeer);
      if (udpCandidates.isNotEmpty) {
        final udpAddr = resolvedPeer.udpAddress ?? udpCandidates.first;
        debugPrint(
          'Sending via UDP to ${resolvedPeer.displayName} at $udpCandidates',
        );
        if (await _sendViaUdp(resolvedPeer.pubkeyHex, udpAddr, bytes)) {
          store.dispatch(
            MessageSentAction(
              messageId: messageId,
              transport: MessageTransport.udp,
              recipientPubkey: recipientPubkey,
              payloadSize: payload.length,
            ),
          );
          return messageId;
        }
      }

      // No address — try discovery via well-connected friends
      if (resolvedPeer.isFriend) {
        debugPrint(
          '[send] No direct path to ${resolvedPeer.displayName}, '
          'attempting discovery via well-connected friends...',
        );
        final discovered = await _discoverPeerViaFriends(resolvedPeer);
        if (discovered) {
          // Re-read peer — discovery updated the address
          final freshPeer = _peersState.getPeerByPubkey(recipientPubkey);
          final freshCandidates = _udpCandidatesForPeer(freshPeer);
          if (freshPeer != null && freshCandidates.isNotEmpty) {
            debugPrint('[send] Discovery succeeded, sending via UDP');
            if (await _sendViaUdp(
              freshPeer.pubkeyHex,
              freshPeer.udpAddress ?? freshCandidates.first,
              bytes,
            )) {
              store.dispatch(
                MessageSentAction(
                  messageId: messageId,
                  transport: MessageTransport.udp,
                  recipientPubkey: recipientPubkey,
                  payloadSize: payload.length,
                ),
              );
              return messageId;
            }
          }
        }
        debugPrint('[send] Discovery failed for ${resolvedPeer.displayName}');
      }
    }

    // All transports failed
    store.dispatch(MessageFailedAction(messageId: messageId));
    debugPrint('All transports failed to send message to ${peer.displayName}');
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
      final bleDeviceId = _connectedBleDeviceIdForPeer(peer);
      if (peer != null && bleDeviceId != null) {
        if (await _bleService!.sendToPeer(bleDeviceId, bytes)) return true;
      }
    }

    // Fall back to UDP
    if (_isUdpEnabledInSettings && _udpAvailable && _udpService != null) {
      final udpCandidates = _udpCandidatesForPeer(peer);
      if (peer != null && udpCandidates.isNotEmpty) {
        if (await _sendViaUdp(
          peer.pubkeyHex,
          peer.udpAddress ?? udpCandidates.first,
          bytes,
        )) {
          return true;
        }
      }
    }

    debugPrint('No transport available to send read receipt');
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
        debugPrint('BLE broadcast failed: $e');
      }
    }

    // Broadcast via UDP (no size limit)
    if (_isUdpEnabledInSettings && _udpAvailable && _udpService != null) {
      try {
        await _udpService!.broadcast(bytes);
      } catch (e) {
        debugPrint('UDP broadcast failed: $e');
      }
    }
  }

  // ===== Public Address Discovery =====

  /// Discover our public UDP address and combine it with the bound UDP port.
  Future<void> _discoverPublicAddress() async {
    final udpService = _udpService;
    final discoveryGeneration = _publicAddressDiscoveryGeneration;
    if (udpService == null || udpService.activeAddressTypes.isEmpty) return;
    final previousAddress = _publicAddress;
    final previousCandidates = _publicAddressCandidates;
    final discoveredCandidates = <String>{};

    for (final family in const [
      InternetAddressType.IPv6,
      InternetAddressType.IPv4,
    ]) {
      final localPort = udpService.localPortForAddressType(family);
      if (localPort == null) continue;

      final publicAddr = await _publicAddressDiscovery.getPublicAddress(
        localPort,
        type: family,
      );
      if (publicAddr != null) {
        discoveredCandidates.add(publicAddr);
      }
    }

    if (_publicAddressDiscoveryGeneration != discoveryGeneration ||
        _udpService != udpService ||
        !_isUdpEnabledInSettings) {
      return;
    }

    _publicAddressCandidates = normalizeAddressStrings(discoveredCandidates);
    final publicAddr = _preferredPublicAddress(_publicAddressCandidates);
    if (publicAddr != null) {
      _publicAddress = publicAddr;
      store.dispatch(PublicAddressUpdatedAction(publicAddr));
      debugPrint('Public UDP address: $_publicAddress');
      debugPrint('Public UDP candidates: $_publicAddressCandidates');
      if (publicAddr != previousAddress ||
          !setEquals(_publicAddressCandidates, previousCandidates)) {
        _resetRendezvousBackoff();
        unawaited(_syncConfiguredRendezvous(reason: 'public-address-updated'));
      }
    } else {
      debugPrint(
        'Could not discover a public UDP address. '
        'No UDP address will be advertised.',
      );
    }

    // Always update the display IP (even if no full address/port available).
    final bestIp = _publicAddressDiscovery.bestPublicIp;
    if (bestIp != null) {
      store.dispatch(PublicIpUpdatedAction(bestIp.address));
    }

    // Discover link-local IPv6 for same-LAN fallback.
    final ipv6Port = udpService.localPortForAddressType(
      InternetAddressType.IPv6,
    );
    final llAddr = ipv6Port != null
        ? await _publicAddressDiscovery.getLinkLocalAddress(ipv6Port)
        : null;
    if (_publicAddressDiscoveryGeneration != discoveryGeneration ||
        _udpService != udpService ||
        !_isUdpEnabledInSettings) {
      return;
    }
    if (llAddr != null) {
      _linkLocalAddress = llAddr;
      debugPrint('Link-local UDP address: $_linkLocalAddress');
    }
  }

  Future<void> _waitForPublicUdpAddress({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final inFlight = _publicAddressDiscoveryFuture;
    if (inFlight == null) return;
    try {
      await inFlight.timeout(timeout);
    } catch (_) {}
  }

  String? _preferredPublicAddress(Set<String> candidates) {
    String? ipv4;
    for (final candidate in candidates) {
      final parsed = parseAddressString(candidate);
      if (parsed == null || parsed.ip.isLinkLocal) continue;
      if (parsed.ip.type == InternetAddressType.IPv6) {
        return parsed.toAddressString();
      }
      if (parsed.ip.type == InternetAddressType.IPv4) {
        ipv4 ??= parsed.toAddressString();
      }
    }
    return ipv4;
  }

  AddressInfo? _parseSupportedUdpAddress(
    String udpAddress, {
    required String context,
    String? peerLabel,
  }) {
    final parsed = parseAddressString(udpAddress);
    if (parsed != null) return parsed;
    final label = peerLabel != null ? ' for $peerLabel' : '';
    debugPrint('[$context] Invalid UDP address$label: $udpAddress');
    return null;
  }

  String? _normalizeAnnouncedUdpAddress(
    String? udpAddress, {
    required String context,
  }) {
    if (udpAddress == null || udpAddress.isEmpty) return null;
    final parsed = _parseSupportedUdpAddress(udpAddress, context: context);
    return parsed?.toAddressString();
  }

  String? _normalizeAnnouncedLinkLocalAddress(
    String? udpAddress, {
    required String context,
  }) {
    if (udpAddress == null || udpAddress.isEmpty) return null;

    final parsed = parseIpv6AddressString(udpAddress);
    if (parsed == null) {
      debugPrint(
        '[$context] Ignoring non-link-local IPv6 address in link-local '
        'ANNOUNCE field: $udpAddress',
      );
      return null;
    }

    if (!parsed.ip.isLinkLocal) {
      debugPrint(
        '[$context] Ignoring non-link-local address in link-local '
        'ANNOUNCE field: $udpAddress',
      );
      return null;
    }

    return parsed.toAddressString();
  }

  String? _connectedBleDeviceIdForPeer(PeerState? peer) {
    if (peer == null || _bleService == null || !_bleAvailable) {
      return null;
    }

    final centralId = peer.bleCentralDeviceId;
    if (centralId != null && _bleService!.isDeviceConnected(centralId)) {
      return centralId;
    }

    final peripheralId = peer.blePeripheralDeviceId;
    if (peripheralId != null && _bleService!.isDeviceConnected(peripheralId)) {
      return peripheralId;
    }

    return null;
  }

  bool _hasLiveBlePath(PeerState? peer) =>
      _connectedBleDeviceIdForPeer(peer) != null;

  HolePunchService? _holePunchServiceFor(InternetAddress address) =>
      _holePunchServices[address.type];

  Set<String> _candidateAddresses({bool includeLinkLocal = false}) =>
      normalizeAddressStrings([
        ..._publicAddressCandidates,
        if (_publicAddress != null) _publicAddress,
        if (includeLinkLocal && _linkLocalAddress != null) _linkLocalAddress,
      ]);

  Set<String> _connectionLocalCandidates() {
    final candidates = _candidateAddresses(includeLinkLocal: true);
    final udpService = _udpService;
    if (udpService == null) return candidates;

    for (final family in udpService.activeAddressTypes) {
      final hasFamily = candidates.any((address) {
        final parsed = parseAddressString(address);
        return parsed?.ip.type == family;
      });
      if (hasFamily) continue;

      final port = udpService.localPortForAddressType(family);
      if (port == null) continue;
      final bindAddress = family == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4;
      candidates.add(AddressInfo(bindAddress, port).toAddressString());
    }

    return candidates;
  }

  Set<String> _udpCandidatesForPeer(
    PeerState? peer, {
    String? fallbackAddress,
  }) =>
      normalizeAddressStrings([
        peer?.linkLocalAddress,
        peer?.udpAddress,
        if (peer != null) ...peer.udpAddressCandidates,
        fallbackAddress,
      ]);

  AddressInfo? _selectUdpRemoteCandidate(
    Set<String> remoteCandidates, {
    required String context,
    String? peerLabel,
  }) {
    final local = parseAddressCandidates(_connectionLocalCandidates());
    final remote = parseAddressCandidates(remoteCandidates);
    final pair = _connectionService.selectBestPair(
      localCandidates: local,
      remoteCandidates: remote,
    );
    if (pair == null) {
      final label = peerLabel != null ? ' for $peerLabel' : '';
      debugPrint('[$context] No compatible UDP candidate pair$label: '
          'local=${local.map((e) => e.toAddressString()).toSet()}, '
          'remote=$remoteCandidates');
      return null;
    }
    return pair.remote;
  }

  Future<Uint8List> _createSignedSignalingPacket(
    Uint8List recipientPubkey,
    Uint8List signalingPayload,
  ) async {
    final packet = GrassrootsPacket(
      type: PacketType.signaling,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: signalingPayload,
      signature: Uint8List(64),
    );
    await _protocolHandler.signPacket(packet);
    return packet.serialize();
  }

  Future<bool> _sendDirectSignalingOverLiveBle(
    Uint8List recipientPubkey,
    Uint8List signalingPayload,
  ) async {
    if (_bleService == null || !_bleAvailable) {
      return false;
    }

    final pubkeyHex =
        recipientPubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final peer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);
    final deviceId = _connectedBleDeviceIdForPeer(peer);
    if (deviceId == null) {
      return false;
    }

    final bytes = await _createSignedSignalingPacket(
      recipientPubkey,
      signalingPayload,
    );
    return _bleService!.sendToPeer(deviceId, bytes);
  }

  Future<void> _sustainHolePunchTraffic(
    String peerHex,
    AddressInfo target, {
    required String phase,
  }) async {
    final punchService = _holePunchServiceFor(target.ip);
    if (punchService == null ||
        _holePunchKeepAliveInProgress.contains(peerHex)) {
      return;
    }

    _holePunchKeepAliveInProgress.add(peerHex);
    debugPrint(
      '[hole-punch] Sustaining punch traffic toward '
      '${target.toAddressString()} during $phase...',
    );
    try {
      await punchService.punch(
        target.ip,
        target.port,
        duration: _holePunchKeepAliveDuration,
      );
    } finally {
      _holePunchKeepAliveInProgress.remove(peerHex);
    }
  }

  void _beginHolePunchAttempt(String peerHex, {bool dispatchStarted = true}) {
    _holePunchTargets.remove(peerHex);
    _holePunchLocalReady.remove(peerHex);
    _holePunchRemoteReady.remove(peerHex);
    _holePunchConnectionInProgress.remove(peerHex);
    _holePunchKeepAliveInProgress.remove(peerHex);
    _holePunchCompleters.putIfAbsent(peerHex, () => Completer<bool>());
    if (dispatchStarted) {
      store.dispatch(HolePunchStartedAction(peerHex));
    }
  }

  void _clearHolePunchState(String peerHex, {bool clearCompleter = false}) {
    _holePunchTargets.remove(peerHex);
    _holePunchLocalReady.remove(peerHex);
    _holePunchRemoteReady.remove(peerHex);
    _holePunchConnectionInProgress.remove(peerHex);
    _holePunchKeepAliveInProgress.remove(peerHex);
    if (clearCompleter) {
      _holePunchCompleters.remove(peerHex);
    }
  }

  void _failHolePunchAttempt(String peerHex, String reason) {
    store.dispatch(HolePunchFailedAction(peerHex, reason));
    final completer = _holePunchCompleters.remove(peerHex);
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    }
    _clearHolePunchState(peerHex);
  }

  Future<void> _maybeEstablishPunchConnection(String peerHex) async {
    if (!_holePunchLocalReady.contains(peerHex) ||
        !_holePunchRemoteReady.contains(peerHex)) {
      return;
    }
    if (_holePunchConnectionInProgress.contains(peerHex)) {
      return;
    }

    final target = _holePunchTargets[peerHex];
    if (target == null) {
      debugPrint(
        '[hole-punch] Both sides are ready for $peerHex but no target '
        'address is cached yet.',
      );
      return;
    }

    final myPubkeyHex = identity.publicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final iAmInitiator = myPubkeyHex.compareTo(peerHex) < 0;
    if (!iAmInitiator) {
      unawaited(
        _sustainHolePunchTraffic(peerHex, target, phase: 'responder-wait'),
      );
      debugPrint(
        '[hole-punch] Both sides are ready; waiting for initiator '
        '$peerHex to connect.',
      );
      return;
    }
    if (_udpService == null) {
      _failHolePunchAttempt(
        peerHex,
        'UDP service unavailable during hole-punch connect',
      );
      return;
    }

    _holePunchConnectionInProgress.add(peerHex);
    debugPrint(
      '[hole-punch] Both sides ready; initiator connecting to '
      '${target.toAddressString()}...',
    );
    unawaited(
      _sustainHolePunchTraffic(peerHex, target, phase: 'initiator-connect'),
    );

    final announce = await _createSignedAnnounce(address: udpAddress);
    final connected = await _sendViaUdp(
      peerHex,
      target.toAddressString(),
      announce,
      allowBleAssistedFallback: false,
      performPreConnectPunch: false,
    );
    _holePunchConnectionInProgress.remove(peerHex);

    if (!connected) {
      _failHolePunchAttempt(
        peerHex,
        'UDX connection failed after both peers reported ready',
      );
    }
  }

  // ===== UDP Connect-on-Demand =====

  /// Send data to a peer via UDP, connecting first if needed.
  ///
  /// UdpTransportService requires an active UDX connection before sending.
  /// This method handles the connect → ANNOUNCE → send flow transparently.
  Future<bool> _sendViaUdp(
    String pubkeyHex,
    String udpAddress,
    Uint8List data, {
    bool isRendezvous = false,
    bool allowBleAssistedFallback = true,
    bool performPreConnectPunch = true,
  }) async {
    if (_udpService == null) return false;
    final peerShort = pubkeyHex.substring(0, 8);

    // Already connected? Send directly.
    if (await _udpService!.sendToPeer(pubkeyHex, data)) {
      debugPrint('[udp-send] Sent to $peerShort via existing connection');
      return true;
    }

    // Not connected — check if we should initiate or wait.
    // Only one side should call connectToPeer to avoid UDX simultaneous-open
    // (two independent socket pairs where data flows in only one direction).
    final myPubkeyHex = identity.publicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final iAmInitiator = myPubkeyHex.compareTo(pubkeyHex) < 0;
    final peer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);

    final remoteCandidates = _udpCandidatesForPeer(
      peer,
      fallbackAddress: udpAddress,
    );
    final addr = _selectUdpRemoteCandidate(
      remoteCandidates,
      context: 'udp-send',
      peerLabel: peerShort,
    );
    if (addr == null) {
      return false;
    }
    final selectedAddress = addr.toAddressString();

    if (!isRendezvous && !iAmInitiator) {
      // We're not the initiator — the other side should connect to us.
      // Wait briefly for their incoming connection to arrive.
      debugPrint(
        '[udp-send] Not initiator for $peerShort, waiting for incoming connection...',
      );
      for (var i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (await _udpService!.sendToPeer(pubkeyHex, data)) {
          debugPrint(
            '[udp-send] Incoming connection arrived, sent to $peerShort',
          );
          return true;
        }
      }
      // Timed out waiting — fall through and try connecting ourselves as last resort
      debugPrint(
        '[udp-send] Timed out waiting for incoming connection from $peerShort, connecting ourselves...',
      );
    }

    final inFlight = _udpConnectInFlight[pubkeyHex];
    if (inFlight != null) {
      debugPrint('[udp-send] Reusing in-flight UDX connect to $peerShort...');
      final connected = await inFlight;
      if (!connected) return false;
      return _udpService!.sendToPeer(pubkeyHex, data);
    }

    late final Future<bool> udxConnectFuture;
    udxConnectFuture = () async {
      // Hole-punch to open NAT mappings before UDX connection attempt.
      // Skip for peers with publicly routable addresses — punching is wasted
      // when no NAT mapping is needed. Using [hasPublicUdpAddress] (not the
      // verified [isWellConnected]) is intentional: skipping the punch is the
      // path by which we gain reachability evidence in the first place. If
      // the direct attempt fails, the caller's fallback path will retry with
      // a punch via signaling.
      if (performPreConnectPunch &&
          !isRendezvous &&
          _holePunchServiceFor(addr.ip) != null &&
          peer != null &&
          !peer.hasPublicUdpAddress) {
        debugPrint(
          '[udp-send] Hole-punching to $selectedAddress before connecting...',
        );
        await _holePunchServiceFor(addr.ip)!.punch(addr.ip, addr.port);
      }

      debugPrint('[udp-send] Connecting to $peerShort at $selectedAddress...');
      return _udpService!.connectToPeer(pubkeyHex, addr.ip, addr.port);
    }();
    _udpConnectInFlight[pubkeyHex] = udxConnectFuture;

    bool connected = false;
    try {
      connected = await udxConnectFuture;
    } finally {
      if (identical(_udpConnectInFlight[pubkeyHex], udxConnectFuture)) {
        _udpConnectInFlight.remove(pubkeyHex);
      }
    }

    if (connected) {
      debugPrint('[udp-send] Connected, sending data to $peerShort');
      // Send the data — the periodic ANNOUNCE cycle handles identity exchange
      return _udpService!.sendToPeer(pubkeyHex, data);
    }

    debugPrint(
        '[udp-send] UDX connect failed to $peerShort at $selectedAddress');

    if (allowBleAssistedFallback &&
        !isRendezvous &&
        peer != null &&
        peer.isFriend &&
        _hasLiveBlePath(peer)) {
      debugPrint(
        '[udp-send] Trying direct BLE-assisted hole-punch to $peerShort...',
      );
      return _attemptDirectPunchWithPeer(peer, addr);
    }

    return false;
  }

  /// Proactively establish a UDP connection to a friend.
  ///
  /// Called (fire-and-forget) when a friend's ANNOUNCE carries a UDP address
  /// and we don't yet have a live UDP connection to them. This keeps both
  /// transports active so disabling one doesn't lose the peer.
  ///
  /// Sends our own ANNOUNCE as the first message so the remote side learns
  /// our identity and address on the new UDP connection.
  Future<void> _connectToFriendViaUdp(
    String pubkeyHex,
    String udpAddress,
  ) async {
    final normalizedAddress =
        _normalizeAnnouncedUdpAddress(udpAddress, context: 'auto-udp') ??
            udpAddress;
    final peerShort = pubkeyHex.substring(0, 8);

    final retryAfter = _autoUdpRetryAfter[pubkeyHex];
    if (retryAfter != null &&
        _autoUdpLastAddress[pubkeyHex] == normalizedAddress &&
        DateTime.now().isBefore(retryAfter)) {
      debugPrint(
        '[auto-udp] Suppressing retry to $peerShort at '
        '$normalizedAddress until ${retryAfter.toIso8601String()}',
      );
      return;
    }

    final inFlight = _autoUdpConnectInFlight[pubkeyHex];
    if (inFlight != null) {
      debugPrint(
        '[auto-udp] Reusing in-flight proactive UDP attempt for '
        '$peerShort',
      );
      await inFlight;
      return;
    }

    _autoUdpLastAddress[pubkeyHex] = normalizedAddress;

    late final Future<void> task;
    task = () async {
      try {
        final announce = await _createSignedAnnounce(address: this.udpAddress);

        // Try link-local first when peer is BLE-nearby (same LAN).
        // Link-local avoids AP client isolation and NAT issues.
        final peer = _peersState.getPeerByPubkeyHex(pubkeyHex);
        final llAddr = peer?.linkLocalAddress;
        if (llAddr != null && _hasLiveBlePath(peer)) {
          debugPrint(
            '[auto-udp] Trying link-local $llAddr for '
            '${pubkeyHex.substring(0, 8)}...',
          );
          final llSuccess = await _sendViaUdp(pubkeyHex, llAddr, announce);
          if (llSuccess) {
            debugPrint(
              '[auto-udp] Connected via link-local to '
              '${pubkeyHex.substring(0, 8)}',
            );
            _autoUdpRetryAfter.remove(pubkeyHex);
            return;
          }
          debugPrint('[auto-udp] Link-local failed, trying global address...');
        }

        final success = await _sendViaUdp(
          pubkeyHex,
          normalizedAddress,
          announce,
        );
        if (success) {
          debugPrint(
            '[auto-udp] Proactive UDP connection to '
            '${pubkeyHex.substring(0, 8)} established',
          );
          _autoUdpRetryAfter.remove(pubkeyHex);
        } else {
          // Direct connection failed (likely NAT/firewall). Try coordinated
          // hole-punch via a well-connected friend if one is reachable.
          final peer = _peersState.getPeerByPubkeyHex(pubkeyHex);
          if (peer != null && peer.isFriend) {
            if (_hasLiveBlePath(peer)) {
              final addr = _parseSupportedUdpAddress(
                normalizedAddress,
                context: 'auto-udp',
                peerLabel: peer.displayName,
              );
              if (addr != null) {
                debugPrint(
                  '[auto-udp] Direct connect to '
                  '${pubkeyHex.substring(0, 8)} failed, trying direct BLE-assisted hole-punch...',
                );
                if (await _attemptDirectPunchWithPeer(peer, addr)) {
                  _autoUdpRetryAfter.remove(pubkeyHex);
                  return;
                }
              }
            }

            debugPrint(
              '[auto-udp] Direct connect to '
              '${pubkeyHex.substring(0, 8)} failed, trying hole-punch via friends...',
            );
            if (await _discoverPeerViaFriends(peer)) {
              _autoUdpRetryAfter.remove(pubkeyHex);
              return;
            }
          } else {
            debugPrint(
              '[auto-udp] Proactive UDP connection to '
              '${pubkeyHex.substring(0, 8)} failed',
            );
          }
          _autoUdpRetryAfter[pubkeyHex] = DateTime.now().add(
            _autoUdpRetryBackoff,
          );
        }
      } catch (e) {
        debugPrint(
          '[auto-udp] Error connecting to '
          '${pubkeyHex.substring(0, 8)}: $e',
        );
        _autoUdpRetryAfter[pubkeyHex] = DateTime.now().add(
          _autoUdpRetryBackoff,
        );
      }
    }();

    _autoUdpConnectInFlight[pubkeyHex] = task;
    try {
      await task;
    } finally {
      if (identical(_autoUdpConnectInFlight[pubkeyHex], task)) {
        _autoUdpConnectInFlight.remove(pubkeyHex);
      }
    }
  }

  /// Ask a BLE-connected friend to start punching toward us, then punch locally.
  ///
  /// This is a direct friend-to-friend fallback for the case where we already
  /// have a control channel (usually BLE) to the target, but direct UDX to
  /// their advertised UDP address timed out.
  Future<bool> _attemptDirectPunchWithPeer(
    PeerState peer,
    AddressInfo targetAddr,
  ) async {
    final peerHex = peer.pubkeyHex;
    final peerName = peer.displayName;

    if (_udpService == null || !_udpAvailable) {
      debugPrint(
        '[direct-punch] UDP unavailable, cannot coordinate with $peerName',
      );
      return false;
    }
    if (_holePunchServiceFor(targetAddr.ip) == null) {
      debugPrint(
        '[direct-punch] Hole-punch service unavailable, cannot coordinate with $peerName',
      );
      return false;
    }
    if (!_hasLiveBlePath(peer)) {
      debugPrint(
        '[direct-punch] No live BLE path to $peerName, skipping direct punch',
      );
      return false;
    }

    final myAddress = udpAddress;
    if (myAddress == null || myAddress.isEmpty) {
      debugPrint(
        '[direct-punch] No public UDP address available for $peerName',
      );
      return false;
    }

    final myAddr = _parseSupportedUdpAddress(
      myAddress,
      context: 'direct-punch',
      peerLabel: peerName,
    );
    if (myAddr == null) {
      return false;
    }

    if (_holePunchCompleters.containsKey(peerHex)) {
      debugPrint(
        '[direct-punch] Reusing in-flight hole-punch attempt for $peerName',
      );
    } else {
      _beginHolePunchAttempt(peerHex);
    }

    debugPrint(
      '[direct-punch] Asking $peerName to punch toward $myAddress '
      'via direct friend signaling...',
    );
    final sent = await _signalingService.requestDirectPunch(
      peer.publicKey,
      requesterPubkey: identity.publicKey,
      requesterIp: myAddr.ip.address,
      requesterPort: myAddr.port,
      requireDirectTransport: true,
    );
    if (!sent) {
      _failHolePunchAttempt(peerHex, 'Could not signal target directly');
      return false;
    }

    await _executePunchInitiate(
      peer.publicKey,
      targetAddr.ip.address,
      targetAddr.port,
      readyRecipientPubkey: peer.publicKey,
    );

    final completer = _holePunchCompleters[peerHex];
    if (completer == null) return false;

    final succeeded = await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        debugPrint(
          '[direct-punch] Timed out waiting for UDP connection to $peerName',
        );
        _failHolePunchAttempt(
          peerHex,
          'Timed out waiting for direct punch connection',
        );
        return false;
      },
    );

    if (succeeded) {
      debugPrint('[direct-punch] Established UDP path to $peerName');
    }
    return succeeded;
  }

  /// Execute the local side of a PUNCH_INITIATE instruction.
  Future<void> _executePunchInitiate(
    Uint8List peerPubkey,
    String ip,
    int port, {
    Uint8List? readyRecipientPubkey,
  }) async {
    final peerHex =
        peerPubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final peerShort = peerHex.substring(0, 8);
    final hasPendingSend = _holePunchCompleters.containsKey(peerHex);

    // Idempotency: a duplicate PUNCH_INITIATE arrives whenever both peers
    // independently requested punches for the same pair. If we're already
    // handling a punch toward the same target, skip — another round would
    // just produce redundant packets and duplicate PUNCH_READY messages.
    final incomingIp = InternetAddress.tryParse(ip);
    final existing = _holePunchTargets[peerHex];
    if (existing != null &&
        incomingIp != null &&
        existing.ip.address == incomingIp.address &&
        existing.port == port &&
        (_holePunchLocalReady.contains(peerHex) ||
            _holePunchConnectionInProgress.contains(peerHex))) {
      debugPrint(
        '[hole-punch] Ignoring duplicate PUNCH_INITIATE for '
        '$peerShort at $ip:$port — punch already in progress '
        '(pendingSend=$hasPendingSend)',
      );
      return;
    }

    debugPrint(
      '[hole-punch] PUNCH_INITIATE received: '
      'target=$peerShort at $ip:$port, '
      'pendingSend=$hasPendingSend',
    );

    store.dispatch(HolePunchPunchingAction(peerHex));

    final targetIp = incomingIp;
    if (targetIp == null) {
      debugPrint('[hole-punch] Invalid address in punch initiate: $ip:$port');
      _failHolePunchAttempt(peerHex, 'Invalid punch target address');
      return;
    }
    if (_udpService == null || !_udpService!.canDialAddress(targetIp)) {
      debugPrint(
        '[hole-punch] Unsupported address family in punch initiate: '
        '$ip:$port. Current UDP socket cannot use '
        '${targetIp.type == InternetAddressType.IPv6 ? "IPv6" : "IPv4"}.',
      );
      _failHolePunchAttempt(peerHex, 'Unsupported address family');
      return;
    }

    final punchService = _holePunchServiceFor(targetIp);
    if (punchService == null) {
      debugPrint('[hole-punch] Hole-punch service unavailable');
      _failHolePunchAttempt(peerHex, 'Hole-punch service unavailable');
      return;
    }

    _holePunchTargets[peerHex] = AddressInfo(targetIp, port);

    // Send punch packets to open NAT mappings on both sides.
    debugPrint('[hole-punch] Sending punch packets to $ip:$port...');
    await punchService.punch(targetIp, port);
    debugPrint('[hole-punch] Punch packets sent.');

    _holePunchLocalReady.add(peerHex);

    if (readyRecipientPubkey != null) {
      final readyRecipientHex = readyRecipientPubkey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      debugPrint(
        '[hole-punch] Reporting local punch readiness for '
        '$peerShort...',
      );
      final readySent = await _signalingService.sendPunchReady(
        readyRecipientPubkey,
        identity.publicKey,
        requireDirectTransport: readyRecipientHex == peerHex,
      );
      if (!readySent) {
        _failHolePunchAttempt(
          peerHex,
          'Could not deliver PUNCH_READY to the remote coordinator',
        );
        return;
      }
    }

    // After punching, only the INITIATOR (smaller pubkey) establishes the
    // UDX connection, and only after the other side explicitly confirms
    // readiness via PUNCH_READY.
    final myPubkeyHex = identity.publicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final iAmInitiator = myPubkeyHex.compareTo(peerHex) < 0;

    if (iAmInitiator) {
      debugPrint(
        '[hole-punch] Local punch complete for $peerShort; waiting for '
        'explicit PUNCH_READY before connecting...',
      );
      await _maybeEstablishPunchConnection(peerHex);
    } else if (!iAmInitiator) {
      // We punched but we're not the initiator — wait for incoming UDX connection.
      debugPrint('[hole-punch] Punched, waiting for initiator to connect...');
    }
  }

  /// Try to reach a peer by sending RECONNECT to every trusted facilitator.
  ///
  /// The facilitator(s) match this against the peer's AVAILABLE message
  /// (which the peer sends when it detects we went silent — see
  /// [_onUdpPeerDisconnected]) and respond with PUNCH_INITIATE. We then wait
  /// for the coordinated punch to complete.
  ///
  /// Returns true if a UDP path to the peer was established.
  Future<bool> _discoverPeerViaFriends(PeerState peer) async {
    final pubkeyBytes = peer.publicKey;
    final pubkeyHex = peer.pubkeyHex;
    final name = peer.displayName;
    final trustedFriendCount = store.state.peers.wellConnectedFriends.length;
    final rendezvousCount = _configuredRendezvousServers().length;
    final facilitatorCount = trustedFriendCount + rendezvousCount;

    if (facilitatorCount == 0) {
      debugPrint('[discover] No signaling facilitators available');
      return false;
    }

    _beginHolePunchAttempt(pubkeyHex);

    final sent = await _signalingService.fanOutReconnect(pubkeyBytes);
    if (sent == 0) {
      debugPrint('[discover] Could not reach any facilitator for $name');
      _failHolePunchAttempt(pubkeyHex, 'Could not reach any facilitator');
      return false;
    }

    final completer = _holePunchCompleters[pubkeyHex];
    if (completer == null) {
      debugPrint('[discover] Hole-punch state vanished for $name');
      return false;
    }

    debugPrint(
      '[discover] RECONNECT fanned out for $name ($sent facilitator(s)); '
      'waiting for PUNCH_INITIATE (timeout: 15s)...',
    );

    final succeeded = await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        debugPrint('[discover] Hole-punch timed out for $name');
        _failHolePunchAttempt(
          pubkeyHex,
          'Timed out waiting for coordinated hole-punch',
        );
        return false;
      },
    );

    if (succeeded) {
      debugPrint('[discover] Successfully established path to $name');
    }
    return succeeded;
  }

  // ===== Internal setup =====

  /// Periodically try to discover unreachable friends via rendezvous facilitators.
  ///
  /// On each announce tick, find friends that we know about but can't currently
  /// reach via any transport. Fan out RECONNECT to all configured rendezvous
  /// facilitators; the match completes (and the punch begins) only when the
  /// peer also sends an AVAILABLE message — typically because the peer
  /// independently detected our disconnect.
  ///
  /// Throttled: each peer is attempted at most once per [_discoveryRetryInterval].
  void _discoverUnreachableFriends() {
    // debugPrint("Discovering unreachable friends");
    if (!_udpAvailable) {
      // debugPrint("No UDP");
      return; // Need UDP to establish the connection
    }

    final wellConnected = store.state.peers.wellConnectedFriends;
    final rendezvousCount = _configuredRendezvousServers().length;
    if (wellConnected.isEmpty && rendezvousCount == 0) {
      // debugPrint("No well connected friends and no RVs");
      return;
    }

    final now = DateTime.now();
    final friends = _peersState.friends;

    // var len = friends.length;
    // debugPrint("Have $len friends");

    for (final friend in friends) {
      // Skip friends we can already reach
      if (_hasLiveBlePath(friend)) {
        // debugPrint("Have live BLE path to friend");
        continue;
      }
      if (_udpService?.getPeerIdForPubkey(friend.publicKey) != null) {
        // debugPrint("Have peer Id for public key in udp service");
        continue;
      }

      // Skip if we attempted discovery recently
      final lastAttempt = _lastDiscoveryAttempt[friend.pubkeyHex];
      if (lastAttempt != null &&
          now.difference(lastAttempt) < _discoveryRetryInterval) {
        // debugPrint("Skip because tried recently");
        continue;
      }

      // Skip if this friend IS one of our well-connected friends (they're
      // reachable — that's how we'd signal through them)
      // if (wellConnected.any((wc) => wc.pubkeyHex == friend.pubkeyHex)) {
      //   debugPrint("Skip because it's well connected");
      //   continue;
      // }

      debugPrint(
        '[discover] Friend ${friend.displayName} is unreachable, '
        'trying discovery via '
        '${wellConnected.length + rendezvousCount} facilitator(s)...',
      );
      _lastDiscoveryAttempt[friend.pubkeyHex] = now;

      // Fire-and-forget — don't block the announce tick
      _discoverPeerViaFriends(friend).then((success) {
        if (success) {
          debugPrint(
            '[discover] Successfully reached ${friend.displayName} via friends',
          );
          _lastDiscoveryAttempt.remove(friend.pubkeyHex);
        } else {
          debugPrint(
            '[discover] Discovery failed for ${friend.displayName}, '
            'will retry in ${_discoveryRetryInterval.inSeconds}s',
          );
        }
      });
    }
  }

  /// Set up MessageRouter callbacks to dispatch to Redux and application layer
  void _setupRouterCallbacks() {
    // Message received from any transport
    _messageRouter.onMessageReceived = (messageId, senderPubkey, payload) {
      final peer = store.state.peers.getPeerByPubkey(senderPubkey);
      final transport = peer?.activeTransport == PeerTransport.udp
          ? MessageTransport.udp
          : MessageTransport.ble;

      store.dispatch(
        MessageReceivedAction(
          messageId: messageId,
          transport: transport,
          senderPubkey: senderPubkey,
          payloadSize: payload.length,
        ),
      );
      onMessageReceived?.call(messageId, senderPubkey, payload, transport);
    };

    // ACK received (UDP delivery confirmation)
    _messageRouter.onAckReceived = (messageId) {
      debugPrint('ACK received for message $messageId');
      store.dispatch(MessageDeliveredAction(messageId: messageId));
    };

    // Read receipt received
    _messageRouter.onReadReceiptReceived = (messageId) {
      debugPrint('Read receipt received for message $messageId');
      store.dispatch(MessageReadAction(messageId: messageId));
    };

    // Map incoming UDP connections from any verified packet's senderPubkey.
    // Previously required ANNOUNCE as the first message on a stream; now any
    // verified packet identifies the sender via its header.
    _messageRouter.onUdpPeerIdentified = (senderPubkey, udpPeerId) {
      final pubkeyHex =
          senderPubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      _udpService?.mapIncomingConnectionToPubkey(udpPeerId, pubkeyHex);
    };

    // Peer ANNOUNCE processed
    _messageRouter.onPeerAnnounced =
        (data, transport, {bool isNew = false, String? udpPeerId}) {
      final pubkeyHex =
          data.publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      // debugPrint('Announce inc');
      if (_isRendezvousPubkeyHex(pubkeyHex)) {
        _completeRendezvousResponseWaiters(pubkeyHex);
      }

      // When we are well-connected and receive an ANNOUNCE from a friend
      // with a UDP address, register it in our address table. This is used
      // by the direct-punch path ([requestDirectPunch]) when we want a
      // friend already reachable over BLE to start punching toward us.
      //
      // Only friends are registered.
      //
      // UDP: use the observed address (NAT-translated, most reliable).
      // BLE: use the claimed address from the ANNOUNCE payload (no observed
      //      address available over BLE, but it's the only option — and for
      //      peers with public UDP reachability, the claimed address is correct).
      final announcedCandidates = normalizeAddressStrings([
        ...data.addressCandidates,
        data.udpAddress,
        data.linkLocalAddress,
      ]);
      if (store.state.transports.isWellConnected &&
          announcedCandidates.isNotEmpty) {
        final senderPeer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);
        if (senderPeer != null && senderPeer.isFriend) {
          if (transport == PeerTransport.udp && _udpService != null) {
            final remote = _udpService!.getRemoteAddress(pubkeyHex);
            _signalingService.processAnnounceFromFriend(
              data.publicKey,
              claimedAddress: data.udpAddress,
              claimedAddresses: announcedCandidates,
              observedIp: remote?.ip.address,
              observedPort: remote?.port,
            );
          } else if (transport == PeerTransport.bleDirect) {
            _signalingService.processAnnounceFromFriend(
              data.publicKey,
              claimedAddress: data.udpAddress,
              claimedAddresses: announcedCandidates,
              // No observed address over BLE — claimed address only.
            );
          }
        }
      } else {
        // debugPrint(
        //     'Either we are not well connected, or peer has null udpAddress, this is expected');
      }

      if (transport == PeerTransport.bleDirect) {
        final senderPeer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);
        if (senderPeer != null && senderPeer.isFriend) {
          _sendFriendAnnounceToConnectedBlePaths(senderPeer);
        }
      }

      // Proactive UDP connect: when a friend's ANNOUNCE arrives with a UDP
      // address (from any transport, including BLE), establish a UDP connection
      // so both transports are active simultaneously. This ensures disabling
      // BLE doesn't kill the peer — UDP keeps it alive.
      //
      // IMPORTANT: Only ONE side should initiate the connection to avoid
      // simultaneous-open issues in UDX (two independent socket pairs that
      // don't share streams, causing one-directional data flow). The device
      // with the lexicographically smaller pubkey initiates.
      if (announcedCandidates.isNotEmpty &&
          _udpService != null &&
          _udpAvailable) {
        debugPrint('[auto-udp] proactive UDP connect to $pubkeyHex');
        final senderPeer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);
        if (senderPeer != null &&
            senderPeer.isFriend &&
            _udpService!.getPeerIdForPubkey(data.publicKey) == null) {
          debugPrint(
              '[auto-udp] proactive UDP connect to $pubkeyHex who is actually ${senderPeer.nickname}');
          // Deterministic initiator: the peer with the smaller pubkey hex
          // initiates the connection. The other side waits for the incoming
          // connection to arrive via the multiplexer.
          final myPubkeyHex = identity.publicKey
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          final iAmInitiator = myPubkeyHex.compareTo(pubkeyHex) < 0;

          if (iAmInitiator) {
            debugPrint(
              '[auto-udp] Friend ${data.nickname} has UDP address '
              '$announcedCandidates, connecting proactively (I am initiator)...',
            );
            _connectToFriendViaUdp(
              pubkeyHex,
              data.udpAddress ?? announcedCandidates.first,
            );
          } else {
            debugPrint(
              '[auto-udp] Friend ${data.nickname} has UDP address '
              '$announcedCandidates, waiting for them to connect (they are initiator)',
            );
          }
        }
      }

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
      if (peerId == null) {
        debugPrint('Cannot send ACK for $messageId: no peerId');
        return;
      }
      final ackPacket = _protocolHandler.createAckPacket(messageId: messageId);
      await _protocolHandler.signPacket(ackPacket);
      final bytes = ackPacket.serialize();
      if (transport == PeerTransport.udp) {
        await _udpService?.sendToPeer(peerId, bytes);
      } else if (transport == PeerTransport.bleDirect) {
        await _bleService?.sendToPeer(peerId, bytes);
      }
    };

    // Signaling packet received — delegate to SignalingService.
    _messageRouter.onSignalingReceived =
        (senderPubkey, payload, {observedIp, observedPort}) {
      _signalingService.processSignaling(
        senderPubkey,
        payload,
        observedIp: observedIp,
        observedPort: observedPort,
      );
    };
  }

  /// Set up SignalingService callbacks
  void _setupSignalingCallbacks() {
    // SignalingService sends signaling payloads through us (wrapped in GrassrootsPacket)
    _signalingService.sendSignaling =
        (recipientPubkey, signalingPayload) async {
      final bytes = await _createSignedSignalingPacket(
        recipientPubkey,
        signalingPayload,
      );

      final pubkeyHex = recipientPubkey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final isRendezvous = _isRendezvousPubkeyHex(pubkeyHex);
      final rendezvousConfig =
          isRendezvous ? _configuredRendezvousForPubkeyHex(pubkeyHex) : null;

      // Try BLE first
      if (_bleService != null && _bleAvailable) {
        final peerId = _bleService!.getPeerIdForPubkey(recipientPubkey);
        if (peerId != null) {
          if (await _bleService!.sendToPeer(peerId, bytes)) return true;
        }
      }

      // Fall back to UDP
      if (_udpService != null && _udpAvailable) {
        if (isRendezvous) {
          final synced = await _syncConfiguredRendezvous(
            config: rendezvousConfig,
            reason: 'signaling-primer',
          );
          if (!synced) {
            return false;
          }
        }

        if (await _udpService!.sendToPeer(pubkeyHex, bytes)) return true;

        // Not connected via UDP yet — try connect-on-demand
        final peer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);
        final candidates = _udpCandidatesForPeer(
          peer,
          fallbackAddress: rendezvousConfig?.address,
        );
        final udpAddr = peer?.udpAddress ??
            rendezvousConfig?.address ??
            (candidates.isNotEmpty ? candidates.first : null);
        if (udpAddr != null && udpAddr.isNotEmpty) {
          return _sendViaUdp(
            pubkeyHex,
            udpAddr,
            bytes,
            isRendezvous: isRendezvous,
          );
        }
      }

      return false;
    };
    _signalingService.sendDirectSignaling = _sendDirectSignalingOverLiveBle;

    // Address-aware send: target an RV at an explicit ip:port even if we
    // haven't otherwise registered or connected to it. Used by AVAILABLE
    // fan-out for RVs we learned about from a friend (RV_LIST).
    _signalingService.sendSignalingToAddress = (
      recipientPubkey,
      address,
      signalingPayload,
    ) async {
      final bytes = await _createSignedSignalingPacket(
        recipientPubkey,
        signalingPayload,
      );
      if (_udpService == null || !_udpAvailable) return false;
      final pubkeyHex = recipientPubkey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      return _sendViaUdp(pubkeyHex, address, bytes);
    };

    // Hole-punch initiation: a well-connected friend told us to start punching
    _signalingService.onPunchInitiate =
        (peerPubkey, ip, port, readyRecipientPubkey) async {
      await _executePunchInitiate(
        peerPubkey,
        ip,
        port,
        readyRecipientPubkey: readyRecipientPubkey,
      );
    };

    _signalingService.onPunchReady = (peerPubkey) async {
      final peerHex =
          peerPubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      _holePunchRemoteReady.add(peerHex);
      await _maybeEstablishPunchConnection(peerHex);
    };

    // Address reflection: a well-connected friend told us our real public address.
    // This replaces the HTTP-discovered IP + guessed port with the actual
    // NAT-translated address the friend observed — correct external port included.
    // The corrected address will be broadcast to all friends on the next
    // periodic ANNOUNCE cycle.
    _signalingService.onAddrReflected = (senderPubkey, ip, port) {
      // The GLP-spec response to a registration ANNOUNCE is an addrReflect.
      // If the sender is a configured (or in-flight) rendezvous server,
      // treat it as authoritative proof of the round-trip and unblock
      // _verifyRendezvousServerResponds. The server's separate ANNOUNCE-back
      // is informational — relying on it is fragile because that send path
      // is fire-and-forget and can be dropped on stream tear-down.
      final senderHex =
          senderPubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (_isRendezvousPubkeyHex(senderHex)) {
        debugPrint(
          '[rendezvous] Server ${senderHex.substring(0, 8)}... acknowledged '
          'via addrReflect',
        );
        _completeRendezvousResponseWaiters(senderHex);
      }

      final reflectedIp = InternetAddress.tryParse(ip);
      if (reflectedIp == null) return;

      // Always update the display IP with the reflected address (IPv6 > IPv4).
      final currentIp = store.state.transports.publicIp;
      final isUpgrade =
          reflectedIp.type == InternetAddressType.IPv6 || currentIp == null;
      if (isUpgrade || ip == currentIp) {
        store.dispatch(PublicIpUpdatedAction(ip));
      }

      if (_udpService == null ||
          !_udpAvailable ||
          !_udpService!.canDialAddress(reflectedIp)) {
        debugPrint(
          'Reflected ${reflectedIp.type == InternetAddressType.IPv6 ? "IPv6" : "IPv4"} '
          'address $ip:$port — noted for display, but the current UDP '
          'socket cannot use that family.',
        );
        return;
      }

      final reflected = AddressInfo(reflectedIp, port).toAddressString();
      if (reflected == _publicAddress) return; // No change

      debugPrint(
        'Public address updated via reflection: $_publicAddress → $reflected',
      );
      _publicAddress = reflected;
      store.dispatch(PublicAddressUpdatedAction(reflected));
      _resetRendezvousBackoff();
      unawaited(_syncConfiguredRendezvous(reason: 'reflected-address-updated'));
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
      udpAddress: state.udpAddress,
      rssi: state.rssi,
      protocolVersion: state.protocolVersion,
    );
  }

  /// Set up callbacks for BLE transport service
  void _setupBleServiceCallbacks() {
    if (_bleService == null) return;

    // Forward BLE packets to the MessageRouter for processing
    _bleService!.onBlePacketReceived =
        (packet, {String? bleDeviceId, int rssi = -100, BleRole? bleRole}) {
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
      debugPrint('BLE Peer disconnected: ${peer.displayName}');
      onPeerDisconnected?.call(peer);
    };

    // Listen to connection events for bookkeeping only. ANNOUNCE traffic is
    // driven exclusively by the periodic announce timer — sending on stream
    // establishment would race with the periodic broadcast and the
    // application's BLE-address rotation handling.
    _bleService!.connectionStream.listen((event) {
      if (event.connected) {
        // debugPrint('BLE device connected: ${event.peerId}');
      } else {
        debugPrint('BLE device disconnected: ${event.peerId}');
        _bleFriendAnnounceSent.remove(event.peerId);
      }
    });
  }

  /// Set up callbacks for UDP transport service
  void _setupUdpServiceCallbacks() {
    if (_udpService == null) return;

    // Forward UDP data to the MessageRouter for processing
    _udpService!.onUdpDataReceived = (peerId, data) {
      try {
        final packet = GrassrootsPacket.deserialize(data);
        // Observed source address: the UDX remote, if known. Used by the
        // signaling matcher to learn cold-call senders' public addresses.
        final remote = _udpService!.getRemoteAddress(peerId);
        _messageRouter.processPacket(
          packet,
          transport: PeerTransport.udp,
          udpPeerId: peerId,
          observedIp: remote?.ip.address,
          observedPort: remote?.port,
        );
      } catch (e) {
        debugPrint('Failed to deserialize UDP packet from $peerId: $e');
      }
    };

    // Listen to connection events — update Redux state and log
    _udpService!.connectionStream.listen((event) {
      if (event.connected) {
        debugPrint('UDP peer connected: ${event.peerId}');
        store.dispatch(PeerUdpSeenAction(_hexToBytes(event.peerId)));
        _sendRvListToFriendIfEligible(event.peerId);

        final wasPunching = _holePunchTargets.containsKey(event.peerId) ||
            _holePunchLocalReady.contains(event.peerId) ||
            _holePunchRemoteReady.contains(event.peerId);
        final completer = _holePunchCompleters.remove(event.peerId);
        if (wasPunching) {
          final remote = _udpService!.getRemoteAddress(event.peerId);
          if (remote != null) {
            store.dispatch(
              HolePunchSucceededAction(
                event.peerId,
                remote.ip.address,
                remote.port,
              ),
            );
          } else {
            final peer = _peersState.getPeerByPubkeyHex(event.peerId);
            final parsed = peer?.udpAddress != null
                ? parseAddressString(peer!.udpAddress!)
                : null;
            if (parsed != null) {
              store.dispatch(
                HolePunchSucceededAction(
                  event.peerId,
                  parsed.ip.address,
                  parsed.port,
                ),
              );
            }
          }
        } else {
          // Connection succeeded with no prior hole-punch coordination —
          // empirical proof of unsolicited UDP reachability.
          //
          // Incoming: a peer reached us at our public address without us
          // first opening a NAT mapping for them. This proves WE accept
          // unsolicited inbound (i.e. our firewall/NAT path is open).
          //
          // Outgoing: we reached the peer at their advertised address
          // without any punch coordination. This proves THEIR address
          // accepts unsolicited inbound.
          final peer = _peersState.getPeerByPubkeyHex(event.peerId);
          final observedRemote = _udpService!.getRemoteAddress(event.peerId);
          final peerCandidates = _udpCandidatesForPeer(peer);
          final matchedAdvertisedAddress = observedRemote != null &&
              peerCandidates.any((candidate) {
                final parsed = parseAddressString(candidate);
                return parsed != null &&
                    observedRemote.ip.address == parsed.ip.address &&
                    observedRemote.port == parsed.port;
              });

          if (event.isIncoming) {
            // Only accept inbound proof if the peer reached us on the same
            // address they advertise publicly. This avoids treating LAN or
            // link-local paths as proof of unsolicited public reachability.
            if (peer?.hasPublicUdpAddress == true && matchedAdvertisedAddress) {
              store.dispatch(UnsolicitedInboundObservedAction());
            } else {
              debugPrint(
                'Ignoring inbound well-connected proof for ${event.peerId}: '
                'peer advertised=${peer?.udpAddress}, observed=$observedRemote',
              );
            }
          } else if (peer != null) {
            // Bind peer reachability proof to the exact advertised address
            // that succeeded, not just any direct path.
            if (peer.hasPublicUdpAddress && matchedAdvertisedAddress) {
              final remote = _udpService!.getRemoteAddress(event.peerId);
              final reachedAdvertisedAddress = remote != null &&
                  peerCandidates.any((candidate) {
                    final advertised = parseAddressString(candidate);
                    return advertised != null &&
                        remote.port == advertised.port &&
                        remote.ip.address == advertised.ip.address;
                  });
              if (reachedAdvertisedAddress) {
                store.dispatch(PeerDirectReachObservedAction(peer.publicKey));
              } else {
                debugPrint(
                    'Skipping direct-reach proof for ${event.peerId}: connected to '
                    '${remote?.ip.address ?? "unknown"}:${remote?.port ?? 0} '
                    'but advertised ${peer.udpAddress ?? "none"}');
              }
            } else {
              debugPrint(
                'Ignoring peer direct-reach proof for ${event.peerId}: '
                'peer advertised=${peer.udpAddress}, observed=$observedRemote',
              );
            }
          }
        }
        if (completer != null && !completer.isCompleted) {
          completer.complete(true);
        }
        _clearHolePunchState(event.peerId);
      } else {
        debugPrint('UDP peer disconnected: ${event.peerId}');
        final hadPendingPunch =
            _holePunchCompleters.containsKey(event.peerId) ||
                _holePunchTargets.containsKey(event.peerId) ||
                _holePunchLocalReady.contains(event.peerId) ||
                _holePunchRemoteReady.contains(event.peerId);
        if (hadPendingPunch) {
          _failHolePunchAttempt(
            event.peerId,
            event.reason ?? 'UDP disconnected during hole-punch',
          );
        } else {
          _clearHolePunchState(event.peerId);
        }
        _onUdpPeerDisconnected(event.peerId);
      }
      store.dispatch(
        PeerUdpConnectionChangedAction(
          pubkeyHex: event.peerId,
          connected: event.connected,
        ),
      );
    });
  }

  /// Fired when a UDP stream ended or the ANNOUNCE keepalive timed out.
  ///
  /// Per the rendezvous reconnection algorithm, when we detect a friend went
  /// silent we should fan out AVAILABLE to our trusted facilitators. The peer
  /// (which presumably had its IP change) will send RECONNECT, the facilitator
  /// will match the pair, and a coordinated hole-punch follows.
  /// Send RV_LIST to a friend right after a UDP connection establishes,
  /// so they can target AVAILABLE at our exact rendezvous servers when our
  /// IP changes.
  void _sendRvListToFriendIfEligible(String pubkeyHex) {
    final peer = _peersState.getPeerByPubkeyHex(pubkeyHex);
    if (peer == null || !peer.isFriend) return;

    final rvServers = _ownRvServerEntries();
    if (rvServers.isEmpty) return;

    debugPrint(
      '[rv-list] Sending ${rvServers.length} rendezvous server entr(y/ies) to '
      '${peer.displayName}',
    );
    unawaited(_signalingService.sendRvList(peer.publicKey, rvServers));
  }

  /// Broadcast our current RV list to every UDP-reachable friend. Called
  /// when the local rendezvous server settings change.
  void _broadcastRvListToFriends() {
    final rvServers = _ownRvServerEntries();
    if (rvServers.isEmpty || _udpService == null) return;
    for (final friend in _peersState.friends) {
      if (_udpService!.getPeerIdForPubkey(friend.publicKey) == null) continue;
      debugPrint(
        '[rv-list] Re-broadcasting RV list to ${friend.displayName} '
        '(settings changed)',
      );
      unawaited(_signalingService.sendRvList(friend.publicKey, rvServers));
    }
  }

  List<RvServerEntry> _ownRvServerEntries() {
    return [
      for (final config in _configuredRendezvousServers())
        RvServerEntry(pubkey: config.pubkey, address: config.address),
    ];
  }

  void _onUdpPeerDisconnected(String pubkeyHex) {
    final peer = _peersState.getPeerByPubkeyHex(pubkeyHex);
    if (peer == null || !peer.isFriend) return;

    // Don't fire the application-level onPeerDisconnected here — the peer
    // may still be reachable via BLE, and BLE/UDP are independent transports.

    final facilitatorCount = store.state.peers.wellConnectedFriends.length +
        _configuredRendezvousServers().length;
    if (facilitatorCount == 0) return;

    debugPrint(
      '[reconnect] UDP path to ${peer.displayName} dropped — fanning out AVAILABLE',
    );
    unawaited(_signalingService.fanOutAvailable(peer.publicKey));
  }

  /// Clean up resources
  Future<void> dispose() async {
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
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

    // Complete any pending hole-punch waiters so send() callers don't hang
    for (final completer in _holePunchCompleters.values) {
      if (!completer.isCompleted) completer.complete(false);
    }
    _holePunchCompleters.clear();
    _holePunchTargets.clear();
    _holePunchLocalReady.clear();
    _holePunchRemoteReady.clear();
    _holePunchConnectionInProgress.clear();

    _messageRouter.dispose();
    _signalingService.dispose();

    if (_bleService != null) {
      await _bleService!.dispose();
    }

    for (final service in _holePunchServices.values) {
      service.dispose();
    }
    _holePunchServices.clear();

    if (_udpService != null) {
      await _udpService!.dispose();
    }
  }

  /// Start the periodic ANNOUNCE timer
  void _startAnnounceTimer() {
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(config.announceInterval, (_) {
      _broadcastAnnounce();
      _broadcastAnnounceViaUdp();
      _removeStalePeers();
      _discoverUnreachableFriends();
    });
  }

  /// Start the periodic scan timer
  void _startScanTimer() {
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(config.scanInterval, (_) {
      // debugPrint('Scan timer is up! Scanning for new devices 📡');
      _periodicScan();
    });
  }

  /// Perform a periodic scan for new BLE devices
  Future<void> _periodicScan() async {
    if (!_bleAvailable) return;
    if (store.state.settings.bleRoleMode == BleRoleMode.peripheralOnly) {
      return;
    }
    try {
      store.dispatch(BleScanningChangedAction(true));
      await _bleService!.scan(timeout: config.scanDuration);
    } catch (e) {
      debugPrint('Periodic scan failed: $e');
    } finally {
      store.dispatch(BleScanningChangedAction(false));
    }
  }

  /// Send ANNOUNCE to all connected BLE devices.
  ///
  /// Each connected device is targeted individually so friend/non-friend
  /// address inclusion is decided using the current mapping for that exact BLE
  /// device ID. This avoids the old exclude-list logic that broke when BLE IDs
  /// rotated or when a peer had separate central/peripheral connections.
  Future<void> _broadcastAnnounce() async {
    if (_bleService == null || !_bleAvailable) return;

    for (final bleId in _bleService!.connectedPeerIds) {
      await _sendAnnounceToDevice(bleId);
    }
  }

  /// Broadcast ANNOUNCE via UDP to all connected peers.
  ///
  /// Always includes our address — all UDP peers are known (no strangers).
  Future<void> _broadcastAnnounceViaUdp() async {
    if (_udpService == null || !_udpAvailable) return;

    final announce = await _createSignedAnnounce(
      address: udpAddress,
      addressCandidates: _candidateAddresses(),
    );
    await _udpService!.broadcast(announce);
  }

  /// Send ANNOUNCE directly to a specific BLE device ID.
  ///
  /// Called from the periodic [_broadcastAnnounce] loop and from
  /// [_sendFriendAnnounceToConnectedBlePaths] (which fires when we receive
  /// an ANNOUNCE from a freshly-identified friend, to close the privacy
  /// gap where the previous periodic broadcast had to omit our address
  /// because we hadn't yet linked the device ID to a pubkey).
  ///
  /// Crucially, NOT called on BLE-connection-established events — the
  /// connection-stream listener is bookkeeping only. ANNOUNCE traffic is
  /// strictly cycle-driven; firing on stream establishment races the
  /// periodic broadcast and the BLE-address-rotation handling.
  Future<bool> _sendAnnounceToDevice(String deviceId) async {
    if (_bleService == null || !_bleAvailable) return false;

    // Check if this device ID belongs to a known friend
    final pubkey = _bleService!.getPubkeyForPeerId(deviceId);
    final isFriend =
        pubkey != null && _peersState.getPeerByPubkey(pubkey)?.isFriend == true;

    // Friends get our address + link-local, non-friends (or unknown) don't
    final announce = isFriend
        ? await _createSignedAnnounce(
            address: udpAddress,
            linkLocalAddress: _linkLocalAddress,
          )
        : await _createSignedAnnounce();

    // debugPrint('[ble-announce] payload size=${announce.length}');
    final sent = await _bleService!.sendToPeer(deviceId, announce);
    if (sent) {
      if (isFriend) {
        _bleFriendAnnounceSent.add(deviceId);
      } else {
        _bleFriendAnnounceSent.remove(deviceId);
      }
      debugPrint(
        '[ble-announce] Sent immediate ANNOUNCE to $deviceId (friend: $isFriend)',
      );
    } else {
      debugPrint('[ble-announce] Failed to send ANNOUNCE to $deviceId');
    }
    return sent;
  }

  /// Once a BLE peer identifies itself, send them a directed friend ANNOUNCE
  /// on every live BLE path we have for them. This closes the window where the
  /// connection-time ANNOUNCE had to omit our address because the device ID had
  /// not been mapped to a pubkey yet.
  void _sendFriendAnnounceToConnectedBlePaths(PeerState peer) {
    if (_bleService == null || !_bleAvailable) return;

    final candidateIds = <String>{
      if (peer.bleCentralDeviceId != null) peer.bleCentralDeviceId!,
      if (peer.blePeripheralDeviceId != null) peer.blePeripheralDeviceId!,
    };

    for (final deviceId in candidateIds) {
      if (_bleFriendAnnounceSent.contains(deviceId)) continue;
      if (!_bleService!.isDeviceConnected(deviceId)) continue;
      _sendAnnounceToDevice(deviceId);
    }
  }

  /// Create a signed ANNOUNCE packet, optionally with address.
  Future<Uint8List> _createSignedAnnounce({
    String? address,
    String? linkLocalAddress,
    Iterable<String> addressCandidates = const [],
  }) async {
    final normalizedAddress = _normalizeAnnouncedUdpAddress(
      address,
      context: 'announce',
    );
    final normalizedLinkLocal = _normalizeAnnouncedLinkLocalAddress(
      linkLocalAddress,
      context: 'announce',
    );
    final includeKnownCandidates = normalizedAddress != null ||
        normalizedLinkLocal != null ||
        addressCandidates.isNotEmpty;
    final normalizedCandidates = normalizeAddressStrings([
      if (includeKnownCandidates)
        ..._candidateAddresses(includeLinkLocal: normalizedLinkLocal != null),
      ...addressCandidates,
      normalizedAddress,
      normalizedLinkLocal,
    ]);
    final payload = _protocolHandler.createAnnouncePayload(
      address: normalizedAddress,
      linkLocalAddress: normalizedLinkLocal,
      addressCandidates: normalizedCandidates,
    );
    final packet = GrassrootsPacket(
      type: PacketType.announce,
      ttl: 0,
      senderPubkey: identity.publicKey,
      payload: payload,
      signature: Uint8List(64),
    );
    await _protocolHandler.signPacket(packet);
    return packet.serialize();
  }

  /// Send ANNOUNCE with address to a specific friend.
  ///
  /// This is the unified presence mechanism — friends receive our UDP address
  /// in the ANNOUNCE so they can connect to us over the internet.
  ///
  /// Works over both BLE and UDP transports.
  Future<bool> sendAnnounceToFriend({
    required Uint8List friendPubkey,
    String? myAddress,
  }) async {
    var sent = false;
    final friendPubkeyHex =
        friendPubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    // Create signed ANNOUNCE packet with our address
    final normalizedAddress = _normalizeAnnouncedUdpAddress(
      myAddress,
      context: 'direct-announce',
    );
    final payload = _protocolHandler.createAnnouncePayload(
      address: normalizedAddress,
      addressCandidates: _candidateAddresses(),
    );
    final packet = GrassrootsPacket(
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

    // Also try UDP if available
    if (_udpService != null && _udpAvailable) {
      final peerId = _udpService!.getPeerIdForPubkey(friendPubkey);
      if (peerId != null) {
        final udpSent = await _udpService!.sendToPeer(peerId, bytes);
        sent = sent || udpSent;
      } else {
        final peer = _peersState.getPeerByPubkeyHex(friendPubkeyHex);
        final candidates = _udpCandidatesForPeer(peer);
        final friendAddress = peer?.udpAddress ??
            (candidates.isNotEmpty ? candidates.first : null);
        if (friendAddress != null && friendAddress.isNotEmpty) {
          final udpSent = await _sendViaUdp(
            friendPubkeyHex,
            friendAddress,
            bytes,
          );
          sent = sent || udpSent;
        }
      }
    }

    return sent;
  }

  /// Remove peers that haven't sent an ANNOUNCE within the interval.
  ///
  /// BLE/general staleness uses [PeerState.lastSeen]. UDP liveness is tracked
  /// independently via [PeerState.lastUdpSeen] so a nearby BLE friend can age
  /// out of "Friends Online" without disappearing from "Nearby".
  void _removeStalePeers() {
    final staleThreshold = config.announceInterval * 2; // Give 2x grace period

    // Tear down quiet UDP sessions that have missed 2 announce cycles.
    final connectedUdpPubkeys = <String>{};
    if (_udpService != null) {
      for (final peer in _peersState.peersList) {
        if (_udpService!.getPeerIdForPubkey(peer.publicKey) != null) {
          connectedUdpPubkeys.add(peer.pubkeyHex);
        }
      }
    }

    final staleUdpPeers = computeStaleUdpPeerPubkeys(
      peers: _peersState.peersList,
      connectedUdpPubkeys: connectedUdpPubkeys,
      staleThreshold: staleThreshold,
    );
    if (_udpService != null) {
      for (final pubkeyHex in staleUdpPeers) {
        final peer = _peersState.getPeerByPubkeyHex(pubkeyHex);
        if (peer == null) continue;

        debugPrint(
          '[udp-stale] No UDP traffic from ${peer.displayName} for '
          '${staleThreshold.inSeconds}s; disconnecting stale session',
        );
        store.dispatch(PeerUdpDisconnectedAction(peer.publicKey));
        unawaited(_udpService!.disconnectFromPeer(pubkeyHex));
      }
    }

    // Dispatch action to remove stale peers via Redux
    store.dispatch(StaleDiscoveredBlePeersRemovedAction(staleThreshold));
    store.dispatch(StalePeersRemovedAction(staleThreshold));
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
      final sent = await _bleService!.sendToPeer(
        bleDeviceId,
        fragment.serialize(),
      );
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
}
