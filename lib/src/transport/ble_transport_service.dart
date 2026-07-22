import 'dart:async';

import 'package:grassroots_bluetooth_layer/grassroots_bluetooth_layer.dart'
    as ble;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:redux/redux.dart';

import '../models/identity.dart';
import '../models/packet.dart';
import '../models/platform.dart';
import '../store/store.dart';
import 'transport_service.dart';

/// Default display info for BLE transport
const _defaultBleDisplayInfo = TransportDisplayInfo(
  icon: Icons.bluetooth,
  name: 'Bluetooth',
  description: 'Bluetooth Low Energy direct P2P transport',
  color: Colors.blue,
);

/// Grassroots characteristic UUID, fixed across all peers. The containing
/// GATT service UUID is derived from the advertiser's public key and the
/// current 15-minute slot (`docs/GLP_Networking_API/sections/ble.tex` §BLE
/// Discovery) — advertisement and GATT service carry the SAME rotating
/// derived UUID, deliberately: rotation severs a connected stranger's
/// continuity of observation each slot.
const String _grassrootsCharacteristicUuid =
    '0000ff01-0000-1000-8000-00805f9b34fb';

/// MTU we request from the peer on every central connect. ANNOUNCE alone is
/// ~200 bytes, far over the default ATT MTU of 23 (20-byte payload). 247 is
/// the largest most Android stacks negotiate; the actual value is whatever
/// the peer accepts and is reported back via the `BlePath.mtu` field.
const int _requestedAndroidMtu = 247;

/// BLE-based implementation of the transport service.
///
/// Wraps the `grassroots_bluetooth_layer` Flutter plugin which unifies central and peripheral
/// roles in one bondless layer. The plugin emits a single role-tagged path
/// stream; this service projects path lifecycle events into Redux actions and
/// forwards payloads to the message router.
///
/// ## Architecture
///
/// - **Peripheral mode**: advertises our derived Grassroots service UUID,
///   accepts incoming connections, exposes one notify+write characteristic.
/// - **Central mode**: scans for peers advertising the Grassroots service
///   prefix and connects to them.
/// - **Direct delivery only**. No relaying, no store-and-forward.
class BleTransportService extends TransportService {
  /// Local device name for advertising (informational; iOS ignores it,
  /// Android does not include it in the advertise packet either).
  final String? localName;

  /// Our identity
  final GrassrootsIdentity identity;

  /// Redux store
  final Store<AppState> store;

  /// Cold-start grace period a non-initiator waits for the deterministic
  /// initiator (the peer with the lower service UUID) to open the first leg
  /// before it dials anyway. Injectable so tests can exercise the fallback
  /// without a real delay.
  final Duration firstMoverFallback;

  /// Restart the continuous scan when no advertisement has reached us for
  /// this long while we are in a scanning role. The transport's discovery
  /// relies on a single long-running, OS-unfiltered scan (prefix matching is
  /// user-space), and Android can silently mute such a scan — observed on
  /// Pixel after a force-cancelled `connecting` wedge: the scan "runs" but
  /// delivers nothing, leaving the device discovery-blind (existing links
  /// keep working; reverse legs toward new peers never dial). With peers
  /// nearby advertising several times a second, 30s of total silence means a
  /// dead scanner, not an empty room — and if the room IS empty, a restart
  /// is harmless. Injectable for tests.
  final Duration scanSilenceRestart;

  /// The unified BLE plugin facade
  final ble.GrassrootsBluetooth _ble;

  // Subscriptions to plugin event streams
  StreamSubscription<ble.BleAdapterState>? _adapterSub;
  StreamSubscription<ble.BleAdvertisement>? _advertisementSub;
  StreamSubscription<ble.BlePath>? _pathSub;
  StreamSubscription<ble.BlePayload>? _payloadSub;
  StreamSubscription<String>? _logSub;

  /// Latest known plugin state per pathId (synchronous mirror of `paths()`).
  /// This is a strict cache of plugin facts, not consumer state.
  final Map<String, ble.BlePath> _paths = {};

  /// True while a `start()` call is in flight. Prevents re-entrant `start()`
  /// from `_onAdapterStateChanged` running concurrently with the original.
  bool _starting = false;

  /// When we last locally tore down a leg to an identity (reform, stale
  /// sweep), keyed by `pk:<pubkeyHex>` and `uuid:<serviceUuid>`. Resets the
  /// first-mover fallback clock ([_fallbackElapsed]): `discoveredAt` never
  /// refreshes, so without this every yield branch would be permanently
  /// escaped ~[firstMoverFallback] after first sighting, and a reform
  /// teardown would be followed by an instant wrong-order redial racing the
  /// iPhone's dial-on-sight. Entries are pruned on write; only the fallback
  /// window matters.
  final Map<String, DateTime> _lastLocalTeardownAt = {};

  /// Scan-liveness watchdog (see [scanSilenceRestart]). Armed whenever the
  /// continuous scan is started; cancelled on stop/dispose or when the role
  /// mode stops scanning.
  Timer? _scanWatchdog;
  DateTime _lastAdvertisementAt = DateTime.now();
  static const Duration _scanWatchdogInterval = Duration(seconds: 10);

  /// Full service-UUID candidates currently installed as *hardware* scan
  /// filters (empty = a plain prefix scan). Populated with the candidate
  /// UUIDs of peers we hold an inbound peripheral leg from but have no reverse
  /// (central) leg to yet — see [_reverseLegScanTargets]. A filterless Android
  /// scan is silently muted under load (advertising + several GATT-server
  /// connections), which strands such a pair peripheral-only because their
  /// advertising MAC is never discovered to dial back; a hardware-filtered
  /// scan for the exact identities we need is not muted the same way.
  Set<String> _scanTargetUuids = {};

  /// Rolls the advertised beacon each 15-minute BLE slot. The advertised
  /// service UUID's suffix rotates ([GrassrootsIdentity.deriveServiceUuidForSlot]),
  /// so we must re-advertise the new-slot beacon when the slot advances. Checked
  /// frequently but only acts when [GrassrootsIdentity.currentBleSlot] moves past
  /// [_advertisedSlot]. Re-advertising rebuilds the peripheral GATT service under
  /// the new UUID (requires plugin >= 0.3.0, which restarts advertising after the
  /// rebuild); live links drop and re-establish across the boundary.
  Timer? _slotTimer;
  int? _advertisedSlot;
  String? _advertiseLocalName;
  static const Duration _slotCheckInterval = Duration(seconds: 30);

  /// True after [stop] is called. Drops in-flight payloads and prevents
  /// adapter-on auto-restart.
  bool _stopped = false;

  /// Stream controllers for the public TransportService API.
  final _dataController = StreamController<TransportDataEvent>.broadcast();
  final _connectionController =
      StreamController<TransportConnectionEvent>.broadcast();

  // ===== Public callbacks =====

