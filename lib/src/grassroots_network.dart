import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:redux/redux.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'package:uuid/uuid.dart';
import 'ble/permission_handler.dart';
import 'platform/transport_foreground_service.dart';
import 'signaling/invite.dart';
import 'signaling/signaling_service.dart';
import 'transport/address_utils.dart';
import 'transport/ble_transport_service.dart';
import 'transport/connection_service.dart';
import 'transport/hole_punch_service.dart';
import 'transport/public_address_discovery.dart';
import 'transport/udp_transport_service.dart';
import 'models/block.dart';
import 'models/identity.dart';
import 'testbed/bulk_flow_driver.dart';
import 'trace/experiment_recorder.dart';
import 'models/peer.dart';
import 'models/packet.dart';
import 'models/secure_frame.dart';
import 'protocol/protocol_handler.dart';
import 'protocol/fragment_handler.dart';
import 'routing/message_router.dart';
import 'session/noise_session_manager.dart';
import 'testbed/crypto_bench.dart';
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

/// A burned invite nonce: how many redemptions we've accepted, and the
/// invite's expiry (unix secs) so the entry can be pruned once it can no
/// longer be presented.
class _BurnedNonce {
  final int uses;
  final int expiry;
  const _BurnedNonce({required this.uses, required this.expiry});
}

/// A message created before any Noise session with its recipient exists —
/// held as plaintext until the eager handshake on an accepted pairing makes
/// it sealable and bufferable.

/// Whether a settings change that just brought a transport up must complete a
/// deferred [GrassrootsNetwork.start].
///
/// The wedge this guards against: with `autoStart` on, the first `initialize()`
/// can still find no usable transport (e.g. BLE permission denied and UDP off),
/// in which case it returns without ever calling `start()`, leaving `_started`
/// false. When the user later enables a transport from settings, the service
/// initializes but the warm-path per-transport `start()` calls are gated on the
/// stack already being started — so without this the transport is live but
/// inert (no advertising, scanning, or announce/scan timers) until the app
/// restarts.
///
/// True only when auto-start was requested, nothing was started yet, and a
/// transport is now usable. With `autoStart` off the caller manages `start()`
/// itself, so an unrelated settings change must not start on its behalf; the
/// disable paths (no transport available) and the warm path (already started)
/// also return false.
@visibleForTesting
bool shouldColdStartAfterSettingsChange({
  required bool autoStart,
  required bool wasStarted,
  required bool startedNow,
  required bool bleAvailable,
  required bool udpAvailable,
}) =>
    autoStart && !wasStarted && !startedNow && (bleAvailable || udpAvailable);

