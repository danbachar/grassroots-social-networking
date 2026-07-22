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

  /// Central pathIds we are tearing down for a wrong-order mixed-pair reform
  /// (see `_onAdvertisement`). Advertisements arrive far faster than the
  /// plugin's disconnect round-trip, so without this an ad burst would issue
  /// duplicate disconnects. Entries clear when the path reaches a terminal
  /// state in [_onPathChanged].
  final Set<String> _reformingCentralPathIds = {};

  /// When we last yielded our central leg to the iOS-marked identity behind
  /// each derived service UUID (lowercase) for a wrong-order pair reform.
  /// Read at two horizons: [_reformYieldGrace] holds our first-mover fallback
  /// so the iPhone gets the first leg, and [_reformRetryInterval] spaces out
  /// repeat reforms of a pair the iPhone never rebuilt.
  final Map<String, DateTime> _reformYieldedAtByUuid = {};

  /// How long after a reform yield we refuse to fallback-dial the same
  /// identity. The iPhone needs to observe its peripheral-side disconnect,
  /// re-sight our advertisement, and connect — seconds. Re-dialing on the
  /// next advertisement (tens of ms) recreates the wrong-order central-only
  /// pair before the iPhone ever sees the drop, and its live-peripheral gate
  /// then blocks its dial again: an endless reform↔redial flap.
  static const Duration _reformYieldGrace = Duration(seconds: 12);

  /// Minimum spacing between reform teardowns toward the same identity. A
  /// yield the iPhone never answers ends with our fallback re-dial restoring
  /// the central-only link; tearing that working link down again on the next
  /// marker advertisement would flap the connection forever. Retrying on
  /// this interval keeps the dual-role upgrade pressure without the flap.
  static const Duration _reformRetryInterval = Duration(minutes: 2);

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
        try {
          await _ble.startScan(
            serviceUuidPrefix: GrassrootsIdentity.grassrootsUuidPrefix,
            timeout: Duration.zero, // continuous scan
            // iOS CoreBluetooth deduplicates per-peer advertisements by
            // default; with allowDuplicates=true it keeps delivering
            // didDiscover so we see liveness/RSSI updates and so a peer that
            // joined mid-scan still gets observed. It costs a bit more power,
            // but also gives us fresh chances to retry a missing reverse leg.
            allowDuplicates: true,
          );
          anyStarted = true;
          _lastAdvertisementAt = DateTime.now();
          _armScanWatchdog();
        } catch (e) {
          debugPrint('Failed to start scanning: $e');
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

    debugPrint(
      '[ble] scan-watchdog: no advertisements for '
      '${scanSilenceRestart.inSeconds}s — restarting the continuous scan '
      '(a long-running unfiltered Android scan can be silently muted).',
    );
    _lastAdvertisementAt = t;
    try {
      await _ble.startScan(
        serviceUuidPrefix: GrassrootsIdentity.grassrootsUuidPrefix,
        timeout: Duration.zero,
        allowDuplicates: true,
      );
    } catch (e) {
      debugPrint('[ble] scan-watchdog: scan restart failed: $e');
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
  /// which is the authoritative moment to act on the pair's SECOND link:
  ///
  ///  - Local iOS, non-iOS peer: our reverse leg is the measured-broken
  ///    second link, and any central dial of ours to this identity still in
  ///    flight was racing the inbound leg that just won — it can never reach
  ///    `didConnect` and would hold a dial slot for the full connect
  ///    timeout. Cancel it.
  ///  - Otherwise: dial the reverse central leg now (at ANNOUNCE time, not
  ///    next-advertisement time). The advertisement-driven election remains
  ///    the retry path if no advertising MAC for the identity is known yet.
  ///
  /// Central-role paths need nothing here: the peer's platform was recorded
  /// via Redux, and the peer opens its own reverse leg.
  void onPeerIdentified(String pathId, Uint8List pubkey, PeerPlatform platform) {
    final path = _paths[pathId];
    if (path == null || !_isReady(path)) return;
    if (_roleFromPathId(pathId) != BleRole.peripheral) return;

    if (defaultTargetPlatform == TargetPlatform.iOS &&
        platform != PeerPlatform.ios) {
      _cancelDoomedCentralDials(pubkey);
      return;
    }

    if (store.state.settings.bleRoleMode != BleRoleMode.auto) return;

    // Already have the central direction (live or mid-handshake)? Nothing
    // to do — without this, every periodic ANNOUNCE over the peripheral leg
    // of a healthy dual-role pair would re-run the candidate search and log
    // the muted-scanner breadcrumb below.
    final pair = _pairViewFor(GrassrootsIdentity.deriveServiceUuidForSlot(
        pubkey, GrassrootsIdentity.currentBleSlot()));
    if (pair.liveCentralPathId != null || pair.centralInFlight) return;

    // Pick a discovered advertising MAC that hashes to this identity (under
    // any candidate slot). Modern stacks use BLE privacy — the peer's
    // connection MAC almost never appears in scan results, so the dial
    // target must come from the scanner, not from this path's remoteId.
    DiscoveredPeerState? target;
    for (final uuid in GrassrootsIdentity.candidateServiceUuids(pubkey)) {
      for (final dp in _peersState.getDiscoveredBlePeersByServiceUuid(uuid)) {
        if (!dp.isConnected && !dp.isConnecting) {
          target = dp;
          break;
        }
      }
      if (target != null) break;
    }
    if (target == null) {
      // Loud on purpose: a peripheral-attached peer with no discovered
      // advertising MAC is the signature of a muted scanner (the pair then
      // silently stays single-link). The scan watchdog restarts a silent
      // scanner; this log is the breadcrumb tying the two together.
      debugPrint(
        '[ble] reverse leg: peer is peripheral-attached but no advertising '
        'MAC for their identity has been discovered — waiting for an '
        'advertisement.',
      );
      return;
    }
    debugPrint(
      '[ble] reverse leg: dialing ${target.transportId} '
      '(peripheral up, opening central direction).',
    );
    unawaited(connectToDevice(target.transportId));
  }

  /// iOS only: abort in-flight central dials to the peer identified by
  /// [pubkey]. Called the moment an inbound peripheral leg is authenticated —
  /// from that point any central dial of ours to the same identity is a
  /// doomed second link (it can never reach `didConnect`) and would hold a
  /// dial slot for the full connect timeout.
  void _cancelDoomedCentralDials(Uint8List pubkey) {
    final candidates = GrassrootsIdentity.candidateServiceUuids(pubkey);
    for (final p in _paths.values.toList(growable: false)) {
      if (p.role != ble.BleRole.central) continue;
      if (p.state != ble.BlePathState.connecting) continue;
      final discovered = _peersState.getDiscoveredBlePeer(p.pathId);
      final discoveredUuid = discovered?.serviceUuid?.toLowerCase();
      if (discoveredUuid == null || !candidates.contains(discoveredUuid)) {
        continue;
      }
      debugPrint(
        '[ble] aborting central dial ${p.pathId}: peer just authenticated an '
        'inbound peripheral leg, and an iOS central cannot open a second '
        'link to the same pair.',
      );
      unawaited(disconnectDevice(p.pathId, forget: true));
    }
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
  Future<bool> connectToDevice(String pathId) async {
    if (!pathId.startsWith('central:')) {
      // Peripheral-side paths are inbound — we don't dial them.
      return false;
    }
    final discovered = _peersState.getDiscoveredBlePeer(pathId);
    final serviceUuid = discovered?.serviceUuid;
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
    // The measured iOS constraint, scoped exactly: an iOS central cannot
    // open the second link toward a NON-iOS peer — a dial to an identity we
    // already hold an inbound peripheral leg from would wedge in
    // `connecting` for the full connect timeout. Toward iOS peers the
    // second link is attempted (dual-role mandate; hardware, not
    // extrapolation, gets to refuse — see CLAUDE.md).
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        pair.livePeripheral &&
        pair.peerPlatform != PeerPlatform.ios) {
      debugPrint(
        'Skipping $pathId: already attached via inbound peripheral leg and '
        'an iOS central cannot open a second link toward a non-iOS peer.',
      );
      return false;
    }
    if (store.state.settings.coldCallTrustLevel == ColdCallTrustLevel.closed &&
        _friendPubkeyForDerivedServiceUuid(serviceUuid) == null) {
      debugPrint('Skipping $pathId: closed trust and unknown service UUID');
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

    final markerInThisAd = _advertisementCarriesIosMarker(adv);
    final pair = _pairViewFor(serviceUuid);

    // Wrong-order mixed-pair reform (dual-role mandate, CLAUDE.md). We are
    // non-iOS, hold ONLY a central leg to this iOS identity, and its
    // missing leg — an iOS-central second link toward us — is
    // hardware-broken: the pair can never upgrade in place. The marker in
    // THIS advertisement (not the sticky flag) proves the iOS app is
    // foregrounded right now, i.e. it can redial within seconds. So drop
    // our wrong-order central leg and yield: the iPhone opens the first
    // leg, and our reverse dial completes the dual-role pair. Backgrounded
    // iPhones advertise no marker, so this self-damps — we never trade a
    // working link away unless the peer is provably there to rebuild it.
    if (markerInThisAd &&
        defaultTargetPlatform != TargetPlatform.iOS &&
        store.state.settings.bleRoleMode == BleRoleMode.auto &&
        !pair.livePeripheral &&
        pair.liveCentralPathId != null &&
        !_reformingCentralPathIds.contains(pair.liveCentralPathId) &&
        !_withinReformWindow(serviceUuid, _reformRetryInterval)) {
      final centralId = pair.liveCentralPathId!;
      _reformingCentralPathIds.add(centralId);
      _reformYieldedAtByUuid[serviceUuid.toLowerCase()] = DateTime.now();
      debugPrint(
        '[ble] reforming wrong-order pair: dropping our central leg '
        '$centralId so the (foregrounded) iOS peer can open the first '
        'leg; we reopen ours as the reverse leg.',
      );
      unawaited(disconnectDevice(centralId, forget: true));
      return;
    }

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
    // entry and keeps the sticky iOS marker.
    store.dispatch(BleDeviceDiscoveredAction(
      deviceId: pathId,
      displayName: adv.advertisedName ?? adv.platformName,
      rssi: adv.rssi,
      serviceUuid: serviceUuid,
      isIosMarked: markerInThisAd,
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
    if (!_shouldDialNow(pair, serviceUuid, existing,
        markerInThisAd: markerInThisAd)) {
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
  /// (identity dedup, iOS second link, trust, in-flight cap) live in
  /// [connectToDevice] — this is purely the leg-ORDER arbitration for `auto`
  /// mode.
  ///
  /// Dual-role (two legs per pair, each device central on one) is mandatory —
  /// see CLAUDE.md, "Dual-Role BLE Is Mandatory". The election exists to pick
  /// the leg ORDER that makes it reachable, around one hardware-measured
  /// constraint (A2/iPhone field tests):
  ///
  ///  1. An **iOS central cannot open the second link toward a non-iOS
  ///     peer.** Once such a pair is linked, an iOS-initiated connect never
  ///     reaches `didConnect` and wedges in `connecting` until the connect
  ///     timeout. (Toward iOS peers this is unmeasured, so per the mandate we
  ///     attempt it — hardware, not extrapolation, gets to refuse.)
  ///  2. A **non-iOS central opens a second (reverse) link just fine** — to
  ///     iOS and Android peripherals alike.
  ///
  /// So for mixed pairs iOS must own the first link and the non-iOS side the
  /// reverse leg. Platform knowledge comes from the signed ANNOUNCE
  /// (pubkey-keyed, rotation- and backgrounding-stable) or — pre-identity —
  /// the `grs-ios` advertisement marker ([ble.grassrootsIosLocalName]);
  /// among same-platform peers the deterministic service-UUID tiebreaker
  /// (mirroring the UDP "smaller pubkey initiates" convention) avoids the
  /// measured mutual-dial collision wedge. Every waiting branch is
  /// backstopped by [firstMoverFallback] so a peer whose expected initiator
  /// never shows (backgrounded iOS, peripheral-only device, marker lost from
  /// the scan response) still gets a first link — and the pair keeps
  /// upgrading toward dual-role from there.
  ///
  /// Auto-only: a central-only device never advertises, so it can never be
  /// dialed and must always first-move.
  bool _shouldDialNow(
    _PairView pair,
    String serviceUuid,
    DiscoveredPeerState? existing, {
    required bool markerInThisAd,
  }) {
    if (store.state.settings.bleRoleMode != BleRoleMode.auto) return true;

    // We already hold the inbound leg: this dial is our reverse leg, which
    // completes the dual-role pair — except the one measured-broken reverse
    // case (iOS central toward a non-iOS peer), which is leg-order
    // knowledge and belongs here: without it, every advertisement from a
    // wrong-order pair would round-trip through [connectToDevice] just to
    // hit its veto (that veto stays as the backstop for non-election
    // callers).
    if (pair.livePeripheral) {
      return !(defaultTargetPlatform == TargetPlatform.iOS &&
          pair.peerPlatform != PeerPlatform.ios);
    }

    // No leg yet: pick who opens the pair's FIRST link. The marker in the
    // triggering advertisement counts too — [pair] was computed before the
    // dispatch that records it, so a first sighting would otherwise read as
    // platform-unknown.
    final peerIsIos = pair.peerPlatform == PeerPlatform.ios ||
        (pair.peerPlatform == null && markerInThisAd);
    if (defaultTargetPlatform == TargetPlatform.iOS && !peerIsIos) {
      // Mixed pair: iOS must own the first link — dial on sight.
      return true;
    }
    if (defaultTargetPlatform != TargetPlatform.iOS && peerIsIos) {
      // Mixed pair, we are the non-iOS side: yield the first dial to iOS.
      // The fallback covers an iOS peer that never dials, where a single
      // us-central first link still beats no link.
      //
      // But if we JUST yielded a wrong-order central leg (reform), hold the
      // fallback for the reform grace: the iPhone needs a few seconds to
      // observe its peripheral-side drop, re-sight us, and dial. Re-dialing
      // on the next advertisement (tens of ms) would recreate the same
      // wrong-order pair before it ever sees the drop.
      if (_withinReformWindow(serviceUuid, _reformYieldGrace)) return false;
      return _fallbackElapsed(existing, serviceUuid);
    }
    // Same-platform (incl. iOS↔iOS and unknown↔unknown) pair: deterministic
    // first-mover; the non-initiator dials only on fallback.
    return _isBleDialInitiator(serviceUuid) ||
        _fallbackElapsed(existing, serviceUuid);
  }

  /// Whether [adv] carries the fixed iOS platform marker
  /// ([ble.grassrootsIosLocalName]) in its local name. iOS surfaces a scanned
  /// local name as `advertisedName`; Android surfaces the scan-response name
  /// there too, with the GAP-cached name in `platformName` — check both.
  /// Absence proves nothing (backgrounded iOS drops the name), which is why
  /// every marker-dependent branch in [_shouldDialNow] has a fallback.
  bool _advertisementCarriesIosMarker(ble.BleAdvertisement adv) {
    return adv.advertisedName == ble.grassrootsIosLocalName ||
        adv.platformName == ble.grassrootsIosLocalName;
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

  /// Whether the last wrong-order reform yield toward the identity behind
  /// [serviceUuid] happened less than [window] ago. Guards the reform gate
  /// (against re-tearing-down a pair the iPhone never rebuilt — the
  /// [_reformRetryInterval] anti-flap) and the first-mover fallback (holding
  /// it for the [_reformYieldGrace] so the iPhone can open the first leg).
  /// See [_reformYieldedAtByUuid].
  bool _withinReformWindow(String serviceUuid, Duration window) {
    final yieldedAt = _reformYieldedAtByUuid[serviceUuid.toLowerCase()];
    return yieldedAt != null &&
        DateTime.now().difference(yieldedAt) < window;
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

    // Plugin central paths whose discovery UUID matches this identity — the
    // pre-ANNOUNCE window and in-flight dials on rotated MACs.
    var inFlight = false;
    for (final p in _paths.values) {
      if (p.role != ble.BleRole.central) continue;
      final du = _peersState
          .getDiscoveredBlePeer(p.pathId)
          ?.serviceUuid
          ?.toLowerCase();
      if (du == null || !candidates.contains(du)) continue;
      if (_isReady(p)) {
        liveCentral ??= p.pathId;
      } else if (p.state == ble.BlePathState.connecting ||
          p.state == ble.BlePathState.connected ||
          p.state == ble.BlePathState.subscribed) {
        inFlight = true;
      }
    }

    final attachedPeripheral = identified?.blePeripheralDeviceId;
    final livePeripheral =
        attachedPeripheral != null && isDeviceConnected(attachedPeripheral);

    // Platform: the authenticated ANNOUNCE value when identified, else the
    // pre-identity `grs-ios` marker hint, else null (unknown).
    final platform = identified?.platform ??
        (candidates
                .expand(_peersState.getDiscoveredBlePeersByServiceUuid)
                .any((d) => d.isIosMarked)
            ? PeerPlatform.ios
            : null);

    return _PairView(
      liveCentralPathId: liveCentral,
      centralInFlight: inFlight,
      livePeripheral: livePeripheral,
      peerPlatform: platform,
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
        }
        break;
      case ble.BlePathState.failed:
      case ble.BlePathState.disconnected:
      case ble.BlePathState.stale:
        // A reform teardown (wrong-order mixed pair) has completed its
        // disconnect round-trip; allow future reforms for this pathId.
        _reformingCentralPathIds.remove(path.pathId);
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

  /// We hold a ready inbound peripheral leg from this identity.
  final bool livePeripheral;

  /// The peer's platform: authenticated ANNOUNCE value when identified,
  /// else `ios` if any matching discovery entry carried the `grs-ios`
  /// marker, else null (unknown).
  final PeerPlatform? peerPlatform;

  const _PairView({
    required this.liveCentralPathId,
    required this.centralInFlight,
    required this.livePeripheral,
    required this.peerPlatform,
  });
}