  /// Called when a BLE packet is deserialized and ready for routing.
  /// `rssi` is the per-packet signal strength reported by the BLE plugin
  /// for every received packet, regardless of role; nullable only because
  /// the typedef matches `MessageRouter.processPacket`'s shared signature.
  void Function(GrassrootsPacket packet,
      {String? bleDeviceId, int? rssi, BleRole? bleRole})? onBlePacketReceived;

  /// Called when a peer disconnects at the BLE level. The argument is the
  /// peer's current `PeerState` snapshot — this is BLE-transport-level only;
  /// `GrassrootsNetwork` decides whether overall reachability changed before
  /// firing its consolidated `onPeerDisconnected`.
  void Function(PeerState peer)? onPeerDisconnected;

  // ===== Convenience getters for Redux state =====

  PeersState get _peersState => store.state.peers;

  BleTransportService({
    required this.identity,
    required this.store,
    this.localName,
    this.firstMoverFallback = const Duration(seconds: 5),
    this.scanSilenceRestart = const Duration(seconds: 30),
    ble.GrassrootsBluetooth? grassrootsBluetooth,
  }) : _ble = grassrootsBluetooth ?? ble.GrassrootsBluetooth();

  // ===== TransportService implementation =====

  @override
  TransportType get type => TransportType.ble;

  @override
  TransportDisplayInfo get displayInfo => _defaultBleDisplayInfo;

  @override
  TransportState get state => store.state.transports.bleState;

  @override
  Stream<TransportDataEvent> get dataStream => _dataController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionStream =>
      _connectionController.stream;

  @override
  int get connectedCount => _readyPaths.length;

  @override
  bool get isActive => store.state.transports.bleState == TransportState.active;

  /// Whether scanning is currently active. The plugin doesn't expose this
  /// directly, so we treat "transport is active" as a proxy.
  bool get isScanning => isActive;

  /// All known peers from Redux store
  List<PeerState> get knownPeers => _peersState.peersList;

  /// Connected peers from Redux store
  List<PeerState> get connectedKnownPeers => _peersState.connectedPeers;

  /// All currently sendable BLE pathIds (across both roles).
  Set<String> get connectedPeerIds => _readyPaths.map((p) => p.pathId).toSet();

  /// All discovered BLE peers (before ANNOUNCE).
  List<DiscoveredPeerState> get discoveredPeers =>
      _peersState.discoveredBlePeersList;

  bool isPeerReachable(Uint8List pubkey) => _peersState.isPeerReachable(pubkey);

  PeerState? getPeer(Uint8List pubkey) => _peersState.getPeerByPubkey(pubkey);

  /// Whether the given pathId is currently sendable.
  bool isDeviceConnected(String peerId) {
    final path = _paths[peerId];
    return path != null && _isReady(path);
  }

  // ===== Lifecycle =====

  @override
  Future<bool> initialize() async {
    if (state != TransportState.uninitialized) {
      return state.isUsable;
    }
    _setState(TransportState.initializing);

    try {
      _adapterSub = _ble.adapterStateChanges.listen((s) {
        _onAdapterStateChanged(s);
      });
      _advertisementSub = _ble.advertisements.listen(_onAdvertisement);
      _pathSub = _ble.pathChanges.listen(_onPathChanged);
      _payloadSub = _ble.payloads.listen(_onPayload);
      _logSub = _ble.logs.listen(
        (msg) => debugPrint('[grassroots_bluetooth_layer] $msg'),
      );

      // `restoreState: true` opts the iOS plugin into CoreBluetooth's
      // state-preservation. With this on, when iOS suspends and later
      // relaunches the app for a BLE event, the peripheral subscriptions,
      // GATT services and active scan are re-attached and the plugin's
      // `willRestoreState` handler rebuilds its in-process tables.
      await _ble.initialize(verboseLogging: true, restoreState: true);

      _setState(TransportState.ready);
      return true;
    } catch (e) {
      debugPrint('Failed to initialize BLE transport: $e');
      _setState(TransportState.error);
      return false;
    }
  }

  @override
  Future<void> start() async {
    if (state != TransportState.ready && state != TransportState.active) {
      debugPrint('Cannot start BLE transport in state: $state');
      return;
    }
    if (_starting) {
      // Re-entrant start (e.g. adapter-on event firing while a previous
      // start is still awaiting). Skip to avoid a redundant tear-down/rebuild
      // cycle that would drop currently-subscribed peripheral centrals.
      return;
    }
    _starting = true;
    _stopped = false;

    final mode = store.state.settings.bleRoleMode;
    final shouldAdvertise = mode != BleRoleMode.centralOnly;
    final shouldScan = mode != BleRoleMode.peripheralOnly;
    debugPrint('BLE start: roleMode=$mode '
        'advertise=$shouldAdvertise scan=$shouldScan');

    // Advertising and scanning are independent; failure in one must not
    // prevent the other. Track whether at least one succeeded — if both
    // fail (e.g. adapter still off), stay in `ready` so the next
    // adapter-on event re-invokes `start()`.
    var anyStarted = false;
    try {
      if (shouldAdvertise) {
        try {
          await _ble.startAdvertising(
            serviceUuid: identity.bleServiceUuid,
            characteristicUuid: _grassrootsCharacteristicUuid,
            localName: localName,
            bondless: true,
          );
          anyStarted = true;
          _advertisedSlot = GrassrootsIdentity.currentBleSlot();
          _advertiseLocalName = localName;
          _startSlotTimer();
        } catch (e) {
          debugPrint('Failed to start advertising: $e');
        }
      } else {
        // Make sure we aren't lingering as an advertiser from a previous
        // mode — explicitly tear down.
        _stopSlotTimer();
        _advertisedSlot = null;
        try {
          await _ble.stopAdvertising();
        } catch (_) {}
      }

      if (shouldScan) {
        _scanTargetUuids = _reverseLegScanTargets();
        if (await _startContinuousScan()) {
          anyStarted = true;
          _lastAdvertisementAt = DateTime.now();
          _armScanWatchdog();
        }
      } else {
        _scanWatchdog?.cancel();
        _scanWatchdog = null;
        try {
          await _ble.stopScan();
        } catch (_) {}
      }

      if (anyStarted) {
        _setState(TransportState.active);
      }
    } finally {
      _starting = false;
    }
  }

  void _armScanWatchdog() {
    _scanWatchdog?.cancel();
    _scanWatchdog = Timer.periodic(
      _scanWatchdogInterval,
      (_) => unawaited(checkScanLiveness()),
    );
  }

  void _startSlotTimer() {
    _slotTimer?.cancel();
    _slotTimer = Timer.periodic(
      _slotCheckInterval,
      (_) => unawaited(_maybeReAdvertiseForSlot()),
    );
  }

  void _stopSlotTimer() {
    _slotTimer?.cancel();
    _slotTimer = null;
  }