/// Actions that mirror an accepted friend's live UDP address (peers slice,
/// which is not persisted) into the friendship record (which is), so the
/// last-known address survives an app restart and can seed reconnection —
/// the hydration path in `main.dart` re-associates it on startup.
///
/// One action per friend whose live address differs from the stored one.
/// A friend with no live address produces nothing: the stored address is the
/// peer's last known location and is never cleared unilaterally (CLAUDE.md
/// "Peer Address Persistence" — only an explicit peer report may clear it).
@visibleForTesting
List<UpdateFriendshipUdpAddressAction> computeFriendUdpAddressMirrorActions({
  required FriendshipsState friendships,
  required PeersState peers,
}) {
  final actions = <UpdateFriendshipUdpAddressAction>[];
  for (final friendship in friendships.friends) {
    final peer =
        peers.getPeerByPubkeyHex(friendship.peerPubkeyHex.toLowerCase());
    final address = peer?.udpAddress;
    if (address == null || address.isEmpty) continue;
    if (address == friendship.udpAddress) continue;
    actions.add(UpdateFriendshipUdpAddressAction(
      peerPubkeyHex: friendship.peerPubkeyHex,
      udpAddress: address,
    ));
  }
  return actions;
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

/// Peers whose `bleCentralDeviceId` / `blePeripheralDeviceId` is still set but
/// who haven't surfaced any BLE traffic (ANNOUNCE, message, ACK, RSSI poll)
/// within [staleThreshold]. The BLE transport plugin is supposed to emit a
/// disconnect when a path drops, but in practice that signal is brittle: a
/// path that drifts through `failed` / `subscribed` (status-133 storms, GATT
/// reinit churn) without a clean `ready → dropped` transition never fires
/// `_emitDisconnect`. This sweep is the safety net — applies equally to
/// friends and strangers, so the UI's "Connected Peers" list stops showing
/// peers we have no live BLE link to.
@visibleForTesting
Set<String> computeStaleBlePeerPubkeys({
  required Iterable<PeerState> peers,
  required Duration staleThreshold,
  DateTime? now,
}) {
  final evaluationTime = now ?? DateTime.now();
  final stale = <String>{};

  for (final peer in peers) {
    if (!peer.hasBleConnection) continue;
    final lastBleSeen = peer.lastBleSeen;
    // Without a `lastBleSeen` timestamp we can't say anything. Treat as
    // fresh — the very next ANNOUNCE will populate the field, and any
    // explicit disconnect from the transport will clear the device-id
    // before this sweep matters.
    if (lastBleSeen == null) continue;

    if (evaluationTime.difference(lastBleSeen) > staleThreshold) {
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

  /// Initialized libsodium (SUMO) instance for native Ed25519 sign/verify and
  /// the Ed25519↔X25519 conversion used to derive/verify Noise static keys.
  /// The caller (typically `main()`) is responsible for
  /// `await SodiumSumoInit.init()` once at app startup and passing the result
  /// here. SUMO is required for `crypto_sign_ed25519_*_to_curve25519`.
  final SodiumSumo sodium;

  /// Optional opt-in trace logger. When present and enabled, message/transport
  /// events are recorded for later upload. Null in tests / when logging is off.
  final ExperimentRecorder? trace;

  /// Subscription for listening to store changes
  StreamSubscription<AppState>? _storeSubscription;

  /// Last known settings state for detecting changes
  SettingsState? _lastSettingsState;

  /// Last accepted friend set broadcast through FRIEND_LIST.
  Set<String> _lastFriendPubkeyHexes = const {};

  /// Per-peer `isReachable` snapshot from the previous store tick. Used by
  /// the reachability subscriber to detect false→true (fire onPeerConnected)
  /// and true→false (fire onPeerDisconnected) transitions across the
  /// consolidated view of all transports. A missing entry is treated as
  /// `false` so a peer that materializes already-reachable fires connect.
  final Map<String, bool> _lastKnownReachability = {};

  /// Pubkeys (hex) already surfaced via [onPeerDiscovered] this session.
  /// Discovery is the identity-learned event — the first accepted ANNOUNCE
  /// carrying a peer's public key + nickname — which precedes the Noise session
  /// and therefore [onPeerConnected]. Fired once per identity; a peer going out
  /// of range and returning is a re-*connect*, not a re-discover.
  final Set<String> _discoveredPubkeyHexes = {};

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

  /// Fragment handler for large BLE messages. Also fragments the two cleartext,
  /// neighbour-local packet types (ANNOUNCE and Noise handshake) via
  /// [FragmentHandler.framesFor] with an explicit per-leg chunk budget — the
  /// frame is written as cleartext (`frame.encode()`) instead of sealed.
  late final FragmentHandler _fragmentHandler;

  /// Message router for incoming packet processing
  late final MessageRouter _messageRouter;

  /// Per-peer, per-transport Noise XX sessions for payload encryption.
  late final NoiseSessionManager _noiseSessions;

  /// Pending hole-punch completers: pubkeyHex → completer that resolves
  /// to true (connected) or false (failed) when the punch finishes.
  final Map<String, Completer<bool>> _holePunchCompleters = {};

  // ===== Invite / cold-bootstrap state =====

  /// Invites we are redeeming, keyed by inviter pubkey hex → the signed
  /// invite blob. When our Noise session to the inviter establishes (after
  /// the introducer coordinates the punch), we send an INTRODUCE to the
  /// inviter so it burns the nonce and authorizes us. Cleared on send.
  final Map<String, Uint8List> _pendingInviteRedemptions = {};

  /// As an introducer: how many times we've coordinated each invite nonce
  /// (nonceHex → count), to enforce the invite's `maxUses` locally and bound
  /// abuse. LRU-evicted at capacity.
  final Map<String, int> _introducedNonceUses = {};
  static const int _maxTrackedNonces = 1024;

  /// As an inviter: our own invites we've accepted redemptions for
  /// (nonceHex → use count), so the single-use nonce and `maxUses` are
  /// durably enforced. Persisted (see [_inviteNonceLedgerKey]) so a restart
  /// does not un-burn a still-unexpired invite.
  final Map<String, _BurnedNonce> _issuedNonceUses = {};

  /// Pubkey hexes of peers authorized via an invite we issued → the invite's
  /// expiry (unix secs). They may complete first contact even under a closed
  /// cold-call posture, but only until the invite that authorized them
  /// expires (the grant is time-boxed to the capability, not the session).
  final Map<String, int> _invitedContacts = {};

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

  /// FIFO outbound message queues keyed by recipient public-key hex.
  ///
  /// These hold application payloads that could not be sent because no live
  /// BLE/UDP path was available. They drain when the peer announces or a UDP
  /// connection event reports the peer as connected.
  /// messageId → the buffered packetIds belonging to it (one for a
  /// single-packet message, N for fragments) so the ACK can drop them from
  /// the buffer.
  ///
  /// BOUNDED BY THE BUFFER: an entry leaves when its packets leave, for ANY
  /// reason — the recipient's ACK, age expiry, or an eviction. The store
  /// reports the non-ACK exits through [MessageRouter.onBufferedPacketDropped]
  /// and [_forgetBufferedPacket] applies them here, so the index holds exactly
  /// the messages with packets still in the store.
  ///
  /// Draining the index on ACK alone would not do: the buffer sheds packets
  /// on ACK, expiry AND eviction, and every non-ACK exit would leave a dead
  /// entry behind. Once the index fills with dead entries its FIFO throws out
  /// LIVE ones, so a later ACK cannot release its packets and they linger to
  /// age expiry,
  /// which keeps the buffer full. That is the same failure an earlier bound of
  /// 1000 caused (178,138 evictions on a 7-device run); raising the number
  /// only made it slower to arrive, because the number was never the problem.
  final Map<String, List<String>> _dtnPacketIds = {};

  /// packetId → the messageId that sealed it. The store reports exits by
  /// packetId and the index is keyed by messageId, so without this the prune
  /// would be a scan of every entry per dropped packet.
  final Map<String, String> _dtnMessageOfPacket = {};

  /// Backstop only — reaching it means [_forgetBufferedPacket] is not being
  /// called, since the index cannot otherwise outgrow the buffer. It fires an
  /// `ackIndex / evicted` drop record, which is the alarm for exactly that
  /// regression; in a healthy run the count is zero.
  static const int _maxAckIndexEntries = 200000;


  // ===== Public callbacks =====

  /// Called when an application message is received.
  /// Parameters: messageId, senderPubkey, payload (raw GSG block data),
  /// transport (the transport the message actually arrived on).
  void Function(
    String messageId,
    Uint8List senderPubkey,
    Uint8List payload,
    MessageTransport transport,
  )? onMessageReceived;

  /// Spec-compliant receive callback
  /// (`docs/GLP_Networking_API/sections/api.tex` §onReceive).
  ///
  /// Fired alongside [onMessageReceived] for every accepted message. Use this
  /// when you only need the sender's pubkey and payload. The richer
  /// [onMessageReceived] variant additionally provides a transport-assigned
  /// `messageId` (useful for dedup / ACK correlation; also dispatched via the
  /// Redux `MessageReceivedAction`) and the transport the message actually
  /// arrived on (taken from the receive path).
  void Function(Uint8List senderPubkey, Uint8List payload)? onReceive;

  /// Spec: `docs/GLP_Networking_API/sections/api.tex` §onPeerDiscovered.
  /// Fires when a new peer's identity becomes known to us for the first
  /// time (the first ANNOUNCE arrives carrying their pubkey and nickname).
  /// Receives the peer's public key and nickname per the spec.
  void Function(Uint8List publicKey, String nickname)? onPeerDiscovered;

  /// Called when a peer becomes reachable (transitions from zero live
  /// transports to one or more). Fires again if the peer disconnects and
  /// later reconnects.
  void Function(PeerState peer)? onPeerConnected;

  /// Called when an existing peer sends an ANNOUNCE update.
  void Function(PeerState peer)? onPeerUpdated;

  /// Called when a peer is no longer reachable (transitions to zero live
  /// transports). Does not fire when losing one of multiple live transports.
  void Function(PeerState peer)? onPeerDisconnected;

  /// Called when UDP transport becomes available
  void Function()? onUdpInitialized;

  /// Spec: `docs/GLP_Networking_API/sections/api.tex` §onConnectivityStatus
  /// (named `onConnectivityStatusChanged` here — the spec name reads like a
  /// status getter; this is a change-event callback).
  /// "Callback when the networking layer detects a change in the agent's
  /// public IP address. Triggers the reconnection protocol. Fired on startup
  /// and on address change."
  ///
  /// Receives `(oldAddress, newAddress)` as `ip:port` strings (or null when
  /// no public address is available). The caller derives the kind of
  /// change:
  ///   - startup / gain: `oldAddress == null && newAddress != null`
  ///   - loss:           `oldAddress != null && newAddress == null`
  ///   - update:         both non-null and `oldAddress != newAddress`
  void Function(String? oldAddress, String? newAddress)?
      onConnectivityStatusChanged;

  // ===== Convenience accessors for Redux state =====

  PeersState get _peersState => store.state.peers;

  GrassrootsNetwork({
    required this.identity,
    this.config = const GrassrootsNetworkConfig(),
    required this.store,
    required this.sodium,
    this.trace,
  }) {
    _protocolHandler = ProtocolHandler(
      identity: identity,
      sodium: sodium,
    );
    _fragmentHandler = FragmentHandler();
    // A partial reassembly abandoned (4-min timeout, or count-complete but
    // unassemblable) is a whole-message loss, so it gets a drop record.
    _fragmentHandler.onAbandon = (reason, messageId, have, total) {
      _traceDrop('reassembly', reason, {
        'messageId': messageId,
        'have': have,
        'total': total,
      });
    };
    _noiseSessions = NoiseSessionManager(
      identity: identity,
      sodium: sodium,
      trace: trace,
    );
    _messageRouter = MessageRouter(
      identity: identity,
      store: store,
      protocolHandler: _protocolHandler,
      fragmentHandler: _fragmentHandler,
      trace: trace,
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
    _lastFriendPubkeyHexes = store.state.peers.friendPubkeyHexes;
    _storeSubscription = store.onChange.listen((state) {
      final previousSettings = _lastSettingsState;
      if (previousSettings != null && state.settings != previousSettings) {
        _lastSettingsState = state.settings;
        _onTransportSettingsChanged(previousSettings, state.settings);
      }
      final friendPubkeyHexes = state.peers.friendPubkeyHexes;
      if (!setEquals(friendPubkeyHexes, _lastFriendPubkeyHexes)) {
        _lastFriendPubkeyHexes = friendPubkeyHexes;
        _broadcastFriendListToFriends(reason: 'friendship changed');
      }
      // Mirror friends' live UDP addresses into the persisted friendship
      // records so the last-known address survives restart. Converges in one
      // extra change notification: the mirror dispatch updates the friendship,
      // after which the addresses compare equal and no further action is
      // produced. (onChange is an async broadcast stream, so dispatching here
      // is not reentrant.)
      for (final action in computeFriendUdpAddressMirrorActions(
        friendships: state.friendships,
        peers: state.peers,
      )) {
        store.dispatch(action);
      }
      _processReachabilityTransitions(state.peers);
    });
  }

  /// Whether BLE transport is available (initialized and usable)
  bool get _bleAvailable =>
      _bleService != null && store.state.transports.bleState.isUsable;

  /// Whether UDP transport is available (initialized and usable)
  bool get _udpAvailable =>
      _udpService != null && store.state.transports.udpState.isUsable;

  /// Currently reachable peers — spec `docs/GLP_Networking_API/sections/api.tex`
  /// §getPeers: "Discover currently reachable peers." Returns only peers
  /// where `isReachable` is true (i.e. at least one transport is live).
  /// Callers that need the full list of known peers (including offline ones)
  /// can read `store.state.peers.peersList` directly.
  List<PeerState> getPeers() =>
      _peersState.peersList.where((p) => p.isReachable).toList();

  /// Check if a peer is reachable via any transport
  bool isPeerReachable(Uint8List pubkey) => _peersState.isPeerReachable(pubkey);

  /// The agent's current public `ip:port`, or null if not yet known.
  /// Address changes are surfaced via [onConnectivityStatusChanged].
  String? getPublicAddress() => store.state.transports.publicAddress;

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

  ColdCallTrustLevel get coldCallTrustLevel =>
      store.state.settings.coldCallTrustLevel;

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

  /// Force a fresh public-address discovery attempt, bypassing the seeip cache.
  ///
  /// Invoked by the UI when the user taps "Retry" on the no-public-address
  /// warning. Friend/RV reflection runs on its own cadence and is not poked
  /// here; this only re-runs seeip-based discovery.
  Future<void> retryPublicAddressDiscovery() async {
    _publicAddressDiscovery.invalidateCache();
    await _discoverPublicAddress();
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

    // Restore the burned-invite-nonce ledger so a restart doesn't un-burn a
    // still-unexpired invite we issued.
    unawaited(_loadInviteNonceLedger());

    bool anyTransportInitialized = false;

    try {
      // Initialize BLE if enabled
      if (_isBleEnabledInSettings) {
        // First start: no service exists, so state must read uninitialized
        // for BleTransportService.initialize() to proceed.
        store.dispatch(
            BleTransportStateChangedAction(TransportState.uninitialized));
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
  /// [promptForPermissions] false = verify the grants we already hold and
  /// never issue a request.
  ///
  /// A transport RESTART is not a fresh app start. Issuing a request on every
  /// restart risks a call that does not come back `granted`, and this method
  /// then returns before it ever touches the BLE stack — leaving `_bleService`
  /// null, so every later bounce returns at its first line and the radio never
  /// comes back. A restart already holds the grants; it only has to check.
  Future<bool> _initializeBle({bool promptForPermissions = true}) async {
    if (_bleInitInFlight) {
      debugPrint('BLE init already in flight — refusing to race it');
      return false;
    }
    _bleInitInFlight = true;
    try {
      debugPrint('Initializing BLE transport');

      // Deliberately does NOT reset the transport state. Blanking it here
      // would apply to every caller, including one that then fails or bails,
      // and would wipe a transport that is working.
      // `BleTransportService.initialize()` only proceeds from `uninitialized`,
      // so a caller that is genuinely replacing a disposed service sets that
      // state itself, next to the dispose that made it true.
      if (promptForPermissions) {
        final permResult = await _permissions.requestPermissions();
        _lastPermissionOutcome = permResult.name;
        debugPrint('[perm] requestPermissions -> $permResult');
        if (permResult != PermissionResult.granted) {
          debugPrint('BLE permissions not granted: $permResult');
          return false;
        }
      } else {
        final held = await _permissions.hasRequiredPermissions();
        _lastPermissionOutcome = held ? 'held' : 'notHeld';
        debugPrint('[perm] hasRequiredPermissions -> $held (no prompt)');
        if (!held) {
          debugPrint('BLE permissions not held on restart');
          return false;
        }
      }

      // Create BLE transport service (manages BLE manager + router)
      _bleService = BleTransportService(
        identity: identity,
        store: store,
        localName: config.localName ?? identity.nickname,
        trace: trace,
      );
      // Wire-ledger content split: only we know what our sealed packets carry.
      _bleService!.secureContentResolver =
          (packetId) => _sealedContentById[packetId] ?? '';
      // A dial-grid step bounces the transport, so the cap it set has to be
      // re-applied to the replacement service or the step would silently run
      // at the production cap.
      _bleService!.setDialParallelism(
          maxParallel: _dialProbeMaxParallel, popN: _dialProbePopN);

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
    } finally {
      _bleInitInFlight = false;
    }
  }

  /// True while [_initializeBle] is running. Two initializations overlapping
  /// is how the transport ended up neither old nor new: the scripted bring-up
  /// and the bounce's delayed re-init both ran, and the loser left the state
  /// pointing at a service the winner had replaced.
  bool _bleInitInFlight = false;

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
        trace: trace,
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
    // Keep the Android process unfrozen while transports run — a frozen Dart
    // VM goes ANNOUNCE-silent and never dials reverse BLE legs, while its
    // radio links stay up (peers then flap us through their stale sweeps).
    unawaited(TransportForegroundService.start());
    _startAnnounceTimer();
    _startScanTimer();
  }

  /// Stop scanning and advertising.
  Future<void> stop() async {
    if (!_started) return;

    debugPrint('Stopping Grassroots transport');
    _started = false;
    unawaited(TransportForegroundService.stop());
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
      // Session kept: end-to-end Noise sessions are path-independent.
    }

    if (_udpService != null) {
      try {
        await _udpService!.stop();
      } catch (e) {
        debugPrint('Error stopping UDP: $e');
      }
      // Session kept: end-to-end Noise sessions are path-independent.
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

  /// Clear per-friend proactive-UDP backoff state.
  ///
  /// Invoked when our own public address changes, because the prior failures
  /// were observed through the previous network path: the OS UDP socket may
  /// have been rebound and NAT mappings invalidated, so the reason for those
  /// failures may no longer apply.
  void _resetAutoUdpBackoff() {
    if (_autoUdpRetryAfter.isEmpty && _autoUdpLastAddress.isEmpty) return;
    debugPrint(
      '[auto-udp] Resetting per-friend backoff '
      '(${_autoUdpRetryAfter.length} entries) after public-address change',
    );
    _autoUdpRetryAfter.clear();
    _autoUdpLastAddress.clear();
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
      // Session kept: end-to-end Noise sessions are path-independent.
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

    await _reconnectUdpFriends(reason: 'connectivity-changed');
  }

  /// Walk every UDP-eligible friend and bring them back online.
  /// Direct-dial known addresses; fan out RECONNECT to facilitators for
  /// friends we couldn't reach directly. Idempotent — already-connected
  /// friends are skipped by [_connectToFriendViaUdp] and by the second-pass
  /// [getPeerIdForPubkey] guard.
  Future<void> _reconnectUdpFriends({required String reason}) async {
    if (!_udpAvailable) return;

    final udpFriends = _peersState.friends
        .where((peer) => _udpCandidatesForPeer(peer).isNotEmpty)
        .toList()
      ..sort((a, b) {
        if (a.isWellConnected == b.isWellConnected) return 0;
        return a.isWellConnected ? -1 : 1;
      });
    if (udpFriends.isEmpty) return;

    debugPrint(
      '[reconnect] Sweeping ${udpFriends.length} UDP friends ($reason)',
    );

    for (final friend in udpFriends) {
      final candidates = _udpCandidatesForPeer(friend);
      final friendAddress = friend.udpAddress ??
          (candidates.isNotEmpty ? candidates.first : null);
      if (friendAddress == null) continue;
      await _connectToFriendViaUdp(friend.pubkeyHex, friendAddress);
    }

    // Fan out RECONNECT for friends still unreachable. Eligible friend
    // mediators are selected through the friends-of-friends map and
    // coordinate directly.
    if (store.state.peers.wellConnectedFriends.isEmpty) return;

    for (final friend in udpFriends) {
      if (_udpService?.getPeerIdForPubkey(friend.publicKey) != null) continue;
      debugPrint(
        '[reconnect] Fanning out RECONNECT for ${friend.displayName} '
        'after IP change',
      );
      unawaited(
        _signalingService.fanOutReconnect(
          friend.publicKey,
          initiatorPubkey: identity.publicKey,
        ),
      );
    }
  }

  /// Public entry point for triggering a UDP friend-reconnection sweep.
  /// Chains on the transport update lock so it cannot overlap with a
  /// connectivity-driven or settings-driven restart.
  Future<void> reconnectUdpFriends({required String reason}) {
    final previous = _transportUpdateLock ?? Future.value();
    final next = previous.then((_) => _reconnectUdpFriends(reason: reason));
    _transportUpdateLock = next;
    return next;
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
        // Session kept: end-to-end Noise sessions are path-independent.
        await _bleService!.dispose();
        _bleService = null;
      }
      // The dispose above is what makes `uninitialized` true; say so here,
      // next to it, rather than inside _initializeBle where it also applied
      // to callers that were not replacing anything.
      store.dispatch(
          BleTransportStateChangedAction(TransportState.uninitialized));
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
      // Session kept: end-to-end Noise sessions are path-independent.

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
        await _reconnectUdpFriends(reason: 'settings-enabled');
      }
    } else if (!_isUdpEnabledInSettings && _udpAvailable) {
      // UDP was disabled, dispose service and clean up
      debugPrint('UDP disabled from settings, cleaning up...');

      for (final service in _holePunchServices.values) {
        service.dispose();
      }
      _holePunchServices.clear();

      if (_udpService != null) {
        // Session kept: end-to-end Noise sessions are path-independent.
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

    // Cold-start recovery: if the transport was never started (e.g. the first
    // initialize() found no usable transport because BLE permission was denied
    // and UDP was off, so it returned without calling start()) and a transport
    // has now come up via this settings change, do a full start. Otherwise the
    // service is live but inert — no advertising, no scanning, no announce/scan
    // timers, no started flag — until the app restarts. The per-transport
    // start() calls above only cover the warm path (wasStarted == true); start()
    // itself is guarded by _started, so this cannot double-start.
    if (shouldColdStartAfterSettingsChange(
      autoStart: config.autoStart,
      wasStarted: wasStarted,
      startedNow: _started,
      bleAvailable: _bleAvailable,
      udpAvailable: _udpAvailable,
    )) {
      debugPrint(
        'Transport came up from settings while never started — starting now',
      );
      await start();
      if (_udpAvailable) {
        await _reconnectUdpFriends(reason: 'settings-enabled-cold-start');
      }
    }
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

  Future<void> setColdCallTrustLevel(ColdCallTrustLevel level) async {
    if (store.state.settings.coldCallTrustLevel == level) return;
    store.dispatch(SetColdCallTrustLevelAction(level));
    // Re-filter the scanner immediately. Closed trust scans for the friend
    // set alone; open trust goes back to the prefix scan. Waiting for the
    // scan watchdog would leave a closed node meeting strangers for up to a
    // silence window after the user asked it to stop.
    await _bleService?.applyTrustModeChange();
  }

  static const _uuid = Uuid();

  // ===== Messaging =====

  /// Send a message to a specific peer.
  ///
  /// Routes through the best available transport:
  /// 1. Bluetooth (if peer is nearby and BLE is enabled)
  /// 2. UDP (if peer has UDP address and UDP is enabled)
  ///
  /// Returns the message ID if the message was sent or queued, null only for
  /// invalid input.
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
    if (recipientPubkey.length != 32) {
      debugPrint('Cannot send: recipient public key must be 32 bytes');
      return null;
    }

    // Use provided message ID or generate one. Full UUID required —
    // packet.packetId is wire-encoded as 16 bytes, so a short prefix would
    // be corrupted on serialization.
    messageId ??= _uuid.v4();

    // Dispatch sending action (clock icon)
    store.dispatch(
      MessageSendingAction(
        messageId: messageId,
        transport: MessageTransport.ble, // Tentative — updated on actual send
        recipientPubkey: recipientPubkey,
        payloadSize: payload.length,
      ),
    );

    if (await _trySendMessageNow(
      recipientPubkey: recipientPubkey,
      payload: payload,
      messageId: messageId,
    )) {
      return messageId;
    }

    // No session with the recipient and none could be established, so no
    // packet was ever created and there is nothing to hold. The message fails
    // here and the user retries once the peer is actually reachable — a
    // plaintext hold waiting for a first pairing is exactly the thing this
    // design refuses to keep.
    store.dispatch(MessageFailedAction(messageId: messageId));
    debugPrint(
      '[send] No session with '
      '${_pubkeyToHex(recipientPubkey).substring(0, 8)}; nothing created, '
      'message failed',
    );
    return messageId;
  }

  Future<bool> _trySendMessageNow({
    required Uint8List recipientPubkey,
    required Uint8List payload,
    required String messageId,
  }) async {
    // A PACKET MAY NOT EXIST BEFORE A SESSION WITH ITS TARGET DOES. This is
    // the invariant, and it is enforced by ordering: establish the session
    // first, and return without ever calling `createMessagePacket` if none can
    // be had. Nothing is held, nothing is queued, nothing half-formed survives
    // this function — a send to a peer we have never handshaked with simply
    // fails, and the user retries once the peer is actually there.
    //
    // A peer RECORD is not what sending needs — a session is. The stale sweep
    // deletes a non-friend peer from `peersList` after ten announce cycles of
    // silence while its Noise session survives untouched, so a recipient that
    // has merely gone quiet has no record but is still perfectly sendable:
    // `hasSession` short-circuits the establish below and the message seals,
    // buffers and floods as normal. That is the store-carry-forward case, and
    // it is why the gate is the SESSION and never the record.
    // The send path does NOT establish sessions. Pairing is eager and lives
    // where it belongs: every accepted ANNOUNCE drives a Noise handshake, any
    // sessionless side initiates, and by the time a user can address a peer
    // the session either exists or that peer is not someone we can talk to.
    // Handshaking from inside send would put session setup on the message
    // latency path and, worse, make "sending" the thing that decides who we
    // have met.
    final peer = _peersState.getPeerByPubkey(recipientPubkey);
    if (!_noiseSessions.hasSession(recipientPubkey)) {
      debugPrint('Cannot send: no session with '
          '${_pubkeyToHex(recipientPubkey).substring(0, 8)}; no packet created');
      _traceMessage('failed', messageId, {
        'reason': 'noSession',
        'peer': _pubkeyToHex(recipientPubkey),
      });
      return false;
    }

    // Only now, with a session in hand, may a packet exist. Its payload is
    // sealed to the recipient's Noise session before flooding; the
    // sender-anonymous envelope carries no wire signature (authentication is
    // end-to-end inside Noise).
    // packetId == messageId so the recipient's ACK (which echoes the
    // packetId back) matches the entry we just stored under `messageId`
    // in `MessageSendingAction`. Otherwise `MessageDeliveredAction` would
    // look up an unrelated UUID and never flip ✓ → ✓✓.
    final packet = _protocolHandler.createMessagePacket(
      payload: payload,
      recipientPubkey: recipientPubkey,
      messageId: messageId,
    );

    // --- BLE mesh: seal to the recipient's session and flood ---
    // Reaches the recipient whether they are a direct neighbor or several hops
    // away, as long as we hold an end-to-end Noise session with them. The
    // session is established neighbor-local (handshake with a direct neighbor)
    // and then survives the peer drifting out of direct range — which is what
    // lets us keep messaging them across the mesh.
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null) {
      // null when the recipient is not a direct neighbor; the handshake inside
      // _ensureNoiseSession only succeeds for a direct neighbor, but an existing
      // session lets us flood to a non-adjacent recipient.
      // Null for a delisted or non-adjacent recipient. That is fine: with a
      // session in hand _ensureNoiseSession short-circuits before it needs a
      // path, and the sealed packets flood to whoever is in range.
      final bleDeviceId =
          peer == null ? null : _connectedBleDeviceIdForPeer(peer);
      final ready = await _ensureNoiseSession(
        transport: PeerTransport.bleDirect,
        recipientPubkey: recipientPubkey,
        peerId: bleDeviceId,
      );
      if (ready) {
        debugPrint('Flooding message into BLE mesh for '
            '${peer?.displayName ?? _pubkeyToHex(recipientPubkey).substring(0, 8)}');
        // Seal ONCE; the sealed packets are simultaneously the wire bytes and
        // our own buffer entries — the sender holds its outgoing packets
        // exactly as a relay would. Offered in sync-on-connect, kept until ACK.
        final List<GrassrootsPacket> sealedPackets;
        try {
          sealedPackets = _fragmentHandler.needsFragmentation(payload)
              ? await _sealFragments(
                  payload: payload,
                  recipientPubkey: recipientPubkey,
                  messageId: messageId,
                )
              : [
                  await _noiseSessions.encryptPacket(
                    packet,
                    remotePubkey: recipientPubkey,
                  ),
                ];
        } on StateError {
          // Check-then-encrypt race: the session vanished between the
          // hasSession gate and sealing (testbed reset, handshake-timeout
          // reset, glare teardown). Reported, and the caller FAILS the
          // message — nothing is held in 'sending' without evidence.
          _traceDrop('seal', 'sessionRace', {'messageId': messageId});
          return false;
        }
        _dtnPacketIds[messageId] = [
          for (final p in sealedPackets) p.packetId,
        ];
        for (final p in sealedPackets) {
          _dtnMessageOfPacket[p.packetId] = messageId;
        }
        // THE fragment join: relay/packetDup/custody/decrypt records carry
        // only per-fragment packetIds, and for a fragmented message those are
        // random — unjoinable to the messageId without this record.
        _traceMessage('sealed', messageId, {
          'peer': _pubkeyToHex(recipientPubkey),
          'packetIds': [for (final p in sealedPackets) p.packetId],
          'fragments': sealedPackets.length,
        });
        while (_dtnPacketIds.length > _maxAckIndexEntries) {
          final evicted = _dtnPacketIds.keys.first;
          for (final id in _dtnPacketIds.remove(evicted) ?? const <String>[]) {
            _dtnMessageOfPacket.remove(id);
          }
          // A later ACK for this message can no longer release its packets
          // early — they linger to age expiry. Silent before.
          _traceDrop('ackIndex', 'evicted', {'messageId': evicted});
        }
        // The router owns the outbound decision — direct-write when the
        // recipient is a connected neighbour, DTN buffer when it is not — one
        // path for every packet type, no per-type delivery logic here.
        var aired = false;
        for (final p in sealedPackets) {
          if (await _messageRouter.dispatchOutbound(recipientPubkey, p)) {
            aired = true;
          }
        }

        final wireMs = DateTime.now().millisecondsSinceEpoch;
        // [aired]: on the air now (direct write to a connected recipient).
        // Otherwise the packets sit in the DTN buffer and leave when a
        // neighbour asks for them in a sync exchange.
        _markSent(
          messageId: messageId,
          recipientPubkey: recipientPubkey,
          payload: payload,
          transport: MessageTransport.ble,
          aired: aired,
          atMs: wireMs,
        );
        return true;
      }
      debugPrint('BLE mesh send unavailable, falling back to UDP...');
    }

    // --- Try UDP (direct connection or connect-on-demand) ---
    if (_isUdpEnabledInSettings && _udpAvailable && _udpService != null) {
      // Re-read peer — state may have changed during BLE attempt.
      final resolvedPeer = _peersState.getPeerByPubkey(recipientPubkey) ?? peer;
      // UDP addresses a peer by its record, so without one there is nothing to
      // dial — unlike BLE above, where the session carries the identity and
      // no address is needed. The send fails; nothing is held.
      if (resolvedPeer == null) return false;

      // Try existing UDX connection first
      if (_udpService!.getPeerIdForPubkey(recipientPubkey) != null) {
        final bytes = await _sealedPacketBytesForTransport(
          packet: packet,
          transport: PeerTransport.udp,
          recipientPubkey: recipientPubkey,
          peerId: resolvedPeer.pubkeyHex,
        );
        final udpWireMs = DateTime.now().millisecondsSinceEpoch;
        if (bytes != null &&
            await _udpService!.sendToPeer(resolvedPeer.pubkeyHex, bytes)) {
          // debugPrint(
          //   'Sent via existing UDP connection to ${resolvedPeer.displayName}',
          // );
          _markSent(
            messageId: messageId,
            recipientPubkey: recipientPubkey,
            payload: payload,
            transport: MessageTransport.udp,
            aired: true,
            atMs: udpWireMs,
          );
          return true;
        }
      }

      // No existing connection — try connect-on-demand if we have an address
      final udpCandidates = _udpCandidatesForPeer(resolvedPeer);
      if (udpCandidates.isNotEmpty) {
        final udpAddr = resolvedPeer.udpAddress ?? udpCandidates.first;
        debugPrint(
          'Sending via UDP to ${resolvedPeer.displayName} at $udpCandidates',
        );
        final demandWireMs = DateTime.now().millisecondsSinceEpoch;
        if (await _sendPacketViaUdp(
          pubkeyHex: resolvedPeer.pubkeyHex,
          udpAddress: udpAddr,
          packet: packet,
          recipientPubkey: recipientPubkey,
        )) {
          _markSent(
            messageId: messageId,
            recipientPubkey: recipientPubkey,
            payload: payload,
            transport: MessageTransport.udp,
            aired: true,
            atMs: demandWireMs,
          );
          return true;
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
            final discWireMs = DateTime.now().millisecondsSinceEpoch;
            if (await _sendPacketViaUdp(
              pubkeyHex: freshPeer.pubkeyHex,
              udpAddress: freshPeer.udpAddress ?? freshCandidates.first,
              packet: packet,
              recipientPubkey: recipientPubkey,
            )) {
              _markSent(
                messageId: messageId,
                recipientPubkey: recipientPubkey,
                payload: payload,
                transport: MessageTransport.udp,
                aired: true,
                atMs: discWireMs,
              );
              return true;
            }
          }
        }
        debugPrint('[send] Discovery failed for ${resolvedPeer.displayName}');
      }
    }

    debugPrint(
      'No transport currently available for '
      '${peer?.displayName ?? _pubkeyToHex(recipientPubkey).substring(0, 8)}; '
      'queuing message',
    );
    return false;
  }

  // ===== Delivery status + DTN buffer lifecycle =====
  //
  // A sent message's sealed packets sit in this node's DTN memory buffer
  // (DtnStore._byRecipient) until the recipient's end-to-end ACK arrives —
  // the sender holds its own outgoing packets exactly as a relay holds a
  // stranger's. There is no sender-side retry machinery: redelivery happens
  // through the sync vector exchange (sync-on-connect) each time a pairing
  // forms, and through relays conveying buffered copies onward. The ACK's
  // only jobs are the Redux status flip (checkmarks) and emptying the
  // buffer of that message's packets.

  /// Number of currently-reachable peers — the temporal node degree recorded
  /// on trace records at send/deliver time.
  int _reachablePeerCount() =>
      store.state.peers.peers.values.where((p) => p.isReachable).length;

  /// Coordinator-side loss record: same shape as the router's, one type for
  /// every drop/timeout/failure so the analyzer counts loss by site.
  void _traceDrop(String where, String reason,
      [Map<String, dynamic> extra = const {}]) {
    if (!(trace?.active ?? false)) return;
    unawaited(trace!.log({
      'type': 'drop',
      't': DateTime.now().millisecondsSinceEpoch,
      'where': where,
      'reason': reason,
      ...extra,
    }));
  }

  void _traceMessage(String dir, String messageId,
      [Map<String, dynamic> extra = const {}]) {
    if (!(trace?.active ?? false)) return;
    unawaited(trace!.log({
      'type': 'message',
      't': DateTime.now().millisecondsSinceEpoch,
      'dir': dir,
      'messageId': messageId,
      ...extra,
    }));
  }

  void _markSent({
    required String messageId,
    required Uint8List recipientPubkey,
    required Uint8List payload,
    required MessageTransport transport,
    required bool aired,
    required int atMs,
  }) {
    // The buffer entry exists either way; `aired` only drives the status shown.
    store.dispatch(aired
        ? MessageSentAction(
            messageId: messageId,
            transport: transport,
            recipientPubkey: recipientPubkey,
            payloadSize: payload.length,
          )
        : MessageQueuedAction(messageId: messageId));
    if (trace?.active ?? false) {
      unawaited(trace!.log({
        'type': 'message',
        // The wire-write instant captured BEFORE the transport await — this
        // record is written after it, and under saturating load that gap ran
        // to hundreds of ms: a nearby receiver logged the arrival first,
        // which read as negative latency. Stamp the event, not the logging.
        't': atMs,
        'dir': 'sent',
        'messageId': messageId,
        'peer': _pubkeyToHex(recipientPubkey),
        'transport': transport == MessageTransport.udp ? 'udp' : 'ble',
        'payloadSize': payload.length,
        'degreeAtEvent': _reachablePeerCount(),
        'sentAt': atMs,
        // Whether the send reached at least one neighbour. aired:false is a
        // send that exists only in this node's DTN buffer until a sync
        // exchange, which the trace has to be able to tell apart.
        'aired': aired,
      }));
    }
  }

  /// The recipient confirmed delivery (ACK or read receipt): drop it from
  /// our buffer
  /// of every sealed packet belonging to [messageId].
  void _dropFromDtnBufferFor(String messageId) {
    final ids = _dtnPacketIds.remove(messageId);
    for (final id in ids ?? const <String>[]) {
      _dtnMessageOfPacket.remove(id);
    }
    _messageRouter.dropFromDtnBuffer(ids ?? [messageId]);
  }

  /// Withdraw an unconfirmed sent message from the buffer so it stops being
  /// conveyed — used to cancel an outstanding friend request. Idempotent: a
  /// message already ACKed, expired, or from a previous process (the buffer is
  /// memory-only) simply is not there.
  void cancelBufferedMessage(String messageId) =>
      _dropFromDtnBufferFor(messageId);

  /// A packet left the DTN buffer without an ACK. Forget it, and forget the
  /// whole message once its LAST packet is gone — a fragmented message keeps
  /// its entry while any fragment is still buffered, so an ACK can still
  /// release the rest.
  void _forgetBufferedPacket(String packetId) {
    final messageId = _dtnMessageOfPacket.remove(packetId);
    if (messageId == null) return;
    final ids = _dtnPacketIds[messageId];
    if (ids == null) return;
    ids.remove(packetId);
    if (ids.isEmpty) _dtnPacketIds.remove(messageId);
  }

  /// DEBUG/TESTBED ONLY. Notified on every end-to-end ACK so the field
  /// runner's saturating mode can refill its send window.
  void Function(String messageId)? onTestbedAck;

  BulkFlowDriver? _bulkFlowDriver;

  /// DEBUG/TESTBED ONLY. The sustained-throughput driver (data-plane
  /// evaluation), lazily bound to [send]. Inert until [startBulkFlows].
  BulkFlowDriver get bulkFlowDriver => _bulkFlowDriver ??= BulkFlowDriver(
        send: send,
        log: (m) => debugPrint(m),
        trace: trace,
      );

  /// DEBUG/TESTBED ONLY. Begin executing the bulk-flow config stored in
  /// settings. No-op without a config or while already running.
  void startBulkFlows() {
    final config = store.state.settings.bulkFlowConfig;
    if (config == null) {
      debugPrint('[bulk] no bulk-flow config set');
      return;
    }
    bulkFlowDriver.start(
        config: config, myPubkeyHex: _pubkeyToHex(identity.publicKey));
  }

  /// DEBUG/TESTBED ONLY. Stop the bulk-flow driver.
  void stopBulkFlows() => _bulkFlowDriver?.stop();

  /// DEBUG/TESTBED ONLY. Drop every Noise session so the next contact runs
  /// the full establishment ladder from a cold handshake (the field runner
  /// invokes this at each experiment step). Messages sent while sessionless
  /// wait in the pending-seal buffer and trigger the lazy handshake.
  /// DEBUG/TESTBED ONLY. Send one raw-throughput blob (unsealed, un-ACKed,
  /// dropped before the peer's parser) to [peer] over [leg]. Returns the blob
  /// size or null when the leg is not available.
  Future<int?> sendRawBlob(Uint8List peer,
          {required String leg,
          required int seq,
          int sizeDelta = 0}) async =>
      _bleService?.sendRawBlob(
          peerHex: _pubkeyToHex(peer),
          leg: leg,
          seq: seq,
          sizeDelta: sizeDelta);

  /// Bytes on the air over BLE since the transport last came up, tx and rx
  /// together. Counted at the GATT send/receive choke points, so this only
  /// moves when a peer is actually connected — advertising and scanning are
  /// invisible to it. A device whose radio is up but alone reads zero.
  int get bleWireBytes => _bleService?.wireBytes ?? 0;

  /// Whether the BLE transport is up and usable. Unlike [bleWireBytes] this
  /// holds with no peer in range, so it is the liveness signal for a scripted
  /// radio bring-up that is deliberately alone ([setBleActiveForTestbed],
  /// whose failure paths return silently and leave the transport down).
  bool get bleUsable {
    // ACTIVE only. `ready` means "initialized, will start when the adapter
    // allows" — it is where the transport parks when system Bluetooth is
    // OFF (adapter-off drops active back to ready; init with the adapter
    // off lands there too). Counting it as usable made a phone with its
    // radio dark read as radio-up: the manual runner then showed TURN OFF
    // BLUETOOTH to an operator whose Bluetooth was already off, and its
    // bt-on/bt-off markers — the anchors of every establishment
    // measurement — were fiction.
    return _bleService != null &&
        store.state.transports.bleState == TransportState.active;
  }

  /// [bleUsable] transitions, emitted at the store dispatch that changes the
  /// transport state — i.e. at the state change itself, not at some later
  /// poll. The testbed stamps its `bt-on`/`bt-off` markers from this stream,
  /// which is what lets analysis treat those timestamps as exact: the
  /// transport cannot form a session before it reports active, so no session
  /// can predate its own bt-on marker.
  Stream<bool> get bleUsableChanges =>
      store.onChange.map((_) => bleUsable).distinct();

  /// Peers this phone holds a Noise session with — recorded in each field-run
  /// step summary alongside [noiseSessionCount].
  int get sessionPeerCount => _peersState.peersList
      .where((p) =>
          p.publicKey.length == 32 && _noiseSessions.hasSession(p.publicKey))
      .length;

  /// Sessions actually held, straight from the session table.
  ///
  /// [sessionPeerCount] intersects the table with Redux `peersList`, and a
  /// non-friend peer is pruned from that list after ten announce cycles of
  /// silence while its Noise session survives untouched — so the two numbers
  /// diverge exactly when a link goes quiet, which is the case field runs
  /// care about. Recording both makes "the session is gone" distinguishable
  /// from "the peer stopped being listed".
  int get noiseSessionCount => _noiseSessions.sessionCount;

  /// DEBUG/TESTBED ONLY. The BLE legs that are live RIGHT NOW, for the
  /// experiment recorder's start-of-trace snapshot.
  List<Map<String, dynamic>> bleLinkSnapshot() =>
      _bleService?.liveLinkSnapshot() ?? const [];

  /// DEBUG/TESTBED ONLY. Measure this device's failed-AEAD and Noise-XX
  /// handshake costs — the two constants that size [maxSessions] and that
  /// decide whether the envelope's recipient field can be dropped. CPU-bound
  /// and several seconds long; the caller warns the user.
  Future<Map<String, dynamic>> runCryptoBench() =>
      CryptoBench.run(sodium: sodium);

  /// DEBUG/TESTBED ONLY. Empty the DTN memory buffer and the packetId index
  /// that maps messages to their buffered packets.
  void clearDtnBuffer() {
    debugPrint('[testbed] Clearing DTN memory buffer');
    _messageRouter.clearDtnBuffer();
    _dtnPacketIds.clear();
    _dtnMessageOfPacket.clear();
  }

  void resetAllSessions() {
    debugPrint('[testbed] Dropping all Noise sessions');
    _noiseSessions.resetAll();
  }

  /// DEBUG/TESTBED ONLY. Whether the pair with [pubkey] is fully settled for
  /// data: an authenticated Noise session AND the converged dual-leg link
  /// (both BLE legs attached). The field runner gates each step's sends on
  /// this so messages only travel over a link that is really ready — the
  /// establishment ladder itself is measured by the link events, not by
  /// racing data into a half-formed pair.
  bool isPeerLinkSettled(Uint8List pubkey) {
    if (!_noiseSessions.hasSession(pubkey)) return false;
    final peer = _peersState.getPeerByPubkey(pubkey);
    return peer != null &&
        peer.bleCentralDeviceId != null &&
        peer.blePeripheralDeviceId != null;
  }

  /// DEBUG/TESTBED ONLY. Bounce the BLE transport — the exact teardown the
  /// settings BLE toggle performs (dispose the service + clear Redux BLE
  /// state), a brief dark gap, then a full cold re-initialize. Unlike a bare
  /// path disconnect this stops advertising + scanning, so the pair genuinely
  /// goes dark and re-establishes through the normal cold-start election
  /// (no chaotic same-identity redial race). The field runner pairs this with
  /// [resetAllSessions] for a clean per-step establishment ladder. Awaited by
  /// the runner so the step's sends only begin once the transport is back.
  ///
  /// [darkSec] overrides the dark gap (see below). Supply it only when EVERY
  /// device bounces at the same instant — then both sides dispose together,
  /// no stale path can survive on either, and there is nothing to wait for.
  Future<void> resetAllBleLinks({int? darkSec}) async {
    if (_bleService == null) return;
    debugPrint('[testbed] BLE bounce: disposing transport (going dark)');
    await _bleService!.dispose();
    _bleService = null;
    store.dispatch(
        BleTransportStateChangedAction(TransportState.uninitialized));
    store.dispatch(ClearDiscoveredBlePeersAction());
    for (final peer in _peersState.peersList) {
      if (peer.hasBleConnection) {
        store.dispatch(PeerBleDisconnectedAction(peer.publicKey));
      }
    }
    // Dark gap = 2 announce cycles + 10s. Going dark disposes the transport,
    // so the peer learns through real link-layer disconnect events, not the
    // stale sweep — the sweep (now 10 announce cycles) is only the safety net
    // for a disconnect the peer's plugin failed to surface, and this gap no
    // longer outlives it. Accepted: a peer that missed the event still holds
    // a stale path, and its own connect handler closes stale GATTs on our
    // redial, so the pair re-establishes cold either way.
    final darkGap = darkSec != null
        ? Duration(seconds: darkSec)
        : config.announceInterval * 2 + const Duration(seconds: 10);
    debugPrint('[testbed] BLE bounce: staying dark ${darkGap.inSeconds}s');
    await Future<void>.delayed(darkGap);
    if (!_isBleEnabledInSettings) return; // user turned BLE off meanwhile
    debugPrint('[testbed] BLE bounce: re-initializing transport');

    // The bounce is BUDGETED, never awaited to success. Steps are anchored to
    // wall clock and every device must be in the same step at the same time,
    // so retrying here until the radio came back would make this phone late
    // and put it in a different step from the rest of the fleet — worse than
    // the outage. We bring the transport up, check ONCE, record what actually
    // happened, and return on time either way. A step that ran without a
    // radio is then visible as such instead of reporting honest-looking zeros.
    //
    // The record matters because a transport that comes back as `ready` and
    // never reaches `active` never runs `start()`, so no ANNOUNCE goes out and
    // a silent step is indistinguishable from a step of failed dials.
    //
    // Something else may bring the transport up while we are dark — the step's
    // scripted `bleOn: true` does exactly that, landing inside the dark gap
    // and leaving the radio scanning and advertising. Re-initializing on top
    // of that would tear down a working transport and leave the state
    // `uninitialized`. If the radio is already up, the bounce has nothing
    // left to do.
    if (_bleService != null && bleUsable) {
      debugPrint('[testbed] BLE bounce: transport already back up — '
          'leaving it alone');
      if (trace?.active ?? false) {
        unawaited(trace!.log({
          'type': 'link',
          't': DateTime.now().millisecondsSinceEpoch,
          'event': 'bounce',
          'darkSec': darkGap.inSeconds,
          'reinit': false,
          'usable': true,
          'bleState': store.state.transports.bleState.name,
        }));
      }
      return;
    }
    // We are genuinely replacing the disposed service, so the state the
    // service checks has to say so.
    store.dispatch(
        BleTransportStateChangedAction(TransportState.uninitialized));
    final initOk = await _initializeBle(promptForPermissions: false);
    var startCalled = false;
    if (initOk && _bleService != null) {
      startCalled = true;
      await _bleService!.start();
    }
    if (trace?.active ?? false) {
      unawaited(trace!.log({
        'type': 'link',
        't': DateTime.now().millisecondsSinceEpoch,
        'event': 'bounce',
        'darkSec': darkGap.inSeconds,
        'initOk': initOk,
        'startCalled': startCalled,
        'started': _started,
        'bleState': store.state.transports.bleState.name,
        'usable': bleUsable,
        if (_lastPermissionOutcome != null) 'perm': _lastPermissionOutcome,
      }));
    }
    if (!bleUsable) {
      debugPrint('[testbed] BLE bounce: transport NOT active after '
          '${darkGap.inSeconds}s (state ${store.state.transports.bleState.name})');
      _traceDrop('testbed', 'bounceNotActive', {
        'bleState': store.state.transports.bleState.name,
        'initOk': initOk,
      });
    }
  }

  /// DEBUG/TESTBED ONLY. Hold the BLE transport down or bring it back up,
  /// WITHOUT touching the user's settings toggle. The power-baseline plan
  /// scripts BLE-off vs BLE-active segments with it. Bringing it up respects
  /// the settings toggle (a user-disabled radio stays down); taking it down
  /// is the same teardown as the settings path, with no dark-gap wait — the
  /// off segment IS the dark.
  Future<void> setBleActiveForTestbed(bool on) async {
    if (!on) {
      if (_bleService == null) return;
      debugPrint('[testbed] BLE down (scripted segment)');
      await _bleService!.dispose();
      _bleService = null;
      store.dispatch(
          BleTransportStateChangedAction(TransportState.uninitialized));
      store.dispatch(ClearDiscoveredBlePeersAction());
      for (final peer in _peersState.peersList) {
        if (peer.hasBleConnection) {
          store.dispatch(PeerBleDisconnectedAction(peer.publicKey));
        }
      }
      return;
    }
    if (_bleService != null) return;
    if (!_isBleEnabledInSettings) return;
    debugPrint('[testbed] BLE up (scripted segment)');
    // Reached only with _bleService == null (checked above), i.e. after a
    // dispose — so the state genuinely is uninitialized and must read that
    // way for initialize() to run.
    store.dispatch(
        BleTransportStateChangedAction(TransportState.uninitialized));
    // A restart, not a first start — same reason as the bounce.
    await _initializeBle(promptForPermissions: false);
    if (_started && _bleAvailable) await _bleService!.start();
  }

  /// DEBUG/TESTBED ONLY. The dial grid's step setting: cap the transport's
  /// in-flight central dials at [maxParallel] (null = the production cap)
  /// and stamp [popN] onto the establishments that follow.
  ///
  /// Held HERE, not only on the service, because a dial-grid step bounces
  /// the BLE transport ([resetAllBleLinks]) and the bounce builds a fresh
  /// [BleTransportService]. Re-applying it in [_initializeBle] is what makes
  /// the setting survive that; a runner that set it on the live service
  /// alone would have its cap thrown away by the next step's bounce.
  void setDialParallelismForTestbed({int? maxParallel, int? popN}) {
    _dialProbeMaxParallel = maxParallel;
    _dialProbePopN = popN;
    _bleService?.setDialParallelism(maxParallel: maxParallel, popN: popN);
  }

  /// What the last permission evaluation returned, stamped into the bounce
  /// record so a failed restart names its own cause instead of needing a log.
  String? _lastPermissionOutcome;

  int? _dialProbeMaxParallel;
  int? _dialProbePopN;

  /// DEBUG/TESTBED ONLY. Central legs that reached GATT-usable since the last
  /// [resetBleEstablishmentCount] — the per-step establishment count the dial
  /// grid records.
  int get bleEstablishmentCount => _bleService?.establishmentCount ?? 0;

  void resetBleEstablishmentCount() => _bleService?.resetEstablishmentCount();

  /// The application block class carried by a `message` payload, from its
  /// first byte (`BlockType`). Testbed traffic uses a reserved byte so it
  /// never masquerades as a real block — see `testbedPayloadMarker`.
  static String? _dataKindOf(Uint8List payload) {
    if (payload.isEmpty) return null;
    if (payload[0] == testbedPayloadMarker) return 'testbed';
    return BlockType.isValidType(payload[0])
        ? BlockType.fromValue(payload[0]).name
        : 'other';
  }

  /// TESTBED/TRACE ONLY. Inner content type of packets we sealed, keyed by
  /// packetId, so the wire ledger can split our own `secure` tx bytes by
  /// what they actually carry (data by block class vs ack/receipt/sync).
  /// Bounded FIFO — only recent packets can still be in flight. Evicts the
  /// OLDEST entry at a time rather than clearing wholesale: a clear drops the
  /// classification for every packet still on the air, and under load
  /// (throughput runs seal thousands of packets a minute) that lost ~1.3 MB
  /// of a 3.8 MB run to the unclassified `secure` bucket.
  final Map<String, String> _sealedContentById = {};
  static const int _sealedContentCap = 8192;

  void _noteSealedContent(String packetId, ContentType type,
      {String? dataKind}) {
    if (!(trace?.active ?? false)) return;
    while (_sealedContentById.length >= _sealedContentCap) {
      _sealedContentById.remove(_sealedContentById.keys.first);
    }
    _sealedContentById[packetId] = switch (type) {
      ContentType.message => dataKind == null ? 'data' : 'data:$dataKind',
      ContentType.ack => 'ack',
      ContentType.readReceipt => 'receipt',
      ContentType.signaling => 'signaling',
      ContentType.syncFilter => 'sync',
    };
  }

  /// Sealed packets currently in the DTN memory buffer (our own un-ACK'd
  /// messages plus packets relayed for others).
  int get dtnBufferedCount => _messageRouter.dtnBufferedCount;

  /// Occupancy of every message-path buffer, for the recorder's periodic
  /// `buf` record. Synchronous in-memory reads only — this runs every 10s
  /// inside the measurement window and must not itself become a load.
  Map<String, dynamic> bufferSnapshot() {
    return {
      'dtnPackets': _messageRouter.dtnBufferedCount,
      'dtnRecipients': _messageRouter.dtnBufferedRecipients,
      'dtnBytes': _messageRouter.dtnBufferedBytes,
      'ackIndex': _dtnPacketIds.length,
      'sessions': _noiseSessions.sessionCount,
      'reassembly': _fragmentHandler.reassemblyCount,
      'reassemblyBytes': _fragmentHandler.reassemblyBytes,
      'sealedContentIds': _sealedContentById.length,
      'outgoingTracked': store.state.messages.outgoingMessages.length,
    };
  }

  /// Drain sub-10s tails at experiment stop (recorder preStopFlush): the
  /// wire ledger's last delta would otherwise be lost with the run's end.
  Future<void> flushTraceTails() async {
    _bleService?.drainWireLedgerNow();
  }

  /// Send a read receipt to the original sender of a message.
  /// Call this when the user has read/viewed a message.
  /// Returns true if the read receipt was sent successfully.
  Future<bool> sendReadReceipt({
    required String messageId,
    required Uint8List senderPubkey,
  }) async {
    // We must already share a Noise session with the sender — we decrypted
    // their message to display it, which is what makes it "read". The receipt
    // is sealed to that session; there is no wire signature.
    if (!_noiseSessions.hasSession(senderPubkey)) {
      debugPrint('No Noise session with sender; cannot send read receipt');
      _traceDrop('receiptTx', 'noSession', {'messageId': messageId});
      return false;
    }

    final packet = _protocolHandler.createReadReceiptPacket(
      messageId: messageId,
      recipientPubkey: senderPubkey,
    );

    // BLE: flood into the mesh, exactly like a delivery ACK. Do NOT target a
    // Redux-tracked device id (`_connectedBleDeviceIdForPeer` can be null or
    // stale across a MAC rotation or a half-tracked dual-role pair, which
    // silently dropped read receipts even on a live direct link). Broadcasting
    // to the actual live BLE connections reaches the original sender whether
    // it is a direct neighbour or several hops away — the same guarantee
    // messages and ACKs already have.
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null) {
      final sealed = await _noiseSessions.encryptPacket(
        packet,
        remotePubkey: senderPubkey,
      );
      _noteSealedContent(sealed.packetId, ContentType.readReceipt);
      _traceMessage('receiptTx', messageId, {
        'packetId': sealed.packetId,
        'peer': _pubkeyToHex(senderPubkey),
        'transport': 'ble',
      });
      // Same as ACKs: the router writes the sealed receipt directly when the
      // sender is a connected neighbour, and buffers it otherwise (age-expiry
      // only — nothing ACKs a receipt).
      await _messageRouter.dispatchOutbound(senderPubkey, sealed);
      return true;
    }

    // Fall back to UDP (direct point-to-point) if we have an address.
    if (_isUdpEnabledInSettings && _udpAvailable && _udpService != null) {
      final peer = _peersState.getPeerByPubkey(senderPubkey);
      final udpCandidates = _udpCandidatesForPeer(peer);
      if (peer != null && udpCandidates.isNotEmpty) {
        if (await _sendPacketViaUdp(
          pubkeyHex: peer.pubkeyHex,
          udpAddress: peer.udpAddress ?? udpCandidates.first,
          packet: packet,
          recipientPubkey: senderPubkey,
        )) {
          return true;
        }
      }
    }

    debugPrint('No transport available to send read receipt');
    _traceDrop('receiptTx', 'noTransport', {'messageId': messageId});
    return false;
  }

  /// Broadcast a message to all peers on all enabled transports.
  Future<void> broadcast(Uint8List payload) async {
    // Broadcast as individually encrypted unicast packets, one Noise session
    // per peer per transport medium.
    if (_isBleEnabledInSettings && _bleAvailable && _bleService != null) {
      try {
        for (final peerId in _bleService!.connectedPeerIds) {
          final pubkey = _bleService!.getPubkeyForPeerId(peerId);
          if (pubkey == null) continue;
          if (_fragmentHandler.needsFragmentation(payload)) {
            if (!_noiseSessions.hasSession(pubkey)) continue;
            for (final sealed in await _sealFragments(
              payload: payload,
              recipientPubkey: pubkey,
              messageId: _uuid.v4(),
            )) {
              await _floodViaBle(sealed.serialize());
              await Future.delayed(FragmentHandler.fragmentDelay);
            }
          } else {
            // Same gate as the fragmenting branch above: no session, no
            // packet. Relying on the sealer to return null let a packet be
            // built for a peer we had never handshaked with.
            if (!_noiseSessions.hasSession(pubkey)) continue;
            final packet = _protocolHandler.createMessagePacket(
              payload: payload,
              recipientPubkey: pubkey,
              messageId: _uuid.v4(),
            );
            final bytes = await _sealedPacketBytesForTransport(
              packet: packet,
              transport: PeerTransport.bleDirect,
              recipientPubkey: pubkey,
              peerId: peerId,
            );
            if (bytes != null) {
              await _bleService!.sendToPeer(peerId, bytes);
            }
          }
        }
      } catch (e) {
        debugPrint('BLE broadcast failed: $e');
      }
    }

    if (_isUdpEnabledInSettings && _udpAvailable && _udpService != null) {
      try {
        for (final peer in _peersState.peersList) {
          if (_udpService!.getPeerIdForPubkey(peer.publicKey) == null) {
            continue;
          }
          // No session, no packet.
          if (!_noiseSessions.hasSession(peer.publicKey)) continue;
          final packet = _protocolHandler.createMessagePacket(
            payload: payload,
            recipientPubkey: peer.publicKey,
            messageId: _uuid.v4(),
          );
          final bytes = await _sealedPacketBytesForTransport(
            packet: packet,
            transport: PeerTransport.udp,
            recipientPubkey: peer.publicKey,
            peerId: peer.pubkeyHex,
          );
          if (bytes != null) {
            await _udpService!.sendToPeer(peer.pubkeyHex, bytes);
          }
        }
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

    // Clear the failure flag while an attempt is in flight so the UI hides
    // the warning during retry.
    store.dispatch(PublicAddressDiscoveryFailedAction(false));

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
        _resetAutoUdpBackoff();
        // Spec onConnectivityStatus: fires on every public address change.
        // Startup case is `previousAddress == null`, gain case same.
        onConnectivityStatusChanged?.call(previousAddress, publicAddr);
      }
    } else {
      debugPrint(
        'Could not discover a public UDP address. '
        'No UDP address will be advertised.',
      );
      if (previousAddress != null) {
        // Spec onConnectivityStatus: address became unavailable.
        onConnectivityStatusChanged?.call(previousAddress, null);
      }
    }

    // Always update the display IP (even if no full address/port available).
    final bestIp = _publicAddressDiscovery.bestPublicIp;
    if (bestIp != null) {
      store.dispatch(PublicIpUpdatedAction(bestIp.address));
    }

    // If we still have neither a full public address nor any reflected/
    // discovered IP, flag discovery as failed so the UI can warn the user.
    final transports = store.state.transports;
    if (transports.publicAddress == null && transports.publicIp == null) {
      store.dispatch(PublicAddressDiscoveryFailedAction(true));
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

  static String _pubkeyToHex(Uint8List pubkey) =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  bool _isAcceptedFriendPubkey(Uint8List pubkey) {
    final hex = _pubkeyToHex(pubkey);
    final peer = _peersState.getPeerByPubkeyHex(hex);
    if (peer?.isFriend == true) return true;
    return store.state.friendships.isFriend(hex);
  }

  /// Whether [pubkey] is currently authorized by an invite we issued — an
  /// invitee we accepted a redemption from, whose authorizing invite has not
  /// yet expired. Such a peer completes first contact even under a closed
  /// cold-call posture, but only for the invite's lifetime.
  bool _isInvitedContact(Uint8List pubkey) {
    final hex = _pubkeyToHex(pubkey);
    final expiry = _invitedContacts[hex];
    if (expiry == null) return false;
    if (DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiry) {
      _invitedContacts.remove(hex);
      return false;
    }
    return true;
  }

  /// Fired when a Noise XX session for [transport] with [pubkey] completes
  /// authentication. Consolidated reachability — and therefore
  /// [onPeerConnected] — is gated on this: a transport counts toward
  /// `isReachable` only once its session is authenticated (spec
  /// `docs/GLP_Networking_API/sections/ip.tex` §IP Connection, "established and
  /// authenticated"). The session is also the gate for every path that moves
  /// buffered packets to this peer: pending messages become sealable, what we
  /// hold for them is conveyed,
  /// and the sync-on-connect vector exchange runs — never before the session.
  /// Peers whose next end-to-end ACK marks the link "usable" for the
  /// evaluation trace (armed on every session establishment).
  final Set<String> _awaitingFirstAck = {};

  void _onNoiseSessionEstablished(PeerTransport transport, Uint8List pubkey) {
    if (trace?.active ?? false) {
      final hex = _pubkeyToHex(pubkey);
      _awaitingFirstAck.add(hex);
      // The BLE leg this peer is attached to at establishment time, central
      // (the leg we dialed) preferred. The dial-probe analysis joins a
      // burst's targets to their session stamps by (pathId, stage, t), and
      // `peer` alone cannot carry that join when the same peer forms legs
      // across reps — the pathId is the per-dial identity.
      final peer = _peersState.getPeerByPubkey(pubkey);
      final blePath = transport == PeerTransport.udp
          ? null
          : (peer?.bleCentralDeviceId ?? peer?.blePeripheralDeviceId);
      unawaited(trace!.log({
        'type': 'link',
        't': DateTime.now().millisecondsSinceEpoch,
        'event': 'session',
        'peer': hex,
        if (blePath != null) 'path': blePath,
        'transport': transport == PeerTransport.udp ? 'udp' : 'ble',
      }));
    }
    // The transport-independent fact: we now hold a session with this peer and
    // can seal to them. It outlives the link below and never goes false, which
    // is what lets the UI enable composing for a peer that has since walked out
    // of range — the store-carry-forward case.
    store.dispatch(PeerNoiseSessionEstablishedAction(pubkey));

    switch (transport) {
      case PeerTransport.udp:
        store.dispatch(
          PeerUdpConnectionChangedAction(
            pubkeyHex: _pubkeyToHex(pubkey),
            connected: true,
          ),
        );
        break;
      case PeerTransport.bleDirect:
        store.dispatch(PeerBleAuthenticatedAction(pubkey));
        break;
    }

    // Buffered packets move ONLY through the sync exchange: advertise a
    // compact filter of what we have SEEN and let the peer answer with what
    // that filter lacks. Never a blind push of held packets: the sender has
    // no way to know what the peer already holds, so pushing re-sends packets
    // that were already delivered on every reconnection. The filter costs a
    // few hundred bytes whatever the buffer size.
    //
    // Both transports ask; they differ in what they may be answered with. Over
    // BLE the peer answers as a mesh relay, with anything it holds. Over UDX it
    // answers only with packets addressed to us — enough to close the gap where
    // a friend reachable solely over the Internet never received a buffered
    // message, without turning a continuous link into a buffer firehose.
    switch (transport) {
      case PeerTransport.bleDirect:
        final bleDeviceId =
            _connectedBleDeviceIdForPeer(_peersState.getPeerByPubkey(pubkey));
        if (bleDeviceId != null) _sendSyncFilter(bleDeviceId);
      case PeerTransport.udp:
        _sendSyncFilterUdx(pubkey);
    }

    // Cold-bootstrap invitee: if this session is with an inviter whose invite
    // we're redeeming, we've now punched through to them — present the invite
    // so they burn the nonce and authorize us.
    final blob = _pendingInviteRedemptions.remove(_pubkeyToHex(pubkey));
    if (blob != null) {
      debugPrint(
        '[invite] Connected to inviter ${_pubkeyToHex(pubkey).substring(0, 8)}'
        ' — sending INTRODUCE to complete redemption',
      );
      unawaited(_signalingService.sendIntroduce(pubkey, blob));
    }
  }

  Future<void> _startNoiseHandshakeForPeer({
    required PeerTransport transport,
    required PeerState peer,
    String? peerId,
  }) async {
    if (transport == PeerTransport.bleDirect) {
      peerId ??= _connectedBleDeviceIdForPeer(peer);
      if (peerId == null) return;
    } else if (transport == PeerTransport.udp) {
      if (_udpService?.getPeerIdForPubkey(peer.publicKey) == null) return;
      peerId ??= peer.pubkeyHex;
    } else {
      return;
    }

    await _ensureNoiseSession(
      transport: transport,
      recipientPubkey: peer.publicKey,
      peerId: peerId,
    );
  }

  Future<bool> _ensureNoiseSession({
    required PeerTransport transport,
    required Uint8List recipientPubkey,
    String? peerId,
  }) async {
    if (_noiseSessions.hasSession(recipientPubkey)) return true;

    final payload = await _noiseSessions.startHandshake(recipientPubkey);
    if (payload != null) {
      final sent = await _sendNoiseHandshakePacket(
        transport: transport,
        recipientPubkey: recipientPubkey,
        peerId: peerId,
        payload: payload,
      );
      if (!sent) {
        _noiseSessions.reset(recipientPubkey);
        return false;
      }
    }

    return _noiseSessions.waitForSession(recipientPubkey);
  }

  Future<bool> _sendNoiseHandshakePacket({
    required PeerTransport transport,
    required Uint8List recipientPubkey,
    required Uint8List payload,
    String? peerId,
  }) async {
    if (transport == PeerTransport.bleDirect) {
      final id = peerId ?? _bleService?.getPeerIdForPubkey(recipientPubkey);
      if (id == null) {
        // Untraced until now, and it is the denominator: without it a run
        // reports handshake TIMEOUTS without reporting how many handshakes
        // were never even put on the air, so no failure rate can be formed.
        _traceDrop('handshake', 'noPath',
            {'peer': _pubkeyToHex(recipientPubkey)});
        return false;
      }
      final service = _bleService;
      if (service == null) {
        _traceDrop('handshake', 'noTransport',
            {'peer': _pubkeyToHex(recipientPubkey)});
        return false;
      }
      // Fragment the handshake message to this leg's discovered MTU (each
      // fragment its own neighbour-local packet with a distinct packetId).
      final packets = _neighbourPacketBytes(
        payload: payload,
        type: PacketType.noiseHandshake,
        budget: service.usableFragmentBudgetFor(id),
        recipientPubkey: recipientPubkey,
      );
      var sent = true;
      for (final bytes in packets) {
        final ok = await service.sendToPeer(id, bytes);
        sent = sent && ok;
      }
      return sent;
    }

    if (transport == PeerTransport.udp) {
      final id = peerId ?? _pubkeyToHex(recipientPubkey);
      final service = _udpService;
      if (service == null) return false;
      final bytes = _wholeNeighbourPacket(
        payload: payload,
        type: PacketType.noiseHandshake,
        recipientPubkey: recipientPubkey,
      );
      return service.sendToPeer(id, bytes);
    }

    return false;
  }

  /// Resolve the peer identity for an inbound handshake from the transport path.
  /// The envelope is sender-anonymous, so for a neighbor-local handshake we map
  /// the inbound path id back to the peer's pubkey (learned from their verified
  /// self-signed ANNOUNCE). Returns null if the path isn't yet associated with a
  /// pubkey (the peer retries after ANNOUNCE propagates).
  Uint8List? _remotePubkeyForHandshake(PeerTransport transport, String? peerId) {
    if (peerId == null) return null;
    switch (transport) {
      case PeerTransport.bleDirect:
        return _bleService?.getPubkeyForPeerId(peerId);
      case PeerTransport.udp:
        return _udpService?.getPubkeyForPeerId(peerId);
    }
  }

  Future<Uint8List?> _sealedPacketBytesForTransport({
    required GrassrootsPacket packet,
    required PeerTransport transport,
    required Uint8List recipientPubkey,
    String? peerId,
  }) async {
    var outgoing = packet;
    if (packet.type == PacketType.secure) {
      final ready = await _ensureNoiseSession(
        transport: transport,
        recipientPubkey: recipientPubkey,
        peerId: peerId,
      );
      if (!ready) return null;
      outgoing = await _noiseSessions.encryptPacket(
        packet,
        remotePubkey: recipientPubkey,
      );
    }
    return outgoing.serialize();
  }

  HolePunchService? _holePunchServiceFor(InternetAddress address) =>
      _holePunchServices[address.type];

  Set<String> _candidateAddresses({bool includeLinkLocal = false}) =>
      normalizeAddressStrings([
        ..._publicAddressCandidates,
        if (_publicAddress != null) _publicAddress,
        if (includeLinkLocal && _linkLocalAddress != null) _linkLocalAddress,
      ]);

  Set<String> _connectionLocalCandidates() {
    final udpService = _udpService;
    if (udpService == null) return const {};

    return normalizeAddressStrings(
      _candidateAddresses(includeLinkLocal: true).where((address) {
        final parsed = parseAddressString(address);
        return parsed != null &&
            udpService.activeAddressTypes.contains(parsed.ip.type);
      }),
    );
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

  AddressCandidatePair? _selectUdpCandidatePair(
    Set<String> remoteCandidates, {
    required String context,
    String? peerLabel,
  }) {
    final localCandidates = _connectionLocalCandidates();
    final pair = _connectionService.selectBestPairFromAddresses(
      localAddresses: localCandidates,
      remoteAddresses: remoteCandidates,
    );
    if (pair == null) {
      final label = peerLabel != null ? ' for $peerLabel' : '';
      debugPrint(
        '[$context] No compatible UDP candidate pair$label: '
        'local=$localCandidates, '
        'remote=$remoteCandidates',
      );
      return null;
    }
    return pair;
  }

  GrassrootsPacket _createSignalingPacket(
    Uint8List recipientPubkey,
    Uint8List signalingPayload,
  ) {
    final frame = SecureFrame(
      contentType: ContentType.signaling,
      messageId: _uuid.v4(),
      chunk: signalingPayload,
    );
    return GrassrootsPacket(
      type: PacketType.secure,
      recipientPubkey: recipientPubkey,
      payload: frame.encode(),
    );
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

    final packet = _createSignalingPacket(recipientPubkey, signalingPayload);
    final bytes = await _sealedPacketBytesForTransport(
      packet: packet,
      transport: PeerTransport.bleDirect,
      recipientPubkey: recipientPubkey,
      peerId: deviceId,
    );
    if (bytes == null) return false;
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

    final announce = _wholeNeighbourPacket(
      payload: await _createSignedAnnouncePayload(address: udpAddress),
      type: PacketType.announce,
    );
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

    final connected = await _ensureUdpConnection(
      pubkeyHex,
      udpAddress,
      allowBleAssistedFallback: allowBleAssistedFallback,
      performPreConnectPunch: performPreConnectPunch,
    );
    if (!connected) return false;

    debugPrint('[udp-send] Connected, sending data to $peerShort');
    return _udpService!.sendToPeer(pubkeyHex, data);
  }

  Future<bool> _sendPacketViaUdp({
    required String pubkeyHex,
    required String udpAddress,
    required GrassrootsPacket packet,
    required Uint8List recipientPubkey,
    bool allowBleAssistedFallback = true,
    bool performPreConnectPunch = true,
  }) async {
    if (_udpService == null) return false;

    final connected =
        _udpService!.getPeerIdForPubkey(recipientPubkey) != null ||
            await _ensureUdpConnection(
              pubkeyHex,
              udpAddress,
              allowBleAssistedFallback: allowBleAssistedFallback,
              performPreConnectPunch: performPreConnectPunch,
            );
    if (!connected) return false;

    final bytes = await _sealedPacketBytesForTransport(
      packet: packet,
      transport: PeerTransport.udp,
      recipientPubkey: recipientPubkey,
      peerId: pubkeyHex,
    );
    if (bytes == null) return false;

    return _udpService!.sendToPeer(pubkeyHex, bytes);
  }

  Future<bool> _ensureUdpConnection(
    String pubkeyHex,
    String udpAddress, {
    bool allowBleAssistedFallback = true,
    bool performPreConnectPunch = true,
  }) async {
    if (_udpService == null) return false;
    if (_udpService!.getPeerIdForPubkey(_hexToBytes(pubkeyHex)) != null) {
      return true;
    }
    final peerShort = pubkeyHex.substring(0, 8);

    // Not connected — check if we should initiate or wait.
    // Only one side should call connectToPeer to avoid UDX simultaneous-open
    // (two independent socket pairs where data flows in only one direction).
    final myPubkeyHex = identity.publicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final iAmInitiator = myPubkeyHex.compareTo(pubkeyHex) < 0;
    final peer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);

    // After coordinated hole-punching, both sides punched a specific target.
    // Keep the UDX connect on that target instead of re-selecting a different
    // advertised candidate that did not just get its NAT mapping opened.
    final remoteCandidates = performPreConnectPunch
        ? _udpCandidatesForPeer(
            peer,
            fallbackAddress: udpAddress,
          )
        : normalizeAddressStrings([udpAddress]);
    final pair = _selectUdpCandidatePair(
      remoteCandidates,
      context: 'udp-send',
      peerLabel: peerShort,
    );
    if (pair == null) {
      return false;
    }
    final addr = pair.remote;
    final selectedAddress = addr.toAddressString();

    if (!iAmInitiator) {
      // We're not the initiator — the other side should connect to us.
      // Wait briefly for their incoming connection to arrive.
      debugPrint(
        '[udp-send] Not initiator for $peerShort, waiting for incoming connection...',
      );
      for (var i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (_udpService!.getPeerIdForPubkey(_hexToBytes(pubkeyHex)) != null) {
          debugPrint(
            '[udp-send] Incoming connection arrived for $peerShort',
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
      return inFlight;
    }

    late final Future<bool> udxConnectFuture;
    udxConnectFuture = () async {
      // Hole-punch to open NAT mappings before UDX connection attempt.
      // Skip for peers with publicly routable addresses — punching is wasted
      // when no NAT mapping is needed. If the direct attempt fails, the
      // caller's fallback path will retry with a punch via signaling.
      if (performPreConnectPunch &&
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

    if (connected) return true;

    debugPrint(
      '[udp-send] UDX connect failed to $peerShort at $selectedAddress',
    );

    if (allowBleAssistedFallback &&
        peer != null &&
        peer.isFriend &&
        _hasLiveBlePath(peer)) {
      debugPrint(
        '[udp-send] Trying direct BLE-assisted hole-punch to $peerShort...',
      );
      return _attemptDirectPunchWithPeer(peer, pair);
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
        final announce = _wholeNeighbourPacket(
          payload:
              await _createSignedAnnouncePayload(address: this.udpAddress),
          type: PacketType.announce,
        );

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
              final pair = _selectUdpCandidatePair(
                _udpCandidatesForPeer(
                  peer,
                  fallbackAddress: normalizedAddress,
                ),
                context: 'auto-udp-direct-punch',
                peerLabel: peer.displayName,
              );
              if (pair != null) {
                debugPrint(
                  '[auto-udp] Direct connect to '
                  '${pubkeyHex.substring(0, 8)} failed, trying direct BLE-assisted hole-punch...',
                );
                if (await _attemptDirectPunchWithPeer(peer, pair)) {
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
    AddressCandidatePair candidatePair,
  ) async {
    final peerHex = peer.pubkeyHex;
    final peerName = peer.displayName;
    final myAddr = candidatePair.local;
    final targetAddr = candidatePair.remote;

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

    if (_holePunchCompleters.containsKey(peerHex)) {
      debugPrint(
        '[direct-punch] Reusing in-flight hole-punch attempt for $peerName',
      );
    } else {
      _beginHolePunchAttempt(peerHex);
    }

    debugPrint(
      '[direct-punch] Asking $peerName to punch toward '
      '${myAddr.toAddressString()} '
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
    final targetAddress = AddressInfo(targetIp, port);
    if (_udpService == null ||
        _connectionService.selectBestPairFromAddresses(
              localAddresses: _connectionLocalCandidates(),
              remoteAddresses: [targetAddress.toAddressString()],
            ) ==
            null) {
      debugPrint(
        '[hole-punch] Unsupported address family in punch initiate: '
        '$ip:$port. No local advertised candidate can use '
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

    _holePunchTargets[peerHex] = targetAddress;

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

  /// Try to reach a peer through friends-of-friends mediators.
  ///
  /// Reconnected common friends receive explicit mediation requests;
  /// well-connected mutual friends receive RECONNECT fan-out. We then wait
  /// for the coordinated punch to complete.
  ///
  /// Returns true if a UDP path to the peer was established.
  Future<bool> _discoverPeerViaFriends(PeerState peer) async {
    final pubkeyBytes = peer.publicKey;
    final pubkeyHex = peer.pubkeyHex;
    final name = peer.displayName;
    final mediators = store.state.peers.mediatorsForFriend(pubkeyHex);
    final directMediatorCount =
        mediators.where((mediator) => !mediator.isWellConnected).length;
    final trustedFriendCount = store.state.peers.wellConnectedFriends
        .where(
          (friend) =>
              store.state.peers.friendsOfFriends[friend.pubkeyHex]?.contains(
                pubkeyHex,
              ) ==
              true,
        )
        .length;
    final facilitatorCount = directMediatorCount + trustedFriendCount;

    if (facilitatorCount == 0) {
      debugPrint('[discover] No signaling facilitators available');
      return false;
    }

    _beginHolePunchAttempt(pubkeyHex);

    var directMediatorSent = 0;
    for (final mediator in mediators) {
      if (mediator.isWellConnected) continue;
      final ok = await _signalingService.requestFriendMediation(
        mediatorPubkey: mediator.publicKey,
        targetPubkey: pubkeyBytes,
        initiatorPubkey: identity.publicKey,
      );
      if (ok) directMediatorSent++;
    }

    final sent = await _signalingService.fanOutReconnect(
      pubkeyBytes,
      initiatorPubkey: identity.publicKey,
    );
    if (sent == 0 && directMediatorSent == 0) {
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
      '[discover] Mediation requested for $name '
      '(${directMediatorSent + sent} facilitator(s)); '
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

  /// Periodically try to discover unreachable friends via friends-of-friends
  /// mediators.
  ///
  /// On each announce tick, find friends that we know about but can't currently
  /// reach via any transport. Common reconnected friends are asked to mediate
  /// directly.
  ///
  /// Throttled: each peer is attempted at most once per [_discoveryRetryInterval].
  void _discoverUnreachableFriends() {
    // debugPrint("Discovering unreachable friends");
    if (!_udpAvailable) {
      // debugPrint("No UDP");
      return; // Need UDP to establish the connection
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

      final mediators =
          store.state.peers.mediatorsForFriend(friend.pubkeyHex).toList();
      final directMediatorCount =
          mediators.where((mediator) => !mediator.isWellConnected).length;
      final wellConnectedCount = store.state.peers.wellConnectedFriends
          .where(
            (wc) =>
                store.state.peers.friendsOfFriends[wc.pubkeyHex]?.contains(
                  friend.pubkeyHex,
                ) ==
                true,
          )
          .length;
      if (directMediatorCount == 0 && wellConnectedCount == 0) {
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
        '${directMediatorCount + wellConnectedCount} '
        'facilitator(s)...',
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
    _messageRouter.onMessageReceived =
        (messageId, senderPubkey, payload, arrivalTransport) {
      // Authoritative arrival transport from the receive path (not inferred
      // from the peer's preferred/active transport).
      final transport = arrivalTransport == PeerTransport.udp
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
      onReceive?.call(senderPubkey, payload);
    };

    // ACK received (UDP delivery confirmation)
    // The store sheds packets without an ACK (expiry, eviction); the index
    // has to hear about it or it fills with dead entries.
    _messageRouter.onBufferedPacketDropped = _forgetBufferedPacket;

    _messageRouter.onAckReceived = (messageId) {
      debugPrint('ACK received for message $messageId');
      // Duplicate-ACK guard for the TRACE (the reducer already refuses the
      // status downgrade): an ACK sits in its originator's buffer until age
      // expiry and re-arrives via sync exchanges, and a second 'delivered'
      // record with a later t would silently skew every latency join. One
      // delivered record per message; later copies are dup records.
      final prior = store.state.messages.outgoingMessages[messageId]?.status;
      final alreadyDelivered = prior == MessageStatus.delivered ||
          prior == MessageStatus.read;
      if (alreadyDelivered) {
        _traceMessage('dupAck', messageId);
        _dropFromDtnBufferFor(messageId); // idempotent
        return;
      }
      if (trace?.active ?? false) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final outgoing = store.state.messages.outgoingMessages[messageId];
        final sentAt = outgoing?.sentAt;
        unawaited(trace!.log({
          'type': 'message',
          't': now,
          'dir': 'delivered',
          'messageId': messageId,
          'deliveredAt': now,
          // NOT the wire RTT. `outgoing.sentAt` is when the message was
          // CREATED, so this spans enqueue -> seal -> wait for the session and
          // the settled link -> flood -> ACK. The wire RTT is deliveredAt
          // minus the `sent` record's own `sentAt` (stamped when the sealed
          // packet is handed to the transport); the analyzer reports both, and
          // the gap between them is the send path's own cost.
          if (sentAt != null)
            'appLatencyMs': now - sentAt.millisecondsSinceEpoch,
          'deliverySuccess': true,
        }));
        // First end-to-end ACK since the session came up: the link is
        // "usable" (the third stage of the control-plane evaluation).
        final peerHex = outgoing?.recipientPubkeyHex;
        if (peerHex != null && _awaitingFirstAck.remove(peerHex)) {
          unawaited(trace!.log({
            'type': 'link',
            't': now,
            'event': 'usable',
            'peer': peerHex,
            'messageId': messageId,
          }));
        }
      }
      store.dispatch(MessageDeliveredAction(messageId: messageId));
      _bulkFlowDriver?.onAck(messageId);
      onTestbedAck?.call(messageId);
      _dropFromDtnBufferFor(messageId);
    };

    // Read receipt received
    _messageRouter.onReadReceiptReceived = (messageId) {
      debugPrint('Read receipt received for message $messageId');
      final sentAt =
          store.state.messages.outgoingMessages[messageId]?.sentAt;
      _traceMessage('read', messageId, {
        if (sentAt != null)
          'readLatencyMs': DateTime.now().millisecondsSinceEpoch -
              sentAt.millisecondsSinceEpoch,
      });
      store.dispatch(MessageReadAction(messageId: messageId));
      // A read receipt implies delivery — drop from the buffer even if the
      // ACK was lost.
      _dropFromDtnBufferFor(messageId);
    };

    // Map incoming UDP connections from any verified packet's senderPubkey:
    // any verified packet identifies the sender via its header, so a stream
    // does not have to open with an ANNOUNCE.
    _messageRouter.onUdpPeerIdentified = (senderPubkey, udpPeerId) {
      final pubkeyHex =
          senderPubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      _udpService?.mapIncomingConnectionToPubkey(udpPeerId, pubkeyHex);
    };

    _messageRouter.onNoiseHandshakeReceived =
        (packet, transport, {String? peerId}) async {
      // The handshake is neighbor-local and the envelope is sender-anonymous, so
      // resolve the dialing peer's identity from the inbound path (BLE: the
      // path→pubkey association from their verified ANNOUNCE; UDP: the mapped
      // connection). Without it we cannot bind/authenticate the session.
      final remotePubkey = _remotePubkeyForHandshake(transport, peerId);
      if (remotePubkey == null) {
        debugPrint('[noise] Dropping handshake: cannot resolve peer identity');
        _traceDrop('handshake', 'unmappedPath', {
          'transport': transport == PeerTransport.udp ? 'udp' : 'ble',
          if (packet.packetId.isNotEmpty) 'packetId': packet.packetId,
        });
        return;
      }
      try {
        final result = await _noiseSessions.handleHandshakePacket(
          packet,
          remotePubkey: remotePubkey,
        );
        final response = result.responsePayload;
        if (response != null) {
          await _sendNoiseHandshakePacket(
            transport: transport,
            recipientPubkey: remotePubkey,
            peerId: peerId,
            payload: response,
          );
        }
        if (result.sessionEstablished) {
          _onNoiseSessionEstablished(transport, remotePubkey);
        }
      } catch (e) {
        debugPrint('[noise] Dropping handshake packet: $e');
      }
    };

    // Trial-decrypt a sealed, sender-anonymous packet against active sessions.
    _messageRouter.trialDecrypt = (packet) => _noiseSessions.trialDecrypt(packet);

    // Direct-write capability for the router's outbound path
    // ([MessageRouter.dispatchOutbound]): resolve a live BLE leg to the
    // recipient and write the sealed packet on it now. False when the
    // recipient is not a connected neighbour (or BLE is down) — the buffered
    // copy then travels by sync exchange alone.
    _messageRouter.directSend = (recipientPubkey, sealed) async {
      final ble = _bleService;
      if (ble == null || !_bleAvailable) return false;
      final deviceId = _connectedBleDeviceIdForPeer(
          _peersState.getPeerByPubkey(recipientPubkey));
      if (deviceId == null) return false;
      return ble.sendToPeer(deviceId, sealed.serialize());
    };

    // Sync-on-connect: directed (never flooded) send of an offer/request/
    // conveyed buffered packet to one specific neighbor.
    _messageRouter.onSyncSend = (packet, link) {
      // The conveyance goes back over the link the filter arrived on. The
      // router already decided WHAT may go (everything held over BLE, only
      // the peer's own packets over UDX); this only picks the wire.
      final send = link.isUdx
          ? _udpService?.sendToPeer
          : _bleService?.sendToPeer;
      if (send == null) {
        // The router already logged custody 'convey' for this packet — say
        // the conveyance never reached a transport.
        _traceDrop('sync', 'conveyNoTransport',
            {'packetId': packet.packetId, 'via': link.transport.name});
        return;
      }
      unawaited(send(link.handle, packet.serialize()).then((ok) {
        if (!ok) {
          _traceDrop('sync', 'conveySendFailed',
              {'packetId': packet.packetId, 'via': link.transport.name});
        }
      }));
    };

    // Peer ANNOUNCE processed
    _messageRouter.onPeerAnnounced = (data, transport,
        {bool isNew = false, String? udpPeerId, String? bleDeviceId}) {
      final pubkeyHex =
          data.publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (trace?.active ?? false) {
        // "Discovered" stage of the control-plane evaluation: a verified
        // ANNOUNCE from this peer arrived (fires once per announce cycle, so
        // the record stream doubles as a presence-visibility sample).
        final rssi = store.state.peers.getPeerByPubkeyHex(pubkeyHex)?.rssi;
        unawaited(trace!.log({
          'type': 'link',
          't': DateTime.now().millisecondsSinceEpoch,
          'event': 'discovered',
          'peer': pubkeyHex,
          // The path this ANNOUNCE arrived on. This is the binding that makes
          // a link attributable: `connected` fires before identity is known,
          // and `drop` only exists for links that ended, so without this the
          // longest-lived links are exactly the ones a topology
          // reconstruction cannot place.
          if (bleDeviceId != null) 'path': bleDeviceId,
          'transport': transport == PeerTransport.udp ? 'udp' : 'ble',
          'isNew': isNew,
          if (rssi != null) 'rssi': rssi,
        }));
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

      final announcedPeer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);
      if (announcedPeer != null) {
        unawaited(_startNoiseHandshakeForPeer(
          transport: transport,
          peer: announcedPeer,
          peerId: udpPeerId,
        ));
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
            '[auto-udp] proactive UDP connect to $pubkeyHex who is actually ${senderPeer.nickname}',
          );
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

      // onPeerDiscovered is the identity-learned event: a peer's public key and
      // nickname arrive in the signed ANNOUNCE, which is sent in the clear and
      // precedes the Noise session. Because onPeerConnected is gated on an
      // authenticated Noise session (see processReachabilityTransitions),
      // discovery strictly precedes connection — so we surface it here, once per
      // identity, rather than coupling it to the reachability transition.
      if (_discoveredPubkeyHexes.add(pubkeyHex)) {
        onPeerDiscovered?.call(data.publicKey, data.nickname);
      }

      // onPeerConnected is driven by the reachability subscriber (it fires once
      // the peer is reachable = an authenticated Noise session exists). We still
      // fire onPeerUpdated on subsequent ANNOUNCEs for callers that want every
      // update regardless of reachability transitions.
      final peerState = store.state.peers.getPeerByPubkey(data.publicKey);
      if (peerState != null && !isNew) {
        onPeerUpdated?.call(peerState);
      }

      // Eager pairing: every accepted announce leads straight to a Noise
      // session (buffered-packet flow is session-gated). ANY sessionless side
      // initiates — not just the lower pubkey. The lower-initiates rule was
      // a workaround for handshake glare corrupting state; glare is now
      // resolved cleanly (msg1 lower-pubkey tie-break + validate-then-commit
      // message reads), and one-sided initiation left an asymmetry: after a
      // one-sided session loss (peer restart, testbed reset) the survivor
      // holds a session and never re-initiates, so a higher-pubkey loser
      // could only recover via a data send racing the fresh link. The 10s
      // periodic announce is the natural retry if a handshake is lost.
      if (!_noiseSessions.hasSession(data.publicKey)) {
        final peer = _peersState.getPeerByPubkey(data.publicKey);
        unawaited(_ensureNoiseSession(
          transport: transport,
          recipientPubkey: data.publicKey,
          peerId: transport == PeerTransport.udp
              ? udpPeerId
              : _connectedBleDeviceIdForPeer(peer),
        ));
      } else {
        // A peer we ALREADY hold a session with has just announced — it went
        // away and came back. Ask it what we are missing, so anything it holds
        // for us comes back on this encounter.
        //
        // Hanging the sync off session establishment alone would miss this:
        // sessions outlive the link that formed them, so a neighbour whose
        // radio cycles returns with its session intact, no establishment
        // fires, and the buffer it left behind is never offered. That is
        // precisely the case store-carry-forward exists to serve.
        //
        // ANNOUNCE is the "recipient appears" signal. It repeats every ~10 s;
        // the send carries its own per-(transport, peer) debounce, and one
        // filter is a few hundred bytes whatever the buffer size, so the
        // steady-state cost of re-advertising is bounded and small.
        //
        // UDX needs no new trigger of its own: ANNOUNCE already goes out over
        // UDP on the same `_announceTimer`, so the Internet path re-asks on the
        // same cycle the radio one does.
        switch (transport) {
          case PeerTransport.bleDirect:
            final peer = _peersState.getPeerByPubkey(data.publicKey);
            final bleDeviceId = _connectedBleDeviceIdForPeer(peer);
            if (bleDeviceId != null) _sendSyncFilter(bleDeviceId);
          case PeerTransport.udp:
            _sendSyncFilterUdx(data.publicKey);
        }
      }
    };

    // ACK request: the router recovered the original sender by trial-decrypt and
    // asks us to confirm delivery. The ACK is a recipient-addressed, sealed
    // packet flooded back through the mesh (BLE) — the sender may be several
    // hops away — or sent directly over UDP.
    _messageRouter.onAckRequested = (senderPubkey, messageId, transport) async {
      // A session with the sender exists (we just decrypted their message).
      if (!_noiseSessions.hasSession(senderPubkey)) {
        // Race: session torn down between decrypt and ACK. The message was
        // delivered and traced 'recv', but no ACK ever goes out — the sender
        // keeps the packets buffered, so this side has to say so.
        _traceDrop('ackTx', 'noSession', {'messageId': messageId});
        return;
      }
      final ackPacket = _protocolHandler.createAckPacket(
        messageId: messageId,
        recipientPubkey: senderPubkey,
      );
      final sealed = await _noiseSessions.encryptPacket(
        ackPacket,
        remotePubkey: senderPubkey,
      );
      _noteSealedContent(sealed.packetId, ContentType.ack);
      final bytes = sealed.serialize();
      // The recipient-side half of the ACK join (ackRx is the sender's):
      // recv.t -> ackTx.t is the recipient's processing contribution to the
      // sender-observed RTT, on one clock.
      _traceMessage('ackTx', messageId, {
        'packetId': sealed.packetId,
        'peer': _pubkeyToHex(senderPubkey),
        'transport': transport == PeerTransport.udp ? 'udp' : 'ble',
      });

      if (transport == PeerTransport.udp) {
        final ok =
            await _udpService?.sendToPeer(_pubkeyToHex(senderPubkey), bytes) ??
                false;
        if (!ok) {
          // A failed UDP ACK is NOT buffered (the DTN buffer is BLE-only):
          // it is simply gone, and the sender redelivers until a BLE
          // encounter ACKs it, so the failure is recorded here.
          _traceDrop('ackTx', 'udpSendFailed', {
            'messageId': messageId,
            'packetId': sealed.packetId,
          });
        }
      } else {
        // The ACK is recipient-addressed traffic like everything else — the
        // router writes it directly when the original sender is a connected
        // neighbour (a direct-delivered message is confirmed in milliseconds,
        // not at the next sync round), and buffers it otherwise (nothing ACKs
        // an ACK, so a buffered entry leaves only by age expiry).
        await _messageRouter.dispatchOutbound(senderPubkey, sealed);
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

    // An invitee presented a signed invite (INTRODUCE). We own verification
    // and the local-role decision.
    _signalingService.onIntroduceReceived =
        (senderPubkey, inviteBlob, observedIp, observedPort) {
      _handleIntroduceReceived(
        senderPubkey,
        inviteBlob,
        observedIp,
        observedPort,
      );
    };
  }

  /// Set up SignalingService callbacks
  void _setupSignalingCallbacks() {
    // SignalingService sends signaling payloads through us (wrapped in GrassrootsPacket)
    _signalingService.sendSignaling =
        (recipientPubkey, signalingPayload) async {
      final packet = _createSignalingPacket(
        recipientPubkey,
        signalingPayload,
      );

      final pubkeyHex = _pubkeyToHex(recipientPubkey);

      // Try BLE first
      if (_bleService != null && _bleAvailable) {
        final peerId = _bleService!.getPeerIdForPubkey(recipientPubkey);
        if (peerId != null) {
          final bytes = await _sealedPacketBytesForTransport(
            packet: packet,
            transport: PeerTransport.bleDirect,
            recipientPubkey: recipientPubkey,
            peerId: peerId,
          );
          if (bytes != null && await _bleService!.sendToPeer(peerId, bytes)) {
            return true;
          }
        }
      }

      // Fall back to UDP
      if (_udpService != null && _udpAvailable) {
        if (_udpService!.getPeerIdForPubkey(recipientPubkey) != null) {
          final bytes = await _sealedPacketBytesForTransport(
            packet: packet,
            transport: PeerTransport.udp,
            recipientPubkey: recipientPubkey,
            peerId: pubkeyHex,
          );
          if (bytes != null &&
              await _udpService!.sendToPeer(pubkeyHex, bytes)) {
            return true;
          }
        }

        // Not connected via UDP yet — try connect-on-demand
        final peer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);
        final candidates = _udpCandidatesForPeer(peer);
        final udpAddr = peer?.udpAddress ??
            (candidates.isNotEmpty ? candidates.first : null);
        if (udpAddr != null && udpAddr.isNotEmpty) {
          return _sendPacketViaUdp(
            pubkeyHex: pubkeyHex,
            udpAddress: udpAddr,
            packet: packet,
            recipientPubkey: recipientPubkey,
          );
        }
      }

      return false;
    };
    _signalingService.sendDirectSignaling = _sendDirectSignalingOverLiveBle;

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
      final previous = _publicAddress;
      if (reflected == previous) return; // No change

      debugPrint(
        'Public address updated via reflection: $previous → $reflected',
      );
      _publicAddress = reflected;
      store.dispatch(PublicAddressUpdatedAction(reflected));
      _resetAutoUdpBackoff();
      // Spec onConnectivityStatus: reflection-driven address change.
      onConnectivityStatusChanged?.call(previous, reflected);
    };
  }

  /// Diff each peer's `isReachable` flag against the previous store tick and
  /// fire the consolidated `onPeerConnected` / `onPeerDisconnected` callbacks
  /// on transitions. Delegates to the testable top-level
  /// [processReachabilityTransitions] function so the diff logic is unit-
  /// testable without a full `GrassrootsNetwork` harness.
  void _processReachabilityTransitions(PeersState peersState) {
    processReachabilityTransitions(
      peersState: peersState,
      lastKnownReachability: _lastKnownReachability,
      onConnected: onPeerConnected,
      onDisconnected: onPeerDisconnected,
    );
  }

  /// Set up callbacks for BLE transport service
  void _setupBleServiceCallbacks() {
    if (_bleService == null) return;

    // Forward BLE packets to the MessageRouter for processing
    _bleService!.onBlePacketReceived =
        (packet, {String? bleDeviceId, int? rssi, BleRole? bleRole}) {
      _messageRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        bleDeviceId: bleDeviceId,
        bleRole: bleRole,
        rssi: rssi,
      );
    };

    _messageRouter.shouldAcceptBleAnnounce =
        (senderPubkey, {String? bleDeviceId, BleRole? bleRole}) {
      if (store.state.settings.coldCallTrustLevel == ColdCallTrustLevel.open) {
        return true;
      }
      // An invitee we issued an invite to may complete first contact even
      // while closed to cold calls.
      return _isAcceptedFriendPubkey(senderPubkey) ||
          _isInvitedContact(senderPubkey);
    };

    _messageRouter.onBleAnnounceRejected = (senderPubkey, bleDeviceId) {
      if (bleDeviceId == null) return;
      unawaited(_bleService?.disconnectDevice(bleDeviceId));
    };

    // A verified BLE ANNOUNCE identified the peer behind a path (the router
    // has already applied it to Redux). Let the transport act on the pair's
    // reverse leg — cancel a doomed dial (iOS) or open the central direction.
    _messageRouter.onBlePeerIdentified = (pathId, pubkey) {
      _bleService?.onPeerIdentified(pathId, pubkey);
    };

    // BLE-level disconnect cleans up the per-transport Noise session.
    // The consolidated application-level onPeerDisconnected is fired by
    // the reachability subscriber when the *last* live transport drops.
    _bleService!.onPeerDisconnected = (peer) {
      debugPrint('BLE Peer disconnected: ${peer.displayName}');
      // Session kept: the end-to-end Noise session is path-independent, so a
      // peer that drifts out of direct BLE range can still be messaged across
      // the mesh (and re-reached directly later) without re-handshaking.
    };

    // Per spec (`docs/GLP_Networking_API/sections/ble.tex` §BLE Discovery):
    // "Upon successful BLE connection, an ANNOUNCE packet is exchanged."
    // Fire an immediate directed ANNOUNCE to the newly connected path so the
    // peer learns our identity within milliseconds rather than waiting up to
    // a full periodic-broadcast cycle. The periodic broadcast still runs as
    // a keep-alive and as a refresh after BLE-address rotation; receivers
    // treat repeated ANNOUNCEs from the same pubkey as idempotent.
    _bleService!.connectionStream.listen((event) {
      if (event.connected) {
        unawaited(_sendAnnounceToDevice(event.peerId));
        // The sync exchange happens later, once the pairing's Noise session is
        // established (see [_onNoiseSessionEstablished]) — never on the raw
        // link.
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
        _traceDrop('udpRx', 'deserialize', {'bytes': data.length});
      }
    };

    // Listen to connection events — update Redux state and log
    _udpService!.connectionStream.listen((event) {
      // UDP connection events get the same trace coverage as BLE link
      // stages, so no transport is dark to analysis.
      if (trace?.active ?? false) {
        unawaited(trace!.log({
          'type': 'link',
          't': DateTime.now().millisecondsSinceEpoch,
          'event': event.connected ? 'connected' : 'drop',
          'transport': 'udp',
          'peer': event.peerId,
        }));
      }
      if (event.connected) {
        debugPrint('UDP peer connected: ${event.peerId}');
        store.dispatch(PeerUdpSeenAction(_hexToBytes(event.peerId)));
        // A friend just came back online with us. Tell them our friend list
        // so they can pick us as a mediator when they need to reconnect to a
        // common friend. We do NOT proactively mediate here — mediation only
        // happens on an explicit RECONNECT the peer fans out to us.
        _sendFriendListToFriendIfEligible(event.peerId);

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
          // Connection succeeded with no prior hole-punch coordination.
          //
          // Incoming: a peer reached us at our public address without us
          // first opening a NAT mapping for them. Record that our current
          // address accepted unsolicited inbound.
          //
          // Outgoing: we reached the peer at their advertised address
          // without any punch coordination. Record that their address
          // accepted unsolicited inbound.
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
            // Only record inbound reachability if the peer reached us on the same
            // address they advertise publicly. This avoids treating LAN or
            // link-local paths as unsolicited public reachability.
            if (peer?.hasPublicUdpAddress == true && matchedAdvertisedAddress) {
              store.dispatch(UnsolicitedInboundObservedAction());
            } else {
              debugPrint(
                'Ignoring inbound reachability observation for ${event.peerId}: '
                'peer advertised=${peer?.udpAddress}, observed=$observedRemote',
              );
            }
          } else if (peer != null) {
            // Bind peer reachability observation to the exact advertised address
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
                  'Skipping direct-reach observation for ${event.peerId}: connected to '
                  '${remote?.ip.address ?? "unknown"}:${remote?.port ?? 0} '
                  'but advertised ${peer.udpAddress ?? "none"}',
                );
              }
            } else {
              debugPrint(
                'Ignoring peer direct-reach observation for ${event.peerId}: '
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
      }
      if (!event.connected) {
        // Disconnect is immediate — drop reachability now.
        store.dispatch(
          PeerUdpConnectionChangedAction(
            pubkeyHex: event.peerId,
            connected: false,
          ),
        );
      }
    });
  }

  // ===== Cold bootstrap via invite links =====
  //
  // See docs/architecture-overview.tex §Facilitators (cold bootstrap via
  // invite links). An inviter
  // issues a signed [Invite] naming well-connected, willing friends as
  // introducers. An invitee redeems it: it presents the invite (INTRODUCE)
  // to an introducer, which coordinates an invitee↔inviter hole-punch, then
  // presents it to the inviter, which accepts first contact and burns the
  // nonce.

  /// Well-connected friends eligible to introduce for us: they have a
  /// globally-routable address the invitee can reach AND they advertised
  /// willingness to facilitate (the signed ANNOUNCE flag). The inviter can't
  /// see a friend's local toggle, so willingness travels over the wire — only
  /// willing friends are offered as introducers.
  List<PeerState> get invitableIntroducers => [
        for (final friend in store.state.peers.wellConnectedFriends)
          if (friend.willingToFacilitate &&
              friend.allUdpAddressCandidates.any(isGloballyRoutableAddress))
            friend,
      ];

  /// The introducers to name in an invite, built from [invitableIntroducers].
  /// [only], when given, restricts to those friend pubkey hexes.
  List<InviteIntroducer> _availableIntroducers({Set<String>? only}) {
    final result = <InviteIntroducer>[];
    for (final friend in invitableIntroducers) {
      final hex = friend.pubkeyHex;
      if (only != null && !only.contains(hex)) continue;
      final addresses = friend.allUdpAddressCandidates
          .where(isGloballyRoutableAddress)
          .toList();
      result.add(
          InviteIntroducer(pubkey: friend.publicKey, addresses: addresses));
    }
    return result;
  }

  /// Whether any friend can currently act as an invite introducer.
  bool get canCreateInvite => invitableIntroducers.isNotEmpty;

  /// Create and sign an invite link for cold bootstrap.
  ///
  /// [introducerPubkeyHexes], when given, restricts the named introducers to
  /// that subset of our well-connected friends; otherwise every eligible
  /// friend is named for redundancy. Returns the `grassroots://invite?d=...`
  /// link, or null if we have no eligible introducer.
  String? createInvite({
    Set<String>? introducerPubkeyHexes,
    Duration ttl = const Duration(hours: 24),
    int maxUses = 1,
  }) {
    final introducers = _availableIntroducers(only: introducerPubkeyHexes);
    if (introducers.isEmpty) {
      debugPrint('[invite] Cannot create invite — no eligible introducers');
      return null;
    }
    final nonce = Uint8List.fromList(
      List<int>.generate(Invite.nonceLength, (_) => _secureRandom.nextInt(256)),
    );
    final expiry = DateTime.now().add(ttl).millisecondsSinceEpoch ~/ 1000;
    final invite = InviteSigner(sodium).sign(
      inviter: identity.publicKey,
      privateKey: identity.privateKey,
      introducers: introducers,
      expiry: expiry,
      nonce: nonce,
      maxUses: maxUses < 1 ? 1 : maxUses,
    );
    debugPrint(
      '[invite] Issued invite (nonce ${invite.nonceHex.substring(0, 8)}, '
      '${introducers.length} introducer(s), maxUses $maxUses)',
    );
    return invite.toLink();
  }

  final Random _secureRandom = Random.secure();

  /// Redeem an invite link: reach the inviter via one of its introducers.
  ///
  /// Parses + verifies the link, then for each named introducer connects over
  /// UDP, announces (so the introducer can bind our identity), and sends an
  /// INTRODUCE. The introducer coordinates the punch; the existing punch
  /// machinery connects us to the inviter, and [_onNoiseSessionEstablished]
  /// then sends the inviter its own INTRODUCE. Returns an
  /// [InviteRedeemResult] describing the outcome.
  Future<InviteRedeemResult> redeemInvite(String link) async {
    if (_udpService == null || !_udpAvailable) {
      return InviteRedeemResult.failure('Internet transport is off');
    }
    final Invite invite;
    try {
      invite = Invite.parseLink(link, sodium);
    } on FormatException catch (e) {
      return InviteRedeemResult.failure('Not a valid invite: ${e.message}');
    }
    if (invite.isExpiredAt(DateTime.now())) {
      return InviteRedeemResult.failure('This invite has expired');
    }
    if (listEquals(invite.inviter, identity.publicKey)) {
      return InviteRedeemResult.failure('This is your own invite');
    }
    if (_isAcceptedFriendPubkey(invite.inviter)) {
      return InviteRedeemResult.failure('You are already friends');
    }

    final inviterHex = invite.inviterHex;
    final blob = invite.encode();
    // Remember the redemption so the post-punch session-established hook can
    // present the invite to the inviter.
    _pendingInviteRedemptions[inviterHex] = blob;

    // Transiently trust the introducers' signaling: we are not their friend,
    // so without this their PUNCH_INITIATE / PUNCH_READY (which drive our leg
    // of the punch) would be dropped by the friend gate. Scoped to this
    // redemption.
    final introHexes = invite.introducers
        .map((i) => i.pubkeyHex)
        .toList(growable: false);
    for (final hex in introHexes) {
      _signalingService.trustTransientSignalingPeer(hex);
    }
    try {
      var reached = 0;
      for (final intro in invite.introducers) {
        for (final address in intro.addresses) {
          final ok =
              await _sendIntroduceToIntroducer(intro.pubkey, address, blob);
          if (ok) {
            reached++;
            break; // first reachable address for this introducer is enough
          }
        }
      }

      if (reached == 0) {
        _pendingInviteRedemptions.remove(inviterHex);
        return InviteRedeemResult.failure('Could not reach any introducer');
      }

      // The punch + connect is asynchronous; wait for a session to the inviter.
      _beginHolePunchAttempt(inviterHex, dispatchStarted: false);
      final completer = _holePunchCompleters[inviterHex];
      final connected =
          await (completer?.future ?? Future.value(false)).timeout(
        const Duration(seconds: 20),
        onTimeout: () => false,
      );
      if (!connected && !_isReachableHex(inviterHex)) {
        _pendingInviteRedemptions.remove(inviterHex);
        return InviteRedeemResult.failure(
          'Reached an introducer, but the hole-punch to your contact timed out',
        );
      }
      return InviteRedeemResult.success(invite.inviter);
    } finally {
      for (final hex in introHexes) {
        _signalingService.untrustTransientSignalingPeer(hex);
      }
    }
  }

  bool _isReachableHex(String pubkeyHex) {
    final peer = _peersState.getPeerByPubkeyHex(pubkeyHex);
    return peer?.isReachable ?? false;
  }

  /// SharedPreferences key for the burned-invite-nonce ledger. Versioned and
  /// identity-scoped so regenerating the keypair starts fresh.
  String get _inviteNonceLedgerKey =>
      'grassroots_invite_nonces_v1_${identity.publicKey.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  /// Load the burned-nonce ledger so a restart does not un-burn a
  /// still-unexpired invite. Prunes entries whose invite has expired.
  Future<void> _loadInviteNonceLedger() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_inviteNonceLedgerKey);
      if (raw == null) return;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _issuedNonceUses.clear();
      decoded.forEach((nonceHex, v) {
        final m = v as Map<String, dynamic>;
        final expiry = m['e'] as int;
        if (expiry <= now) return; // expired — drop
        _issuedNonceUses[nonceHex] =
            _BurnedNonce(uses: m['u'] as int, expiry: expiry);
      });
    } catch (e) {
      debugPrint('[invite] Failed to load nonce ledger: $e');
    }
  }

  /// Persist the burned-nonce ledger, pruning expired entries.
  Future<void> _saveInviteNonceLedger() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _issuedNonceUses.removeWhere((_, n) => n.expiry <= now);
      final map = {
        for (final e in _issuedNonceUses.entries)
          e.key: {'u': e.value.uses, 'e': e.value.expiry},
      };
      await prefs.setString(_inviteNonceLedgerKey, jsonEncode(map));
    } catch (e) {
      debugPrint('[invite] Failed to save nonce ledger: $e');
    }
  }

  /// Connect to an introducer over UDP and present an invite (INTRODUCE).
  Future<bool> _sendIntroduceToIntroducer(
    Uint8List introducerPubkey,
    String address,
    Uint8List inviteBlob,
  ) async {
    final introHex = _pubkeyToHex(introducerPubkey);
    // Announce first so the introducer learns our identity and can bind the
    // Noise handshake that carries the INTRODUCE.
    final announce = _wholeNeighbourPacket(
      payload: await _createSignedAnnouncePayload(address: udpAddress),
      type: PacketType.announce,
    );
    final announced = await _sendViaUdp(introHex, address, announce);
    if (!announced) {
      debugPrint(
        '[invite] Could not reach introducer ${introHex.substring(0, 8)} '
        'at $address',
      );
      return false;
    }
    final sent = await _signalingService.sendIntroduce(
      introducerPubkey,
      inviteBlob,
    );
    debugPrint(
      '[invite] INTRODUCE to introducer ${introHex.substring(0, 8)}: '
      '${sent ? "sent" : "failed"}',
    );
    return sent;
  }

  /// Handle an inbound INTRODUCE. Decide our role from the verified invite:
  /// inviter (we signed it) → accept + burn nonce; introducer (we're named)
  /// → coordinate the punch. Silently drops otherwise.
  void _handleIntroduceReceived(
    Uint8List senderPubkey,
    Uint8List inviteBlob,
    String? observedIp,
    int? observedPort,
  ) {
    final Invite invite;
    try {
      invite = Invite.decode(inviteBlob, sodium);
    } on FormatException catch (e) {
      debugPrint('[invite] Dropping INTRODUCE with bad invite: ${e.message}');
      return;
    }
    if (invite.isExpiredAt(DateTime.now())) {
      debugPrint('[invite] Dropping INTRODUCE — invite expired');
      return;
    }

    // Inviter role: we signed this invite.
    if (listEquals(invite.inviter, identity.publicKey)) {
      final entry = _issuedNonceUses[invite.nonceHex];
      final used = entry?.uses ?? 0;
      if (used >= invite.maxUses) {
        debugPrint('[invite] Refusing redemption — nonce exhausted');
        return;
      }
      _issuedNonceUses[invite.nonceHex] =
          _BurnedNonce(uses: used + 1, expiry: invite.expiry);
      _invitedContacts[_pubkeyToHex(senderPubkey)] = invite.expiry;
      unawaited(_saveInviteNonceLedger());
      debugPrint(
        '[invite] Accepted invite redemption from '
        '${_pubkeyToHex(senderPubkey).substring(0, 8)} '
        '(nonce use ${used + 1}/${invite.maxUses})',
      );
      return;
    }

    // Introducer role: we must be named, the inviter must be our friend, and
    // both introduce toggles must be open.
    final named = invite.introducers
        .any((i) => listEquals(i.pubkey, identity.publicKey));
    if (!named) {
      debugPrint('[invite] Dropping INTRODUCE — we are not a named introducer');
      return;
    }
    if (!store.state.settings.willingToFacilitateInvites) {
      debugPrint('[invite] Declining introduction — not willing to facilitate');
      return;
    }
    if (!_isAcceptedFriendPubkey(invite.inviter)) {
      debugPrint(
        '[invite] Declining introduction — inviter '
        '${invite.inviterHex.substring(0, 8)} is not our friend',
      );
      return;
    }
    if (observedIp == null || observedPort == null) {
      debugPrint('[invite] Cannot introduce — no observed invitee address');
      return;
    }
    // Enforce the inviter's maxUses locally to bound abuse.
    final used = _introducedNonceUses[invite.nonceHex] ?? 0;
    if (used >= invite.maxUses) {
      debugPrint('[invite] Declining introduction — nonce budget exhausted');
      return;
    }
    // LRU-evict the oldest entry at capacity rather than flushing all budgets
    // (a wholesale clear would momentarily un-bound every in-flight invite).
    if (_introducedNonceUses.length >= _maxTrackedNonces) {
      _introducedNonceUses.remove(_introducedNonceUses.keys.first);
    }
    _introducedNonceUses[invite.nonceHex] = used + 1;

    debugPrint(
      '[invite] Introducing ${_pubkeyToHex(senderPubkey).substring(0, 8)} '
      '→ inviter ${invite.inviterHex.substring(0, 8)}',
    );
    _signalingService.coordinateIntroduction(
      inviteePubkey: senderPubkey,
      inviteeIp: observedIp,
      inviteePort: observedPort,
      inviterPubkey: invite.inviter,
    );
  }

  /// Send our current accepted friend set to a friend after a live connection
  /// establishes so they can maintain their friends-of-friends map.
  void _sendFriendListToFriendIfEligible(String pubkeyHex) {
    final peer = _peersState.getPeerByPubkeyHex(pubkeyHex);
    if (peer == null || !peer.isFriend) return;

    final friendPubkeys = _ownFriendListEntries();
    debugPrint(
      '[fof] Sending ${friendPubkeys.length} accepted friend(s) to '
      '${peer.displayName}',
    );
    unawaited(_signalingService.sendFriendList(peer.publicKey, friendPubkeys));
  }

  /// Broadcast our current accepted friend set to every live friend.
  void _broadcastFriendListToFriends({required String reason}) {
    final friendPubkeys = _ownFriendListEntries();
    for (final friend in _peersState.friends) {
      if (!friend.isReachable) continue;
      debugPrint(
        '[fof] Broadcasting friend list to ${friend.displayName} ($reason)',
      );
      unawaited(
        _signalingService.sendFriendList(friend.publicKey, friendPubkeys),
      );
    }
  }

  List<Uint8List> _ownFriendListEntries() {
    final friends = _peersState.friendPubkeyHexes.toList()..sort();
    return [for (final hex in friends) _hexToBytes(hex)];
  }

  /// Called by the host app when it returns to the foreground.
  ///
  /// Three steps, in order:
  ///   1. Probe the raw UDP sockets and rebind the transport if the OS
  ///      poisoned them while we were backgrounded (Android in particular
  ///      EPERMs background sends and leaves the socket FD in a permanently
  ///      broken state — fixable only by close + bind).
  ///   2. Drain any messages queued while backgrounded toward peers that
  ///      are still live. (Friend rediscovery runs on the announce tick.)
  Future<void> onAppResumed() async {
    debugPrint('[lifecycle] App resumed — probing sockets');
    if (_udpService != null && _udpAvailable) {
      final rebound = await _udpService!.probeAndRebindIfDead();
      if (rebound) {
        debugPrint('[lifecycle] UDP transport rebound after foreground probe');
      }
    }
  }

  /// Clean up resources
  Future<void> dispose() async {
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _storeSubscription?.cancel();
    _storeSubscription = null;
    _announceTimer?.cancel();
    _scanTimer?.cancel();
    _bulkFlowDriver?.stop();

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
    _pendingInviteRedemptions.clear();
    _introducedNonceUses.clear();
    _issuedNonceUses.clear();
    _invitedContacts.clear();
    _dtnPacketIds.clear();
    _dtnMessageOfPacket.clear();

    _messageRouter.dispose();
    _signalingService.dispose();
    _noiseSessions.dispose();
    _fragmentHandler.dispose();

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
    if (config.scanDuration == null) {
      // BLE start() already requested a continuous scan. Do not replace it
      // with the finite default scan window from BleTransportService.scan().
      return;
    }
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
  /// device ID, rather than an exclude list keyed on BLE IDs that
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

    final announce = _wholeNeighbourPacket(
      payload: await _createSignedAnnouncePayload(
        address: udpAddress,
        addressCandidates: _candidateAddresses(),
      ),
      type: PacketType.announce,
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
  /// Also fired immediately when a BLE path becomes connected (per spec
  /// §BLE Discovery: ANNOUNCE is exchanged upon successful BLE connection).
  /// Receivers treat repeated ANNOUNCEs from the same pubkey as idempotent,
  /// so racing with the periodic broadcast is harmless.
  /// Last time we sent sync offers to a given neighbor, keyed by PEER
  /// IDENTITY. Keying by the pathId's address made the pair's two legs share
  /// one debounce only while both rode a single ACL; the 19% of field-day
  /// pairs that held two separate ACLs have two addresses for one peer and
  /// were offered the same buffer twice per round. An offer is a statement
  /// about a peer, so identity is its natural key. Entries are pruned by age.
  final Map<String, DateTime> _lastSyncOfferAt = {};
  /// Collapses the two connect events a dual-role pair fires (one per leg)
  /// into a single offer round — they arrive milliseconds apart.
  ///
  /// Deliberately SHORTER than the 10 s announce interval, so a peer that has
  /// reappeared gets an offer on every announce cycle rather than once a
  /// minute. At 60 s a returning neighbour could sit for most of a minute
  /// with the carrier holding packets for it and saying nothing.
  static const Duration _syncOfferDebounce = Duration(seconds: 5);

  /// Advertise our DTN buffer to a neighbour as a GCS filter (sync-on-connect
  /// and on every announce cycle). Dual-role pairs fire two connect events
  /// (one per leg); the per-peer debounce collapses them into one send.
  void _sendSyncFilter(String deviceId) {
    if (_bleService == null || !_bleAvailable) return;
    final pubkey = _bleService!.getPubkeyForPeerId(deviceId);
    if (pubkey == null) return; // path not yet identified; retry next connect
    _sendSyncFilterOver(SyncLink.ble(pubkey, deviceId));
  }

  /// The UDX counterpart of [_sendSyncFilter]. The peer answers it with packets
  /// addressed to US and nothing else, which is what closes the gap where a
  /// friend reachable only over the Internet never received a buffered message
  /// until a BLE encounter happened to occur.
  ///
  /// The peer id on a UDX connection IS the pubkey hex, so unlike the BLE side
  /// there is no path-to-identity lookup that can come back null.
  void _sendSyncFilterUdx(Uint8List pubkey) {
    if (_udpService == null) return;
    _sendSyncFilterOver(SyncLink.udx(pubkey, _pubkeyToHex(pubkey)));
  }

  /// Build and send one seen-filter over [link], debounced.
  ///
  /// The debounce key is (transport, peer), not peer: the two links ask
  /// different question sets — BLE can be answered with anything we hold, UDX
  /// only with our own packets — so a BLE round must not suppress the UDX one
  /// or the Internet path would go silent whenever a peer was also in radio
  /// range, which is exactly when both are worth asking.
  void _sendSyncFilterOver(SyncLink link) {
    final key = '${link.transport.name}:${_pubkeyToHex(link.peerPubkey)}';
    final now = DateTime.now();
    _lastSyncOfferAt.removeWhere(
        (_, at) => now.difference(at) > const Duration(minutes: 10));
    final last = _lastSyncOfferAt[key];
    if (last != null && now.difference(last) < _syncOfferDebounce) return;

    final payload = _messageRouter.buildSyncFilter(link.peerPubkey);
    if (payload == null) return; // nothing to advertise this round
    _lastSyncOfferAt[key] = now;
    debugPrint('[sync] Advertising a ${payload.length}-byte seen-filter to '
        '${link.handle} over ${link.transport.name} '
        '(${_messageRouter.dtnBufferedCount} carried)');
    unawaited(_sealAndSendSyncFrame(ContentType.syncFilter, payload, link));
  }

  /// Seal a sync control frame to the link's peer and send it back over the
  /// link. No session yet (a pairing still handshaking) simply skips the
  /// exchange — sync-on-connect retries on the next pairing. Returns whether
  /// the frame reached the link; the offer round is built from that answer.
  Future<bool> _sealAndSendSyncFrame(
      ContentType type, Uint8List payload, SyncLink link) async {
    if (!_noiseSessions.hasSession(link.peerPubkey)) return false;
    try {
      final packet = _protocolHandler.createSyncPacket(
        type: type,
        payload: payload,
        recipientPubkey: link.peerPubkey,
      );
      final sealed = await _noiseSessions.encryptPacket(
        packet,
        remotePubkey: link.peerPubkey,
      );
      _noteSealedContent(sealed.packetId, type);
      final send =
          link.isUdx ? _udpService?.sendToPeer : _bleService?.sendToPeer;
      if (send == null) return false;
      return await send(link.handle, sealed.serialize());
    } catch (e) {
      debugPrint('[sync] Failed to seal/send ${type.name}: $e');
      return false;
    }
  }

  Future<bool> _sendAnnounceToDevice(String deviceId) async {
    if (_bleService == null || !_bleAvailable) return false;

    // Check if this device ID already belongs to an authenticated friend.
    final pubkey = _bleService!.getPubkeyForPeerId(deviceId);
    final isFriend = pubkey != null && _isAcceptedFriendPubkey(pubkey);

    final friendHint = _bleService!.getFriendPubkeyHintForPeerId(deviceId);
    final allowsColdCall =
        store.state.settings.coldCallTrustLevel == ColdCallTrustLevel.open;
    if (!isFriend && !allowsColdCall && friendHint == null) {
      debugPrint(
        '[ble-announce] Suppressed ANNOUNCE to $deviceId '
        '(closed trust, unknown peer)',
      );
      return false;
    }

    // Authenticated friends get our address + link-local. Non-friends, and
    // derived-UUID friend hints that have not yet sent a signed ANNOUNCE, get
    // only identity. A spoofed derived UUID must not unlock friend metadata.
    final announcePayload = isFriend
        ? await _createSignedAnnouncePayload(
            address: udpAddress,
            linkLocalAddress: _linkLocalAddress,
          )
        : await _createSignedAnnouncePayload();

    // Fragment to THIS leg's discovered MTU: a friend ANNOUNCE (~301 B with
    // address candidates) overflows the common 247 MTU as a single write.
    // "Sent" means every fragment was accepted — a partial send leaves the
    // neighbour unable to reassemble.
    final packets = _neighbourPacketBytes(
      payload: announcePayload,
      type: PacketType.announce,
      budget: _bleService!.usableFragmentBudgetFor(deviceId),
    );
    var sent = true;
    for (final bytes in packets) {
      final ok = await _bleService!.sendToPeer(deviceId, bytes);
      sent = sent && ok;
    }
    if (sent) {
      if (isFriend) {
        _bleFriendAnnounceSent.add(deviceId);
      } else {
        _bleFriendAnnounceSent.remove(deviceId);
      }
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
  /// Build the self-signed ANNOUNCE PAYLOAD (not a serialized packet).
  ///
  /// Callers wrap it in one-or-more neighbour-local packets via the fragmenter:
  /// [_neighbourPacketBytes] over BLE (sized to the leg's discovered MTU) or
  /// [_wholeNeighbourPacket] over UDP (a stream, always one fragment). The
  /// fragment header is what lets a friend ANNOUNCE — ~301 bytes with address
  /// candidates — survive the common 247 ATT MTU instead of being truncated.
  Future<Uint8List> _createSignedAnnouncePayload({
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
    return _protocolHandler.createAnnouncePayload(
      address: normalizedAddress,
      linkLocalAddress: normalizedLinkLocal,
      addressCandidates: normalizedCandidates,
      willingToFacilitate: store.state.settings.willingToFacilitateInvites,
    );
  }

  /// Serialize [payload] as one-or-more neighbour-local packets of [type]
  /// (ttl 1), fragmented at [budget] so no single write overflows the leg's
  /// MTU. Each fragment rides its own packet (distinct packetId) with a
  /// cleartext [SecureFrame] as its payload; the neighbour reassembles by the
  /// frame's globally-unique messageId. [contentType] stays at its default —
  /// it is vestigial here, since the outer `packet.type` routes these and
  /// reassembly ignores it.
  List<Uint8List> _neighbourPacketBytes({
    required Uint8List payload,
    required PacketType type,
    required int budget,
    Uint8List? recipientPubkey,
  }) {
    final frames = _fragmentHandler.framesFor(
      payload: payload,
      messageId: _uuid.v4(),
      chunkBudget: budget,
    );
    return [
      for (final frame in frames)
        GrassrootsPacket(
          type: type,
          ttl: 1,
          recipientPubkey: recipientPubkey,
          payload: frame.encode(),
        ).serialize(),
    ];
  }

  /// A large budget that forces a single frame for stream transports (UDP),
  /// well above any ANNOUNCE or handshake payload.
  static const int _wholeFragmentBudget = 1 << 20;

  /// One neighbour-local packet carrying [payload] whole. Used for stream
  /// transports (UDP), which have no MTU; it still wraps the payload in a
  /// (single-fragment) cleartext frame so the receive path is uniform.
  Uint8List _wholeNeighbourPacket({
    required Uint8List payload,
    required PacketType type,
    Uint8List? recipientPubkey,
  }) {
    return _neighbourPacketBytes(
      payload: payload,
      type: type,
      budget: _wholeFragmentBudget,
      recipientPubkey: recipientPubkey,
    ).single;
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
      willingToFacilitate: store.state.settings.willingToFacilitateInvites,
    );

    // Try BLE first if available. Fragment to the leg's discovered MTU; "sent"
    // means every fragment was accepted so the neighbour can reassemble.
    if (_bleService != null && _bleAvailable) {
      final peerId = _bleService!.getPeerIdForPubkey(friendPubkey);
      if (peerId != null) {
        final packets = _neighbourPacketBytes(
          payload: payload,
          type: PacketType.announce,
          budget: _bleService!.usableFragmentBudgetFor(peerId),
          recipientPubkey: friendPubkey,
        );
        var bleSent = true;
        for (final bytes in packets) {
          final ok = await _bleService!.sendToPeer(peerId, bytes);
          bleSent = bleSent && ok;
        }
        sent = bleSent;
      }
    }

    // Also try UDP if available. A stream has no MTU: one whole fragment.
    if (_udpService != null && _udpAvailable) {
      final udpBytes = _wholeNeighbourPacket(
        payload: payload,
        type: PacketType.announce,
        recipientPubkey: friendPubkey,
      );
      final peerId = _udpService!.getPeerIdForPubkey(friendPubkey);
      if (peerId != null) {
        final udpSent = await _udpService!.sendToPeer(peerId, udpBytes);
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
            udpBytes,
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
    // TEN missed announces, not two. Two cycles meant one announce lost on a
    // busy air — or delayed by screen-off scan batching — put a peer one tick
    // from eviction, and the sweep then tore down state that was about to
    // refresh. At 10 cycles (~100 s at the default interval) only a peer that
    // is genuinely gone ages out; a friend's Noise session was never touched
    // by this sweep either way.
    final staleThreshold = config.announceInterval * 10;

    // Tear down quiet UDP sessions that have missed 10 announce cycles.
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
        if (trace?.active ?? false) {
          unawaited(trace!.log({
            'type': 'link',
            't': DateTime.now().millisecondsSinceEpoch,
            'event': 'drop',
            'transport': 'udp',
            'reason': 'stale',
            'peer': peer.pubkeyHex,
          }));
        }
        store.dispatch(PeerUdpDisconnectedAction(peer.publicKey));
        unawaited(_udpService!.disconnectFromPeer(pubkeyHex));
      }
    }

    // Sweep stale BLE attachments. The BLE plugin can fail to surface a
    // disconnect when the path drifts through `failed`/`subscribed` instead
    // of cleanly dropping from `ready`. Without this safety net the peer's
    // `bleCentralDeviceId` / `blePeripheralDeviceId` stay set indefinitely
    // and `nearbyBlePeers` keeps showing them. Friends and strangers are
    // treated identically — both should fall off "Connected Peers" once
    // they've been silent over BLE for ten announce cycles.
    final staleBlePeers = computeStaleBlePeerPubkeys(
      peers: _peersState.peersList,
      staleThreshold: staleThreshold,
    );
    for (final pubkeyHex in staleBlePeers) {
      final peer = _peersState.getPeerByPubkeyHex(pubkeyHex);
      if (peer == null) continue;
      debugPrint(
        '[ble-stale] No BLE traffic from ${peer.displayName} for '
        '${staleThreshold.inSeconds}s; synthesizing disconnect',
      );
      // This is the ONLY code path that voluntarily disconnects a live link,
      // and before a session exists ANNOUNCE is the only thing that refreshes
      // the clock it watches — so a pairing can be torn down mid-handshake
      // and the teardown was, until now, invisible outside debug output. It
      // is a measurement: it separates "the pairing was never attempted"
      // from "the attempt lost its 5s race".
      _traceDrop('bleStale', 'sweep', {
        'peer': pubkeyHex,
        'silentSec': staleThreshold.inSeconds,
        'hadSession': _noiseSessions.hasSession(peer.publicKey),
      });
      // Redux is a strict projection of transport facts — so when we
      // synthesize a disconnect, make it a fact: physically tear down any
      // plugin paths still attached to this peer. An ANNOUNCE-quiet link is
      // often still alive at the radio level; clearing only the Redux
      // attachment blinds the identity-keyed dial guards, and the recovery
      // dial then opens a doomed SECOND link to a device we are still
      // linked with (20s connecting-wedge on iOS, GATT-133 churn on
      // Android). Tearing the radio down first makes the recovery dial a
      // legitimate first link.
      final centralId = peer.bleCentralDeviceId;
      if (centralId != null) {
        unawaited(_bleService?.disconnectDevice(centralId, forget: true));
      }
      final peripheralId = peer.blePeripheralDeviceId;
      if (peripheralId != null) {
        unawaited(_bleService?.disconnectDevice(peripheralId, forget: true));
      }
      // role: null clears both central and peripheral attachments.
      store.dispatch(PeerBleDisconnectedAction(peer.publicKey));
    }

    // Dispatch action to remove stale peers via Redux
    store.dispatch(StaleDiscoveredBlePeersRemovedAction(staleThreshold));
    store.dispatch(StalePeersRemovedAction(staleThreshold));
  }

  // ===== BLE Fragmentation Helpers =====

  /// Send a large payload via BLE using fragmentation.
  /// Each fragment is individually encrypted and signed.
  /// Seal every fragment of [payload] to the recipient's session, returning
  /// the sealed packets. Requires an existing session. The caller floods them
  /// and (for tracked messages) puts them in the DTN memory buffer.
  Future<List<GrassrootsPacket>> _sealFragments({
    required Uint8List payload,
    required Uint8List recipientPubkey,
    required String messageId,
  }) async {
    final frames = _fragmentHandler.framesFor(
      payload: payload,
      messageId: messageId,
    );
    final sealed = <GrassrootsPacket>[];
    for (final frame in frames) {
      final packet = GrassrootsPacket(
        type: PacketType.secure,
        recipientPubkey: recipientPubkey,
        payload: frame.encode(),
      );
      final out = await _noiseSessions.encryptPacket(
        packet,
        remotePubkey: recipientPubkey,
      );
      _noteSealedContent(out.packetId, ContentType.message,
          dataKind: _dataKindOf(payload));
      sealed.add(out);
    }
    return sealed;
  }

  /// Flood a serialized packet into the BLE mesh (managed flooding). Returns the
  /// number of neighbors it was sent to. [excludeBlePeerId] skips the inbound
  /// path when relaying.
  Future<int> _floodViaBle(Uint8List bytes, {String? excludeBlePeerId}) async {
    final service = _bleService;
    if (service == null || !_bleAvailable) return 0;
    return service.broadcast(
      bytes,
      excludePeerIds: excludeBlePeerId == null ? null : {excludeBlePeerId},
    );
  }
}

/// Diff each peer's `isReachable` against the previous tick and fire the
/// consolidated reachability callbacks on transitions. Pure-ish: the only
/// side effects are calling [onConnected] / [onDisconnected] and mutating
/// [lastKnownReachability] in place.
///
/// Semantics:
///   - previous absent (treated as `false`) or `false` → current `true`:
///     fire [onConnected] with the current `PeerState`. (Discovery —
///     onPeerDiscovered — is surfaced separately at ANNOUNCE receipt, because a
///     peer's identity is known before its Noise session authenticates.)
///   - previous `true` → current `false`: fire [onDisconnected].
///   - reachable peer removed from [peersState.peersList] entirely
///     (e.g. PeerRemovedAction): fire [onDisconnected] with a minimal
///     synthetic `PeerState` carrying only the identity, since the original
///     state is gone.
///   - state unchanged or one-of-two transports flipping while the other
///     stays live: no fire.
@visibleForTesting
void processReachabilityTransitions({
  required PeersState peersState,
  required Map<String, bool> lastKnownReachability,
  required void Function(PeerState peer)? onConnected,
  required void Function(PeerState peer)? onDisconnected,
}) {
  final seenPubkeys = <String>{};

  for (final peer in peersState.peersList) {
    final pk = peer.pubkeyHex;
    seenPubkeys.add(pk);
    final previous = lastKnownReachability[pk] ?? false;
    final current = peer.isReachable;
    if (previous == current) continue;
    lastKnownReachability[pk] = current;
    if (current) {
      onConnected?.call(peer);
    } else {
      onDisconnected?.call(peer);
    }
  }

  // Removed-while-reachable: surface as a disconnect with a synthesized stub.
  final missing = lastKnownReachability.keys
      .where((pk) => !seenPubkeys.contains(pk) && lastKnownReachability[pk]!)
      .toList(growable: false);
  for (final pk in missing) {
    lastKnownReachability.remove(pk);
    final cb = onDisconnected;
    if (cb == null) continue;
    cb(PeerState(
      publicKey: Uint8List.fromList([
        for (var i = 0; i < pk.length; i += 2)
          int.parse(pk.substring(i, i + 2), radix: 16)
      ]),
      nickname: '',
      connectionState: PeerConnectionState.disconnected,
      transport: PeerTransport.udp,
    ));
  }
}