  /// Re-advertise the current slot's beacon when the 15-minute BLE slot has
  /// advanced past the slot we last advertised. The advertised service UUID's
  /// suffix is a function of the slot, so a new slot is a new beacon; the
  /// re-advertise rebuilds the peripheral GATT service under the new UUID
  /// (plugin >= 0.3.0 restarts advertising after that rebuild). Live peripheral
  /// links drop and re-establish across the boundary — the accepted cost of an
  /// unlinkable, rotating beacon.
  @visibleForTesting
  Future<void> maybeReAdvertiseForSlot() => _maybeReAdvertiseForSlot();

  Future<void> _maybeReAdvertiseForSlot() async {
    if (_stopped) return;
    final slot = GrassrootsIdentity.currentBleSlot();
    if (slot == _advertisedSlot) return;
    try {
      await _ble.startAdvertising(
        serviceUuid: identity.bleServiceUuid,
        characteristicUuid: _grassrootsCharacteristicUuid,
        localName: _advertiseLocalName,
        bondless: true,
      );
      _advertisedSlot = slot;
      debugPrint('[ble] rotated advertised beacon to slot $slot');
    } catch (e) {
      // Leave _advertisedSlot unchanged so the next tick retries.
      debugPrint('[ble] slot re-advertise failed (will retry): $e');
    }
  }

  /// Restart the continuous scan if the airwaves have been silent past
  /// [scanSilenceRestart] — the recovery for a silently muted scanner (see
  /// the field doc). One restart per silence window: the clock resets on the
  /// restart itself, so an empty room costs one cheap stop+start per window
  /// rather than one per watchdog tick.
  @visibleForTesting
  Future<void> checkScanLiveness({DateTime? now}) async {
    if (_stopped) return;
    if (store.state.settings.bleRoleMode == BleRoleMode.peripheralOnly) {
      return;
    }
    final t = now ?? DateTime.now();
    if (t.difference(_lastAdvertisementAt) < scanSilenceRestart) return;

    // Silence means the scan is dead. If we have pending reverse legs, restart
    // it hardware-FILTERED for exactly those identities — a filterless restart
    // just re-enters the same Android muting that stranded us here.
    _scanTargetUuids = _reverseLegScanTargets();
    debugPrint(
      _scanTargetUuids.isEmpty
          ? '[ble] scan-watchdog: no advertisements for '
              '${scanSilenceRestart.inSeconds}s — restarting the continuous '
              'scan (a long-running unfiltered Android scan can be silently '
              'muted).'
          : '[ble] scan-watchdog: no advertisements for '
              '${scanSilenceRestart.inSeconds}s with pending reverse legs — '
              'restarting a hardware-filtered scan for their identities '
              '(the unfiltered scan is being silently muted under load).',
    );
    _lastAdvertisementAt = t;
    await _startContinuousScan();
  }

  /// Candidate service UUIDs of every peer we hold a live inbound peripheral
  /// leg from but have no live/in-flight central (reverse) leg to — i.e. the
  /// pairs stuck single-link that need us to dial back. Feeding these to the
  /// scanner as hardware filters is what makes Android reliably surface their
  /// advertising MAC (see [_scanTargetUuids]). Empty in steady state, so the
  /// scan falls back to a plain prefix scan and normal discovery continues.
  Set<String> _reverseLegScanTargets() {
    if (store.state.settings.bleRoleMode != BleRoleMode.auto) return const {};
    final targets = <String>{};
    for (final peer in _peersState.peersList) {
      final peripheralId = peer.blePeripheralDeviceId;
      if (peripheralId == null || !isDeviceConnected(peripheralId)) continue;
      final uuid = GrassrootsIdentity.deriveServiceUuidForSlot(
        peer.publicKey,
        GrassrootsIdentity.currentBleSlot(),
      );
      final pair = _pairViewFor(uuid);
      if (pair.liveCentralPathId != null || pair.centralInFlight) continue;
      targets.addAll(GrassrootsIdentity.candidateServiceUuids(peer.publicKey));
    }
    return targets;
  }

  /// (Re)start the continuous scan with the current [_scanTargetUuids] as
  /// hardware filters (or a plain prefix scan when empty). Returns whether the
  /// scan started. `allowDuplicates` keeps already-discovered peers surfacing
  /// so RSSI refreshes and reverse-leg retries keep flowing.
  Future<bool> _startContinuousScan() async {
    try {
      await _ble.startScan(
        serviceUuidPrefix: GrassrootsIdentity.grassrootsUuidPrefix,
        serviceUuids: _scanTargetUuids.toList(growable: false),
        timeout: Duration.zero,
        allowDuplicates: true,
      );
      if (_scanTargetUuids.isNotEmpty) {
        debugPrint(
          '[ble] scan: hardware-filtered for ${_scanTargetUuids.length} '
          'candidate UUID(s) covering stuck reverse-leg peers',
        );
      }
      return true;
    } catch (e) {
      debugPrint('[ble] startContinuousScan failed: $e');
      return false;
    }
  }

  /// Recompute the reverse-leg scan targets and, if they changed, restart the
  /// scan to match. Debounced ([setEquals]) so steady state issues no scan
  /// restarts. Called whenever a leg attaches/detaches or a reverse leg is
  /// found stuck.
  Future<void> _applyScanTargets() async {
    if (_stopped) return;
    if (state != TransportState.active) return;
    if (store.state.settings.bleRoleMode != BleRoleMode.auto) return;
    final targets = _reverseLegScanTargets();
    if (setEquals(targets, _scanTargetUuids)) return;
    _scanTargetUuids = targets;
    if (await _startContinuousScan()) {
      _lastAdvertisementAt = DateTime.now();
    }
  }

  /// Apply a runtime role-mode change. Stops the current scan/advertise and
  /// restarts under the new mode. Existing live paths are left untouched —
  /// the plugin's path stream will tear them down naturally if the OS
  /// disconnects them.
  Future<void> applyRoleModeChange() async {
    if (state != TransportState.active && state != TransportState.ready) {
      return;
    }
    debugPrint('BLE role mode changed → restarting transport');
    try {
      await _ble.stopScan();
    } catch (_) {}
    try {
      await _ble.stopAdvertising();
    } catch (_) {}
    if (state == TransportState.active) {
      _setState(TransportState.ready);
    }
    await start();
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _scanWatchdog?.cancel();
    _scanWatchdog = null;
    _stopSlotTimer();
    _advertisedSlot = null;
    try {
      await _ble.stopScan();
    } catch (_) {}
    try {
      await _ble.stopAdvertising();
    } catch (_) {}

    // Disconnect every known path. Order doesn't matter — the plugin emits
    // disconnected events that we project into Redux.
    final pathIds = _paths.keys.toList(growable: false);
    for (final pathId in pathIds) {
      try {
        await _ble.disconnect(pathId, forget: true);
      } catch (_) {}
    }

    if (state == TransportState.active) {
      _setState(TransportState.ready);
    }
  }

  /// Trigger a finite scan window. The plugin handles the timeout natively.
  Future<void> scan({Duration? timeout}) async {
    if (store.state.settings.bleRoleMode == BleRoleMode.peripheralOnly) {
      return;
    }
    final t = timeout ?? const Duration(seconds: 10);
    try {
      await _ble.startScan(
        serviceUuidPrefix: GrassrootsIdentity.grassrootsUuidPrefix,
        timeout: t,
        // Match the continuous-scan path so already-discovered peers keep
        // surfacing for RSSI refreshes and reverse-leg retries.
        allowDuplicates: true,
      );
    } catch (e) {
      debugPrint('scan() failed: $e');
    }
  }

  @override
  Future<bool> sendToPeer(String peerId, Uint8List data) async {
    final path = _paths[peerId];
    if (path == null || !_isReady(path)) {
      return false;
    }
    try {
      await _ble.send(peerId, data);
      return true;
    } catch (e) {
      debugPrint('send() failed for $peerId: $e');
      return false;
    }
  }

  @override
  Future<int> broadcast(Uint8List data, {Set<String>? excludePeerIds}) async {
    // Sort by RSSI descending so the strongest signals get the data first.
    // Paths without a known RSSI (peripheral-role on iOS/Android, where the
    // OS doesn't expose remote signal strength) sort last via a very-weak
    // fallback so they still receive the broadcast.
    final ready = _readyPaths.toList()
      ..sort((a, b) => (b.rssi ?? -100).compareTo(a.rssi ?? -100));
    var sent = 0;
    for (final path in ready) {
      if (excludePeerIds != null && excludePeerIds.contains(path.pathId)) {
        continue;
      }
      try {
        await _ble.send(path.pathId, data);
        sent++;
      } catch (e) {
        debugPrint('broadcast send() failed for ${path.pathId}: $e');
      }
    }
    return sent;
  }

  /// Act on the pair's reverse leg the moment a verified ANNOUNCE identifies
  /// the peer behind a BLE path. Wired from
  /// `MessageRouter.onBlePeerIdentified`, after the announce has been applied
  /// to Redux (so the role attachment is already visible to [_pairViewFor]).
  ///
  /// Peripheral-role paths only — an inbound leg just became attributable,
  /// which is the authoritative moment to open the pair's SECOND (reverse
  /// central) link now, at ANNOUNCE time rather than next-advertisement time.
  /// The advertisement-driven election remains the retry path if no
  /// advertising MAC for the identity is known yet.
  ///
  /// EXPERIMENT: platform is no longer consulted here. We dial the reverse
  /// leg regardless of platform, including when we are iOS and the peer is
  /// not — deliberately exercising the (unverified in this build) claim that
  /// an iOS central cannot open the second link toward a peer it is already
  /// linked with.
  ///
  /// Central-role paths need nothing here: the peer opens its own reverse leg.
  void onPeerIdentified(String pathId, Uint8List pubkey, PeerPlatform platform) {
    final path = _paths[pathId];
    if (path == null || !_isReady(path)) return;
    if (_roleFromPathId(pathId) != BleRole.peripheral) return;

    if (store.state.settings.bleRoleMode != BleRoleMode.auto) return;

    // Already have the central direction (live or mid-handshake)? Nothing
    // to do — without this, every periodic ANNOUNCE over the peripheral leg
    // of a healthy dual-role pair would re-run the reverse-leg attempt.
    final pair = _pairViewFor(GrassrootsIdentity.deriveServiceUuidForSlot(
        pubkey, GrassrootsIdentity.currentBleSlot()));
    if (pair.liveCentralPathId != null || pair.centralInFlight) return;

    unawaited(_openReverseLeg(pathId, pubkey));
  }

  /// Open the reverse (central) leg toward a peer whose inbound peripheral
  /// leg [peripheralPathId] just became attributable.
  ///
  /// Preferred target: the inbound link's OWN remote address. Connecting to a
  /// device we already share an ACL link with attaches our GATT client over
  /// that existing link — no second ACL is created. This matters because a
  /// second ACL between the same two radios is refused by spec-conformant
  /// stacks: measured on Pixel 10 Pro (Android 16), every dial to the peer's
  /// advertised MAC fast-failed GATT 133 while the first link existed, while
  /// older Android 8.1 pairs happened to tolerate dual ACLs. (The measured
  /// iOS "cannot open the second link" wedge is plausibly the same LL rule.)
  ///
  /// Fallback: a discovered advertising MAC (a fresh ACL) for stacks where
  /// dialing the connection address fails outright.
  Future<void> _openReverseLeg(
    String peripheralPathId,
    Uint8List pubkey,
  ) async {
    // A scanned advertising MAC for this identity, if the scanner has one.
    // Its UUID is the peer's current advertised (= GATT, they rotate
    // together) service UUID — fresher than a clock-derived one.
    DiscoveredPeerState? scanned;
    for (final uuid in GrassrootsIdentity.candidateServiceUuids(pubkey)) {
      for (final dp in _peersState.getDiscoveredBlePeersByServiceUuid(uuid)) {
        if (!dp.isConnected && !dp.isConnecting) {
          scanned = dp;
          break;
        }
      }
      if (scanned != null) break;
    }

    final remoteId = peripheralPathId.substring('peripheral:'.length);
    final gattUuid = scanned?.serviceUuid ??
        GrassrootsIdentity.deriveServiceUuidForSlot(
            pubkey, GrassrootsIdentity.currentBleSlot());
    debugPrint(
      '[ble] reverse leg: dialing central:$remoteId over the existing '
      'inbound link (attaches to the live ACL; a second ACL to the same '
      'peer is refused by modern stacks).',
    );
    if (await connectToDevice('central:$remoteId',
        serviceUuidOverride: gattUuid)) {
      return;
    }

    // The over-ACL dial did not start (choke-point guard or a stack that
    // cannot connect to a connection address) — fall back to a fresh ACL
    // toward the scanned advertising MAC.
    if (scanned != null) {
      debugPrint(
        '[ble] reverse leg: over-ACL dial did not start; dialing advertised '
        '${scanned.transportId} instead.',
      );
      unawaited(connectToDevice(scanned.transportId));
      return;
    }

    // Loud on purpose: a peripheral-attached peer with no dialable target is
    // the signature of a muted scanner (the pair then silently stays
    // single-link). The scan watchdog restarts a silent scanner; this log is
    // the breadcrumb tying the two together.
    debugPrint(
      '[ble] reverse leg: over-ACL dial did not start and no advertising '
      'MAC for the identity has been discovered — waiting for an '
      'advertisement.',
    );
    // Add this identity to the hardware scan filter so Android reliably
    // surfaces its advertisement (the unfiltered scan is what got muted).
    unawaited(_applyScanTargets());
  }

  @override
  String? getPeerIdForPubkey(Uint8List pubkey) {
    final peer = _peersState.getPeerByPubkey(pubkey);
    if (peer == null) return null;

    // Prefer our central path because writes go directly to the peer's GATT
    // characteristic; fall back to the inbound peripheral path when that is
    // the only ready route.
    final centralId = peer.bleCentralDeviceId;
    if (centralId != null && isDeviceConnected(centralId)) {
      return centralId;
    }
    final peripheralId = peer.blePeripheralDeviceId;
    if (peripheralId != null && isDeviceConnected(peripheralId)) {
      return peripheralId;
    }
    return null;
  }

  @override
  Uint8List? getPubkeyForPeerId(String peerId) {
    for (final peer in _peersState.peersList) {
      if (peer.bleCentralDeviceId == peerId ||
          peer.blePeripheralDeviceId == peerId) {
        return peer.publicKey;
      }
    }
    return null;
  }

  /// Accepted-friend hint for a BLE path.
  ///
  /// For already authenticated paths this returns the mapped friend pubkey.
  /// For pre-ANNOUNCE central paths it may return a friend whose derived
  /// service UUID matches the advertisement. That second case is only a hint:
  /// callers must not send friend-only metadata until a signed ANNOUNCE maps
  /// the path to the same public key.
  Uint8List? getFriendPubkeyHintForPeerId(String peerId) {
    final mappedPubkey = getPubkeyForPeerId(peerId);
    if (mappedPubkey != null) {
      final peer = _peersState.getPeerByPubkey(mappedPubkey);
      if (peer?.isFriend == true) return mappedPubkey;
    }

    final discovered = _peersState.getDiscoveredBlePeer(peerId);
    final serviceUuid = discovered?.serviceUuid;
    if (serviceUuid == null) return null;
    return _friendPubkeyForDerivedServiceUuid(serviceUuid);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _adapterSub?.cancel();
    await _advertisementSub?.cancel();
    await _pathSub?.cancel();
    await _payloadSub?.cancel();
    await _logSub?.cancel();
    try {
      await _ble.dispose();
    } catch (_) {}

    _setState(TransportState.disposed);
    await _dataController.close();
    await _connectionController.close();
  }

  // ===== Connect/disconnect =====

  /// Dial the central leg to a discovered peer. The pathId is
  /// `central:<remote-id>`.
  ///
  /// THE choke point: every central dial — election-driven from
  /// [_onAdvertisement], reverse-leg from [onPeerIdentified], or a manual UI
  /// tap — passes through here, and each validity guard is enforced exactly
  /// once, in order. The plugin's `connect()` idempotency (Android returns
  /// the live path; iOS never drops an existing link) is the backstop for
  /// any race that slips through. Path-state updates flow through
  /// `_onPathChanged`, which is the only dispatcher of
  /// `BleDeviceConnectingAction` / `Connected` / `Failed`.
  /// [serviceUuidOverride] supplies the peer's GATT service UUID for dial
  /// targets that have no scanner discovery entry — the reverse-leg dial to a
  /// live inbound link's remote address (see [_openReverseLeg]). Ignored when
  /// the discovery map already knows the advertised UUID (the fresher truth).
  Future<bool> connectToDevice(
    String pathId, {
    String? serviceUuidOverride,
  }) async {
    if (!pathId.startsWith('central:')) {
      // Peripheral-side paths are inbound — we don't dial them.
      return false;
    }
    final discovered = _peersState.getDiscoveredBlePeer(pathId);
    final serviceUuid = discovered?.serviceUuid ?? serviceUuidOverride;
    if (serviceUuid == null) {
      debugPrint('Cannot connect to $pathId: no advertised service UUID');
      return false;
    }

    final pair = _pairViewFor(serviceUuid);
    // One central leg per identity — live or in flight, across MAC
    // rotations. Dialing a freshly-rotated MAC while another is up is the
    // GATT-status-133 storm.
    if (pair.liveCentralPathId != null || pair.centralInFlight) {
      return false;
    }
    // EXPERIMENT: the iOS "cannot open the second link toward a non-iOS peer"
    // veto has been removed. We now dial the reverse central leg even when
    // we are iOS and already hold an inbound peripheral leg from a non-iOS
    // peer, to observe whether that dial actually wedges in `connecting`.
    if (store.state.settings.coldCallTrustLevel == ColdCallTrustLevel.closed &&
        _friendPubkeyForDerivedServiceUuid(serviceUuid) == null) {
      debugPrint('Skipping $pathId: closed trust and unknown service UUID');
      return false;
    }
    // TESTBED Layer 1 (software-defined topology): refuse the dial when the
    // allowlist is active and this peer's derived service UUID is not an
    // allowed neighbour. This is the cleanest enforcement point — it never
    // opens the leg, so there is no flapping. Off in production.
    final allowlist = store.state.settings.neighborAllowlist;
    if (allowlist != null &&
        allowlist.enabled &&
        !allowlist.allowsServiceUuid(serviceUuid)) {
      debugPrint('Skipping $pathId: neighbor allowlist excludes this peer');
      return false;
    }
    // BLE address rotation produces a fresh pathId every ~30s for the same
    // peer. Cap the number of in-flight central dials so a chatty rotator
    // can't exhaust the BLE stack's connection slots.
    if (_inFlightCentralDials() >= _maxInFlightCentralDials) {
      return false;
    }

    final remoteId = pathId.substring('central:'.length);
    try {
      await _ble.connect(
        remoteId: remoteId,
        // The peer's GATT service carries the same derived UUID it
        // advertises (design: advertisement and GATT service rotate
        // together), so the discovered UUID is the service to attach to.
        serviceUuid: serviceUuid,
        characteristicUuid: _grassrootsCharacteristicUuid,
        androidMtu: _requestedAndroidMtu,
        // Apple's docs say CoreBluetooth's connect can legitimately take
        // 10-15s, so we stay safely above that. The election's first-mover
        // gate should prevent the simultaneous-dial collision that used to
        // wedge a connect for the full window; 20s is a safety net for any
        // collision that still slips through (e.g. during the first-mover
        // fallback) so it recovers and retries sooner.
        timeout: const Duration(seconds: 20),
      );
      return true;
    } catch (e) {
      // The plugin throws synchronously only for invalid args / adapter off.
      // No path event will fire, so dispatch a failure action ourselves so
      // Redux doesn't show the peer stuck in `isConnecting` (which the
      // plugin would otherwise correct via a `failed` event).
      store.dispatch(BleDeviceConnectionFailedAction(pathId));
      return false;
    }
  }

  Future<void> disconnectDevice(String pathId, {bool forget = true}) async {
    _recordLocalTeardown(pathId);
    try {
      await _ble.disconnect(pathId, forget: forget);
    } catch (e) {
      debugPrint('disconnect() failed for $pathId: $e');
    }
  }

  /// Reset the first-mover fallback clock for the identity behind [pathId]
  /// (see [_lastLocalTeardownAt]). Written under both the discovered
  /// service-UUID key and — when the path is attached to an identified peer —
  /// the pubkey key, so [_lastTeardownFor] finds it from either direction.
  void _recordLocalTeardown(String pathId) {
    final now = DateTime.now();
    final uuid = _peersState.getDiscoveredBlePeer(pathId)?.serviceUuid;
    if (uuid != null) {
      _lastLocalTeardownAt['uuid:${uuid.toLowerCase()}'] = now;
    }
    for (final peer in _peersState.peersList) {
      if (peer.bleCentralDeviceId == pathId ||
          peer.blePeripheralDeviceId == pathId) {
        _lastLocalTeardownAt['pk:${peer.pubkeyHex}'] = now;
        break;
      }
    }
    // Bounded: entries only matter within the fallback window.
    _lastLocalTeardownAt.removeWhere(
      (_, t) => now.difference(t) > firstMoverFallback * 4,
    );
  }

  /// The most recent local teardown for the identity behind [serviceUuid],
  /// or null if none is recorded.
  DateTime? _lastTeardownFor(String serviceUuid) {
    final uuid = serviceUuid.toLowerCase();
    var best = _lastLocalTeardownAt['uuid:$uuid'];
    for (final peer in _peersState.peersList) {
      if (!GrassrootsIdentity.serviceUuidMatchesPubkey(uuid, peer.publicKey)) {
        continue;
      }
      final t = _lastLocalTeardownAt['pk:${peer.pubkeyHex}'];
      if (t != null && (best == null || t.isAfter(best))) best = t;
      break;
    }
    return best;
  }

  /// Process an incoming raw BLE packet. Deserializes and forwards to the
  /// MessageRouter via [onBlePacketReceived]. `rssi` is nullable because
  /// peripheral-role payloads carry no remote-RSSI measurement on either
  /// platform; the downstream router treats null as "unknown" and skips
  /// updating peer RSSI from that packet.
  void onPacketReceived(Uint8List data,
      {String? fromDeviceId, required int? rssi, BleRole? bleRole}) {
    if (_stopped) return;
    try {
      final packet = GrassrootsPacket.deserialize(data);
      onBlePacketReceived?.call(
        packet,
        bleDeviceId: fromDeviceId,
        rssi: rssi,
        bleRole: bleRole,
      );
    } catch (e) {
      debugPrint('Failed to deserialize packet: $e');
    }
  }

  // ===== Peer lifecycle helpers =====

  void onPeerBleConnected(String pathId, {int? rssi}) {
    debugPrint('BLE peer connected: $pathId');
  }

  void onPeerBleDisconnected(Uint8List pubkey, {BleRole? role}) {
    final peer = _peersState.getPeerByPubkey(pubkey);
    if (peer == null) return;
    store.dispatch(PeerBleDisconnectedAction(pubkey, role: role));
    onPeerDisconnected?.call(peer);
  }

  // ===== Plugin event handlers =====

  void _onAdapterStateChanged(ble.BleAdapterState adapterState) {
    if (adapterState != ble.BleAdapterState.poweredOn) {
      // The plugin already stops scan/advertising and tears down paths on
      // adapter-off; mirror that into Redux by dropping back to `ready` so
      // the next adapter-on triggers a fresh `start()`.
      if (state == TransportState.active) {
        _setState(TransportState.ready);
      }
      return;
    }

    // Adapter came back on. iOS resumes deferred scan/advertise itself, but
    // Android throws on a powered-off call so the prior start was dropped.
    // We re-issue both unconditionally when the transport is in `ready`;
    // duplicates are harmless because `start()` calls `stopScan`/`stopAdvertising`
    // first via the plugin's idempotent path.
    if (state == TransportState.ready && !_stopped) {
      unawaited(start());
    }
  }

  void _onAdvertisement(ble.BleAdvertisement adv) {
    // Any delivery proves the scanner is alive — feed the watchdog before
    // any gate below can return.
    _lastAdvertisementAt = DateTime.now();
    final pathId = 'central:${adv.remoteId}';
    final serviceUuid = _firstGrassrootsServiceUuid(adv.serviceUuids);
    if (serviceUuid == null) {
      // Plugin already filters by Grassroots prefix, but defensively skip
      // anything that lost its service UUID before reaching us.
      return;
    }

    final pair = _pairViewFor(serviceUuid);

    // EXPERIMENT: the wrong-order mixed-pair reform (Android tearing down its
    // central leg so a foregrounded iPhone can re-open the pair in the right
    // order) has been removed, along with the grs-ios marker it keyed off.
    // Both sides now dial per the platform-neutral first-mover election.

    // One central leg per identity — live or in flight, across MAC
    // rotations (the identity-keyed [_pairViewFor] sees through a rotated
    // advertising MAC; dialing a fresh MAC while another is up is the
    // GATT-status-133 storm).
    final centralActive =
        pair.liveCentralPathId != null || pair.centralInFlight;
    final existing = _peersState.getDiscoveredBlePeer(pathId);
    if (centralActive && existing == null) {
      // A rotated MAC for an identity whose central leg is already live or
      // being dialed: neither dial it nor pile up a ghost discovery entry.
      return;
    }

    // Redux dispatches BEFORE the dial suppression below: RSSI/lastSeen
    // freshness must keep flowing for connected identities too (UI ordering
    // and the stale-pruning inputs). The reducer merges into the existing
    // entry.
    store.dispatch(BleDeviceDiscoveredAction(
      deviceId: pathId,
      displayName: adv.advertisedName ?? adv.platformName,
      rssi: adv.rssi,
      serviceUuid: serviceUuid,
    ));
    final pubkey = getPubkeyForPeerId(pathId);
    if (pubkey != null) {
      final existingPeer = _peersState.getPeerByPubkey(pubkey);
      if (existingPeer?.rssi == null || existingPeer?.rssi != adv.rssi) {
        store.dispatch(PeerRssiUpdatedAction(
          publicKey: pubkey,
          rssi: adv.rssi,
        ));
      }
    }

    if (centralActive) {
      return;
    }
    if (!_shouldDialNow(pair, serviceUuid, existing)) {
      return;
    }

    // Reverse leg with a live inbound link: dial the link's own remote
    // address so the GATT client attaches over the existing ACL. Dialing the
    // advertised MAC here would attempt a SECOND ACL to the same radio,
    // which modern stacks refuse (fast GATT 133) while a link exists. The
    // freshly-advertised UUID is the peer's current GATT service.
    final livePeripheralPathId = pair.livePeripheralPathId;
    if (livePeripheralPathId != null) {
      final remoteId =
          livePeripheralPathId.substring('peripheral:'.length);
      unawaited(connectToDevice('central:$remoteId',
          serviceUuidOverride: serviceUuid));
      return;
    }

    unawaited(connectToDevice(pathId));
  }

  /// Cap on simultaneous `connecting` central paths.
  /// Each `connectGatt` consumes a controller slot for ~5s on Android; too
  /// many parallel dials starve real connections.
  static const int _maxInFlightCentralDials = 2;

  int _inFlightCentralDials() {
    var count = 0;
    for (final p in _paths.values) {
      if (p.role != ble.BleRole.central) continue;
      if (p.state == ble.BlePathState.connecting ||
          p.state == ble.BlePathState.connected ||
          p.state == ble.BlePathState.subscribed) {
        count++;
      }
    }
    return count;
  }

  /// Central-dial election: decides whether this advertisement should
  /// trigger an outbound (central) dial right now. All *validity* guards
  /// (identity dedup, trust, in-flight cap) live in [connectToDevice] — this
  /// is purely the leg-ORDER arbitration for `auto` mode.
  ///
  /// Dual-role (two legs per pair, each device central on one) is mandatory —
  /// see CLAUDE.md, "Dual-Role BLE Is Mandatory".
  ///
  /// EXPERIMENT: all iOS-specific leg-order arbitration has been removed. The
  /// election is now platform-neutral for every pair:
  ///
  ///  - If we already hold the inbound peripheral leg, dial the reverse
  ///    (central) leg unconditionally — including when we are iOS and the
  ///    peer is not. This is the case that tests whether an iOS central can
  ///    actually open a second link toward a peer it is already linked with.
  ///  - Otherwise pick the first link by the deterministic service-UUID
  ///    tiebreaker (mirroring the UDP "smaller pubkey initiates" convention),
  ///    backstopped by [firstMoverFallback] so the non-initiator still opens
  ///    a link if the expected initiator never shows.
  ///
  /// Auto-only: a central-only device never advertises, so it can never be
  /// dialed and must always first-move.
  bool _shouldDialNow(
    _PairView pair,
    String serviceUuid,
    DiscoveredPeerState? existing,
  ) {
    if (store.state.settings.bleRoleMode != BleRoleMode.auto) return true;

    // We already hold the inbound leg: this dial is our reverse leg, which
    // completes the dual-role pair. Attempt it for every pair regardless of
    // platform.
    if (pair.livePeripheral) return true;

    // No leg yet: deterministic first-mover, non-initiator dials on fallback.
    return _isBleDialInitiator(serviceUuid) ||
        _fallbackElapsed(existing, serviceUuid);
  }

  /// Cold-start tie-breaker between same-platform peers: the one whose
  /// derived service UUID sorts lower is the initiator and opens the first
  /// (central) leg; the higher one waits for that inbound leg and then opens
  /// its reverse central leg via [onPeerIdentified]. Mirrors the UDP
  /// "smaller pubkey initiates" convention, adapted to what we have at
  /// advertisement time: the service UUID is a stable, deterministic function
  /// of the pubkey, so both peers compute the same comparison and reach
  /// opposite verdicts. Without it, both peers dial on discovery and collide.
  bool _isBleDialInitiator(String peerServiceUuid) {
    return identity.bleServiceUuid.toLowerCase().compareTo(
              peerServiceUuid.toLowerCase(),
            ) <
        0;
  }

  /// Whether we've been seeing [existing] long enough that the expected
  /// initiator has had its chance and we should fall back to dialing. A
  /// just-discovered (or absent) entry is never elapsed — the initiator gets
  /// the first move.
  ///
  /// The clock starts at the LATER of first discovery and our last local
  /// teardown of a leg to this identity (see [_lastLocalTeardownAt]).
  bool _fallbackElapsed(DiscoveredPeerState? existing, String serviceUuid) {
    if (existing == null) return false;
    var since = existing.discoveredAt;
    final teardown = _lastTeardownFor(serviceUuid);
    if (teardown != null && teardown.isAfter(since)) since = teardown;
    return DateTime.now().difference(since) >= firstMoverFallback;
  }

  /// One identity-keyed answer to every pair-state question the arbitration
  /// asks about the peer behind [serviceUuid]. Computed from plugin path
  /// facts ([_paths] + [isDeviceConnected]) and Redux attachments — never
  /// inferred.
  ///
  /// Identity matching is rotation-stable: an identified peer is matched via
  /// [GrassrootsIdentity.serviceUuidMatchesPubkey] (prev/current/next slot),
  /// and its in-flight central dials are found by matching every central
  /// path's discovery UUID against the same candidate set — so a freshly
  /// rotated advertising MAC still resolves to the same pair. Pre-identity,
  /// only the literal advertised UUID can be matched.
  _PairView _pairViewFor(String serviceUuid) {
    final uuid = serviceUuid.toLowerCase();

    PeerState? identified;
    for (final peer in _peersState.peersList) {
      if (GrassrootsIdentity.serviceUuidMatchesPubkey(uuid, peer.publicKey)) {
        identified = peer;
        break;
      }
    }

    final candidates = identified != null
        ? GrassrootsIdentity.candidateServiceUuids(identified.publicKey)
        : {uuid};

    // Central attachment on the identified peer (rotation-stable).
    String? liveCentral;
    final attachedCentral = identified?.bleCentralDeviceId;
    if (attachedCentral != null && isDeviceConnected(attachedCentral)) {
      liveCentral = attachedCentral;
    }

    // Peripheral attachment — needed before the central loop: a reverse-leg
    // dial over the existing ACL targets the peripheral leg's remote address
    // and has NO discovery entry, so it is matched to this identity by
    // remoteId instead of by advertised UUID.
    final attachedPeripheral = identified?.blePeripheralDeviceId;
    final peripheralRemoteId = attachedPeripheral == null
        ? null
        : attachedPeripheral.substring('peripheral:'.length);
    final livePeripheralPathId =
        attachedPeripheral != null && isDeviceConnected(attachedPeripheral)
            ? attachedPeripheral
            : null;

    // Plugin central paths that belong to this identity: matched by the
    // discovery map's advertised UUID (pre-ANNOUNCE window, rotated-MAC
    // dials) or by sharing the attached peripheral leg's remote address (the
    // over-ACL reverse dial, which never appears in scan results).
    var inFlight = false;
    for (final p in _paths.values) {
      if (p.role != ble.BleRole.central) continue;
      final du = _peersState
          .getDiscoveredBlePeer(p.pathId)
          ?.serviceUuid
          ?.toLowerCase();
      final matchesByUuid = du != null && candidates.contains(du);
      final matchesByRemoteId = peripheralRemoteId != null &&
          p.pathId.substring('central:'.length) == peripheralRemoteId;
      if (!matchesByUuid && !matchesByRemoteId) continue;
      if (_isReady(p)) {
        liveCentral ??= p.pathId;
      } else if (p.state == ble.BlePathState.connecting ||
          p.state == ble.BlePathState.connected ||
          p.state == ble.BlePathState.subscribed) {
        inFlight = true;
      }
    }

    return _PairView(
      liveCentralPathId: liveCentral,
      centralInFlight: inFlight,
      livePeripheralPathId: livePeripheralPathId,
    );
  }

  void _onPathChanged(ble.BlePath path) {
    final previous = _paths[path.pathId];
    _paths[path.pathId] = path;

    final role =
        path.role == ble.BleRole.central ? BleRole.central : BleRole.peripheral;

    switch (path.state) {
      case ble.BlePathState.discovered:
        // Already handled by _onAdvertisement for central; for peripheral
        // we only see paths once the central connects.
        break;
      case ble.BlePathState.connecting:
        if (path.role == ble.BleRole.central) {
          store.dispatch(BleDeviceConnectingAction(path.pathId));
        }
        break;
      case ble.BlePathState.connected:
      case ble.BlePathState.subscribed:
        // Not yet sendable — wait for `ready`.
        break;
      case ble.BlePathState.ready:
        if (previous?.state != ble.BlePathState.ready) {
          store.dispatch(BleDeviceConnectedAction(path.pathId));
          _addConnectionEvent(TransportConnectionEvent(
            peerId: path.pathId,
            transport: TransportType.ble,
            connected: true,
            reason: role.name,
            isIncoming: role == BleRole.peripheral,
          ));
          // A ready peripheral leg needs no dial here: the peer's directed
          // ANNOUNCE arrives within one announce interval and triggers the
          // reverse leg via [onPeerIdentified]; later advertisements retry
          // it via the election in [_onAdvertisement].
          //
          // Re-evaluate the reverse-leg scan filters: a new peripheral leg
          // may need targeted scanning to find its MAC, and a completed
          // central leg lets us drop a target and fall back to a broad scan.
          unawaited(_applyScanTargets());
        }
        break;
      case ble.BlePathState.failed:
      case ble.BlePathState.disconnected:
      case ble.BlePathState.stale:
        if (path.state == ble.BlePathState.failed &&
            path.role == ble.BleRole.central) {
          store.dispatch(BleDeviceConnectionFailedAction(path.pathId));
        }
        // Mirror the connect emit at the `ready` case: surface a disconnect
        // to the upper layer only on a true transition out of `ready`.
        // Failed dials from `connecting` never produced a "connected" event,
        // and re-emits of an already-dead path (the iOS `.failed → .disconnected`
        // pair, and scan re-discoveries that keep firing path-changed with
        // the cached state) would otherwise spam disconnect logs.
        if (previous?.state == ble.BlePathState.ready) {
          _emitDisconnect(path, role);
        }
        _paths.remove(path.pathId);
        // A dropped leg may add or clear a reverse-leg scan target.
        unawaited(_applyScanTargets());
        break;
    }
  }

  void _emitDisconnect(ble.BlePath path, BleRole role) {
    if (path.role == ble.BleRole.central) {
      store.dispatch(BleDeviceDisconnectedAction(path.pathId));
    }
    final pubkey = getPubkeyForPeerId(path.pathId);
    if (pubkey != null) {
      onPeerBleDisconnected(pubkey, role: role);
    }
    _addConnectionEvent(TransportConnectionEvent(
      peerId: path.pathId,
      transport: TransportType.ble,
      connected: false,
      reason: path.error ?? role.name,
    ));
  }

  void _addConnectionEvent(TransportConnectionEvent event) {
    if (_connectionController.isClosed) return;
    _connectionController.add(event);
  }

  void _onPayload(ble.BlePayload payload) {
    if (_stopped) return;
    // Drop payloads unless the plugin currently marks the path ready. This
    // prevents late ANNOUNCE packets, hot-restart leftovers, or connected-but-
    // not-sendable paths from populating PeerState BLE role fields.
    final path = _paths[payload.pathId];
    if (path == null || !_isReady(path)) return;

    final role = payload.role == ble.BleRole.central
        ? BleRole.central
        : BleRole.peripheral;
    onPacketReceived(
      payload.value,
      fromDeviceId: payload.pathId,
      rssi: payload.rssi,
      bleRole: role,
    );
    if (_dataController.isClosed) return;
    _dataController.add(TransportDataEvent(
      peerId: payload.pathId,
      transport: TransportType.ble,
      data: payload.value,
    ));
  }

  // ===== Helpers =====

  void _setState(TransportState newState) {
    if (store.state.transports.bleState != newState) {
      store.dispatch(BleTransportStateChangedAction(newState));
    }
  }

  bool _isReady(ble.BlePath path) =>
      path.state == ble.BlePathState.ready && path.canSend;

  Iterable<ble.BlePath> get _readyPaths => _paths.values.where(_isReady);

  Uint8List? _friendPubkeyForDerivedServiceUuid(String serviceUuid) {
    for (final peer in _peersState.friends) {
      if (GrassrootsIdentity.serviceUuidMatchesPubkey(
          serviceUuid, peer.publicKey)) {
        return peer.publicKey;
      }
    }
    return null;
  }

  BleRole? _roleFromPathId(String pathId) {
    if (pathId.startsWith('central:')) return BleRole.central;
    if (pathId.startsWith('peripheral:')) return BleRole.peripheral;
    return null;
  }

  /// Find the first service UUID that matches the Grassroots prefix.
  String? _firstGrassrootsServiceUuid(List<String?> uuids) {
    for (final uuid in uuids) {
      if (uuid == null) continue;
      final hex = uuid.toLowerCase().replaceAll('-', '');
      if (hex.startsWith(GrassrootsIdentity.grassrootsUuidPrefix)) {
        return uuid;
      }
    }
    return null;
  }
}

/// Snapshot of a pair's leg state, keyed by the peer's identity (derived
/// service UUID). Produced by [BleTransportService._pairViewFor]; consumed by
/// the choke-point guards in `connectToDevice` and the election in
/// `_onAdvertisement`.
class _PairView {
  /// Ready (sendable) central path to this identity, if one exists.
  final String? liveCentralPathId;

  /// A central dial to this identity is mid-handshake
  /// (connecting/connected/subscribed — not yet ready).
  final bool centralInFlight;

  /// The ready inbound peripheral leg from this identity, if one exists.
  /// Its remote address is the preferred reverse-leg dial target: connecting
  /// to it attaches our GATT client OVER the existing ACL link instead of
  /// opening a second ACL, which modern stacks (Pixel 10 / Android 16,
  /// measured) refuse with a fast GATT 133 while a link already exists.
  final String? livePeripheralPathId;

  /// We hold a ready inbound peripheral leg from this identity.
  bool get livePeripheral => livePeripheralPathId != null;

  const _PairView({
    required this.liveCentralPathId,
    required this.centralInFlight,
    required this.livePeripheralPathId,
  });
}
