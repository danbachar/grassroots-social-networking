import 'dart:async';

import 'package:grassroots_bluetooth_layer/grassroots_bluetooth_layer.dart'
    as ble;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:redux/redux.dart';

import '../models/identity.dart';
import '../models/packet.dart';
import '../models/secure_frame.dart';
import '../store/store.dart';
import '../trace/experiment_recorder.dart';
import '../trace/wire_ledger.dart';
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
/// The ATT MTU asked for on every central link: the specification's ceiling,
/// so the two controllers settle at whatever they can both carry rather than
/// at a number chosen here. What they agree on is reported back per path and
/// is what writes are sized against; this is only the opening ask.
const int _requestedAndroidMtu = 517;

/// The BLE default ATT MTU before any negotiation (20-byte usable payload).
/// Used as the fragment-budget fallback when a device has no ready path or has
/// not yet reported an MTU: sizing against it fragments small but never
/// truncates.
const int _defaultAttMtu = 23;

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
  StreamSubscription<ble.BleAdvertisingState>? _advertisingStateSub;
  StreamSubscription<ble.BleScanState>? _scanStateSub;

  /// Which roles the current start asked for, and which the controller has
  /// CONFIRMED running. `active` means the service finished booting: every
  /// requested role confirmed on the air — advertising by the advertiser
  /// callback, scanning by the scan-state event. The calls returning mean
  /// only that the requests were accepted, and a stamp anchored there
  /// reports intent; every establishment measurement anchors on the
  /// `active` transition, so it has to report the fact.
  bool _wantAdvertise = false;
  bool _wantScan = false;
  bool _advertisingConfirmed = false;
  bool _scanConfirmed = false;

  void _promoteIfBooted() {
    if (_stopped) return;
    if (state != TransportState.ready) return;
    if (_wantAdvertise && !_advertisingConfirmed) return;
    if (_wantScan && !_scanConfirmed) return;
    if (!_wantAdvertise && !_wantScan) return;
    _setState(TransportState.active);
  }
  StreamSubscription<ble.BlePath>? _pathSub;
  StreamSubscription<ble.BlePayload>? _payloadSub;
  StreamSubscription<String>? _logSub;

  /// Latest known plugin state per pathId (synchronous mirror of `paths()`).
  /// This is a strict cache of plugin facts, not consumer state.
  final Map<String, ble.BlePath> _paths = {};

  /// True while a `start()` call is in flight. Prevents re-entrant `start()`
  /// from `_onAdapterStateChanged` running concurrently with the original.
  bool _starting = false;

  /// Scan-liveness watchdog (see [scanSilenceRestart]). Armed whenever the
  /// continuous scan is started; cancelled on stop/dispose or when the role
  /// mode stops scanning.
  Timer? _scanWatchdog;
  DateTime _lastAdvertisementAt = DateTime.now();
  static const Duration _scanWatchdogInterval = Duration(seconds: 10);

  /// Debug: periodic OS-level link (ACL) snapshot poll, projected into Redux
  /// for the link-diagnostics overlay. Runs only while the transport is up;
  /// each tick is a no-op unless settings.showLinkDiagnostics is on.
  Timer? _linkSnapshotTimer;
  static const Duration _linkSnapshotInterval = Duration(seconds: 3);

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
    this.scanSilenceRestart = const Duration(seconds: 30),
    this.trace,
    ble.GrassrootsBluetooth? grassrootsBluetooth,
  }) : _ble = grassrootsBluetooth ?? ble.GrassrootsBluetooth();

  /// Optional trace logger for the evaluation instrumentation: per-sample
  /// RSSI records, link-stage events, and the periodic wire byte ledger.
  /// All emissions gate on `trace!.active` — zero cost in production.
  final ExperimentRecorder? trace;

  /// Per-type tx/rx byte counters, drained to a `wire` trace record on a
  /// fixed cadence while tracing is active.
  final WireLedger _wireLedger = WireLedger();

  /// Monotonic tx+rx bytes on this transport instance — the field runner's
  /// proof that a scripted `bleOn: true` segment actually reached the air.
  int get wireBytes => _wireLedger.totalBytes;

  /// Wire-ledger hook: resolve one of our sealed packets' inner content type
  /// (set by the coordinator, which does the sealing). See
  /// [WireLedger.secureContentFor].
  set secureContentResolver(String Function(String packetId) resolver) =>
      _wireLedger.secureContentFor = resolver;
  Timer? _wireLedgerTimer;

  /// Reverse (central) dials in flight toward a peer's inbound connection
  /// address, keyed by the dial's pathId. A dial that starts and then dies
  /// before ready — the observed mode is a 6 ms connect-then-drop on the
  /// peer's rotated address — otherwise triggers nothing until the next
  /// advertisement election, which is where the pair's convergence time was
  /// going. The entry lets the terminal-state handler retry once, at the
  /// peer's freshly advertised MAC.
  final Map<String, Uint8List> _reverseDialPending = {};

  /// Writes held back because their only leg had not negotiated an MTU yet,
  /// keyed by pathId. Released by [_onPathChanged] the moment that leg
  /// reports a bigger MTU, or by their own timer if it never does.
  ///
  /// A leg starts at the 23-byte ATT default and the peer's central side is
  /// what raises it, so a peripheral leg cannot make that happen. The Noise
  /// handshake is dispatched as soon as an ANNOUNCE is verified, which is
  /// routinely before the MTU lands, and a handshake message does not fit in
  /// 20 bytes. Refusing it outright cost three wasted writes and a whole
  /// re-handshake per encounter; waiting forever would cost the pairing
  /// entirely, which is why every deferral carries a deadline and then goes
  /// out regardless.
  final Map<String, List<_DeferredWrite>> _awaitingMtu = {};

  /// How long a write waits for its leg to report an MTU before being sent
  /// anyway. Long enough to cover a negotiation that is merely slow, short
  /// enough that a peer which never negotiates still gets a handshake.
  static const Duration _mtuWait = Duration(seconds: 3);

  /// How long the higher-sorting peer holds its first dial toward an
  /// identity, giving the deterministic initiator its uncontested window.
  ///
  /// This is a stagger, not a wait: a connect lands in ~0.3 s, so 1.5 s is a
  /// few connect-latencies and the initiator has either succeeded (we take
  /// the inbound leg, no dial needed) or failed (we dial, ~2.2 s to session)
  /// well inside it. The predecessor was FIVE seconds, a thousand
  /// connect-latencies of politeness, and that constant — not the ordering —
  /// was what held pairs apart for 4-8 s.
  static const Duration _initiatorGrace = Duration(milliseconds: 1500);

  /// When this identity was first sighted in the current discovery epoch,
  /// keyed by service UUID. The grace above is measured from here, and a
  /// local teardown re-arms it so a re-forming pair gives the initiator its
  /// window again instead of both sides dialing into each other.
  final Map<String, DateTime> _firstSightingAt = {};

  /// Central dials being torn down because they provably lost the race —
  /// our inbound leg from the same identity became ready while they were
  /// still in `connecting`. Excluded from every in-flight view so the
  /// reverse leg can open at once instead of waiting out the loser's 20 s
  /// connect timeout; each entry leaves when its path's terminal event
  /// arrives.
  final Set<String> _cancellingDials = {};

  /// Dials handed to the plugin whose `connecting` path event has not come
  /// back yet. The pair-view suppression reads [_paths], which only learns of
  /// a dial from that event — so in the round-trip window a re-sighting of
  /// the same address would dial again. The election used to mask this by
  /// keeping one side silent; with every sighting dialing, the mark has to
  /// be synchronous.
  final Set<String> _dialingNow = {};

  /// Rate-limit for `dialSkip` records: one per (path, reason) per second.
  /// A sighting arrives many times a second, and the interesting fact is
  /// WHICH gate refused the dial across a window, not every refusal.
  final Map<String, int> _lastDialSkipTraceMs = {};

  /// Why a sighting did not become a dial, on the trace. The sighting-to-dial
  /// gap is where establishment time now lives, and every gate in that path
  /// returns a bare false — a run could not tell WHICH said no.
  void _traceDialSkip(String pathId, String reason) {
    if (!_tracing) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final key = '$pathId|$reason';
    final last = _lastDialSkipTraceMs[key];
    if (last != null && now - last < 1000) return;
    if (_lastDialSkipTraceMs.length > 256) _lastDialSkipTraceMs.clear();
    _lastDialSkipTraceMs[key] = now;
    unawaited(trace!.log({
      'type': 'link',
      't': now,
      'event': 'dialSkip',
      'transport': 'ble',
      'path': pathId,
      'reason': reason,
    }));
  }

  /// Rate-limit for per-peer `rssi` trace records (adv sightings can arrive
  /// many times per second).
  final Map<String, int> _lastRssiTraceMs = {};
  static const int _rssiTraceMinIntervalMs = 900;

  bool get _tracing => trace?.active ?? false;

  /// pathId -> peer pubkey hex, learned at identification and kept for every
  /// path we hold.
  ///
  /// PeerState cannot serve this: it stores ONE central and ONE peripheral
  /// device id per peer, so the moment a rotated address is recorded the
  /// previous path stops resolving — which is exactly the pair the duplicate
  /// check has to compare. Entries are dropped with their path.
  final Map<String, String> _peerHexByPath = {};

  /// When a path first entered a live-but-not-`ready` state, for
  /// [_pruneNeverReadyPaths].
  final Map<String, DateTime> _notReadySince = {};

  /// Backdates a path's not-ready stamp so a test can age it past
  /// [_stuckPathTimeout] without 120 s of wall clock.
  @visibleForTesting
  void ageNotReadyForTest(String pathId, Duration by) {
    final at = _notReadySince[pathId];
    if (at != null) _notReadySince[pathId] = at.subtract(by);
  }

  /// How long a path may sit in connecting/connected/subscribed before it is
  /// declared dead and dropped.
  ///
  /// Nothing else removes it: `_paths.remove` fires only on a plugin-reported
  /// failed/disconnected/stale, so a path whose peer vanished without the OS
  /// saying so lives forever — and keeps being counted by
  /// [_inFlightCentralDials], denying a real dial one of the M slots, and by
  /// [_linksHoldingControllerSlot].
  ///
  /// This is NOT an idle timeout. It does not look at traffic: a path that
  /// reached `ready` is never pruned, however long it then sits silent —
  /// that case belongs to the stale-peer sweep. What ages out here is an
  /// address that never became SENDABLE at all.
  ///
  /// The value has to clear a healthy handshake by a wide margin and equal at
  /// least one dial-grid dwell, so that a path stuck for a whole measurement
  /// window cannot be part of that window's result.
  static const Duration _stuckPathTimeout = Duration(seconds: 120);

  String? _peerHexForPathId(String pathId) {
    final known = _peerHexByPath[pathId];
    if (known != null) return known;
    final pubkey = getPubkeyForPeerId(pathId);
    if (pubkey == null) return null;
    return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Emit one `rssi` sample record, rate-limited per path.
  void _traceRssi(String pathId, int rssi,
      {required String source, String? role}) {
    if (!_tracing) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastRssiTraceMs[pathId];
    if (last != null && now - last < _rssiTraceMinIntervalMs) return;
    // MAC rotation mints fresh pathIds every ~30s; bound the map on long runs.
    if (_lastRssiTraceMs.length > 512) _lastRssiTraceMs.clear();
    _lastRssiTraceMs[pathId] = now;
    unawaited(trace!.log({
      'type': 'rssi',
      't': now,
      'src': source,
      'path': pathId,
      'rssi': rssi,
      if (role != null) 'role': role,
      ...?_peerField(pathId),
    }));
  }

  /// Emit one `link` stage record. The stages are SEPARATE facts about one
  /// path and each can fail without unmaking the ones before it:
  ///
  ///  1. `gattConnected` — the link established. On a leg we dialed this IS
  ///     the establishment, and it is what the dial grid counts.
  ///  2. `identified` — a verified ANNOUNCE bound a pubkey to the path, so we
  ///     now know who is on the other end.
  ///  3. `connected` — the path reached `ready`: GATT-usable, MTU negotiated,
  ///     subscribed.
  ///  4. `session` — a Noise session exists with that peer.
  ///
  /// Keeping them apart is what lets a run distinguish "the dial never
  /// connected" from "it connected to a peer that never announced" from "it
  /// identified but the handshake failed". Collapsing them reports all three
  /// as a failed dial. (`drop` is the terminal stage; discovered / usable are
  /// logged by the coordinator.)
  ///
  /// A CENTRAL establishment additionally carries the dial-parallelism
  /// context, so every establishment in a dial-grid run is attributable
  /// without inferring anything offline:
  ///
  ///  - `inFlight` — how many OTHER central dials were still underway at that
  ///    instant, INCLUDING this one. This is [_inFlightCentralDials], the
  ///    very counter the cap gates on, and a dial is not finished until the
  ///    path reaches `ready` — so a path that has just connected still holds
  ///    one of the M slots. Counting it is what makes the field directly
  ///    comparable to the cap: it runs 1..M, and `inFlight == maxParallel`
  ///    means the cap was saturated at that moment.
  ///  - `maxParallel` / `popN` — the step's M (the cap the runner set) and N
  ///    (radios up). The transport cannot see the plan, so the runner pushes
  ///    them down the same call that sets the cap ([setDialParallelism]).
  ///  - `peripheralLinks` / `totalLinks` — live INBOUND legs, and live legs
  ///    across both roles. These separate the experiment's most likely
  ///    confound from its subject. A peripheral cannot dial (only a central
  ///    issues `connectGatt`), so the in-flight cap has no peripheral
  ///    counterpart, and nothing — app or plugin — limits ACCEPTING inbound
  ///    links. What does limit them is the controller's simultaneous-link
  ///    budget, which both roles SHARE: with every device dialing at M, one
  ///    device can hold up to (N-1) inbound plus M outbound, so N=8 reaches
  ///    14 links on chips that may only carry ~7-10. Without these two
  ///    counters a failure at (N=8, M=2) cannot be told apart from "the
  ///    controller ran out of link slots" — the same number either way.
  void _traceLink(String event, ble.BlePath path, BleRole role) {
    if (!_tracing) return;
    // THE establishment is the link coming up — `gattConnected` — on a leg we
    // dialed. It is emphatically NOT `ready`: reaching `ready` additionally
    // requires the peer's ANNOUNCE to have identified the path, so anchoring
    // the count there conflates three independent outcomes and reports a link
    // that demonstrably established as if the dial had failed: with no
    // ANNOUNCE flowing, no path reaches `ready` at all.
    final establishment = event == 'gattConnected' && role == BleRole.central;
    // Every stage of the same path carries the cell context, so the analyzer
    // can subtract stage timestamps per (popN, maxParallel) cell and get
    // time-to-link, time-to-identity and time-to-ready as separate results
    // instead of one all-or-nothing number.
    final staged = establishment ||
        event == 'identified' ||
        event == 'connected' ||
        event == 'session';
    unawaited(trace!.log({
      'type': 'link',
      't': DateTime.now().millisecondsSinceEpoch,
      'event': event,
      'path': path.pathId,
      'role': role.name,
      if (path.rssi != null) 'rssi': path.rssi,
      // The negotiated ATT MTU at this stage. Recorded on EVERY stage, not
      // only beside a drop: a link that never leaves the 23-byte ATT default
      // is reported ready and then refuses every ANNOUNCE and handshake write
      // as oversized, so it can never identify a peer or reach a session —
      // and with the value logged only on failure, a healthy link's MTU was
      // absent from the traces entirely and the two cases were
      // indistinguishable. Stamping it per stage also dates the negotiation:
      // whether the exchange lands before `gattConnected`, between there and
      // `identified`, or never.
      'mtu': path.mtu,
      if (event == 'drop') 'reason': path.error ?? path.state.name,
      if (establishment) 'establishment': true,
      if (establishment) 'inFlight': _inFlightCentralDials(),
      if (establishment)
        'peripheralLinks':
            _linksHoldingControllerSlot(ble.BleRole.peripheral),
      if (establishment) 'totalLinks': _linksHoldingControllerSlot(null),
      if (staged && dialProbeMaxParallel != null)
        'maxParallel': dialProbeMaxParallel,
      if (staged && dialProbePopN != null) 'popN': dialProbePopN,
      ...?_peerField(path.pathId),
    }));
  }

  /// Prune addresses that never became usable.
  ///
  /// `_paths.remove` runs only from a plugin-reported failed/disconnected/
  /// stale, so a peer that goes away without the OS surfacing it leaves an
  /// entry that is counted forever — by [_inFlightCentralDials], which then
  /// denies a real dial one of the M slots, and by
  /// [_linksHoldingControllerSlot].
  ///
  /// Disconnect first, then forget: dropping our bookkeeping alone would free
  /// the counter while the controller still held the link, which is the
  /// opposite of the intent.
  /// Runs one reap sweep. The production caller is the link-snapshot timer;
  /// tests drive it directly rather than waiting 120 s of wall clock.
  @visibleForTesting
  void pruneNeverReadyPathsNow() => _pruneNeverReadyPaths();

  void _pruneNeverReadyPaths() {
    final now = DateTime.now();
    final dead = <String>[];
    for (final entry in _notReadySince.entries) {
      final path = _paths[entry.key];
      if (path == null) continue;
      if (_isReady(path)) continue;
      if (now.difference(entry.value) < _stuckPathTimeout) continue;
      dead.add(entry.key);
    }
    for (final pathId in dead) {
      final path = _paths[pathId];
      debugPrint('[ble] pruning $pathId — never reached ready '
          '(stuck at ${path?.state.name} for '
          '${_stuckPathTimeout.inSeconds}s)');
      if (_tracing && path != null) {
        final role = _roleFromPathId(pathId);
        unawaited(trace!.log({
          'type': 'link',
          't': now.millisecondsSinceEpoch,
          // What actually happened: an ADDRESS we connected to never became
          // usable, and we are giving up on it. Not a drop (the peer never
          // told us anything), not a disconnect of a working link — this
          // path never carried a byte, because `ready` is what makes a path
          // sendable.
          'event': 'pruned',
          'reason': 'neverReady',
          'path': pathId,
          if (role != null) 'role': role.name,
          // The stage it died in: `connecting` means the dial never landed,
          // `connected`/`subscribed` mean the link came up and the peer never
          // identified itself, which is the rotated-address case.
          'stuckState': path.state.name,
          'afterSec': _stuckPathTimeout.inSeconds,
          ...?_peerField(pathId),
        }));
      }
      unawaited(disconnectDevice(pathId));
      _paths.remove(pathId);
      _peerHexByPath.remove(pathId);
      _notReadySince.remove(pathId);
    }
  }

  /// Legs holding a controller link slot in [role], or across both roles when
  /// null.
  ///
  /// A slot is taken from the moment GATT connects, NOT when the path reaches
  /// `ready` — `ready` additionally requires identity and `canSend`, neither
  /// of which the controller knows or cares about. Counting only `ready` legs
  /// undercounts precisely the confound these fields exist to expose: at the
  /// instant a link comes up, the link itself and any sibling still short of
  /// `ready` are already consuming the budget that decides whether the next
  /// dial can succeed at all.
  int _linksHoldingControllerSlot(ble.BleRole? role) {
    var count = 0;
    for (final p in _paths.values) {
      if (role != null && p.role != role) continue;
      if (p.state == ble.BlePathState.connected ||
          p.state == ble.BlePathState.subscribed ||
          p.state == ble.BlePathState.ready) {
        count++;
      }
    }
    return count;
  }

  /// Every currently-live leg, as the link records that WOULD have been
  /// written had the trace been running when they connected. Logged once at
  /// experiment start: links formed before the recording — phones sitting
  /// together with radios on — are otherwise invisible to any topology
  /// reconstruction, which replays events and cannot see an edge whose
  /// connect predates the file. The home preflight drew its founding trio at
  /// degree 0 for exactly this reason while delivering 99.9% of its sends.
  List<Map<String, dynamic>> liveLinkSnapshot() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      for (final path in _readyPaths)
        {
          'type': 'link',
          't': now,
          'event': 'connected',
          'path': path.pathId,
          'role': path.pathId.startsWith('peripheral:')
              ? 'peripheral'
              : 'central',
          // Not a fresh transition: this leg was already up when the
          // recording began.
          'snapshot': true,
          ...?_peerField(path.pathId),
        },
    ];
  }

  Map<String, dynamic>? _peerField(String pathId) {
    final hex = _peerHexForPathId(pathId);
    return hex == null ? null : {'peer': hex};
  }

  /// Public drain for the experiment-stop tail: the periodic timer fires
  /// every 10s, so up to one interval of traffic sat undrained at stop.
  void drainWireLedgerNow() => _drainWireLedger();

  /// Uniform loss record, transport edition — the wire ledger only counts
  /// SUCCESSFUL writes, so without these a failed write is absent from both
  /// the wire totals and any error stream.
  void _traceDrop(String where, String reason,
      [Map<String, dynamic> extra = const {}]) {
    if (!_tracing) return;
    unawaited(trace!.log({
      'type': 'drop',
      't': DateTime.now().millisecondsSinceEpoch,
      'where': where,
      'reason': reason,
      'transport': 'ble',
      ...extra,
    }));
  }

  /// A write that failed on one leg and landed on the pair's other one. Its
  /// own record type, not a `drop`: the failure is already traced as one, and
  /// counting the save as a drop too would make a recovered packet look like
  /// a lost one. How often this fires is the measure of what the second leg
  /// is worth.
  void _traceRetry(String where, Map<String, dynamic> extra) {
    if (!_tracing) return;
    unawaited(trace!.log({
      'type': 'retry',
      't': DateTime.now().millisecondsSinceEpoch,
      'where': where,
      'transport': 'ble',
      ...extra,
    }));
  }

  void _drainWireLedger() {
    if (!_tracing) return;
    final record = _wireLedger.drainRecord(transport: 'ble');
    if (record != null) unawaited(trace!.log(record));
  }

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
      _advertisingStateSub =
          _ble.advertisingStateChanges.listen(_onAdvertisingStateChanged);
      _scanStateSub = _ble.scanStateChanges.listen(_onScanStateChanged);
      _pathSub = _ble.pathChanges.listen(_onPathChanged);
      _payloadSub = _ble.payloads.listen(_onPayload);
      _logSub = _ble.logs.listen(
        (msg) => debugPrint('[grassroots_bluetooth_layer] $msg'),
      );
      _wireLedgerTimer ??= Timer.periodic(
          const Duration(seconds: 10), (_) => _drainWireLedger());

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
    _wantAdvertise = shouldAdvertise;
    _wantScan = shouldScan;
    _advertisingConfirmed = false;
    _scanConfirmed = false;
    debugPrint('BLE start: roleMode=$mode '
        'advertise=$shouldAdvertise scan=$shouldScan');

    // Advertising and scanning are independent; failure in one must not
    // prevent the other. Track whether at least one succeeded — if both
    // fail (e.g. adapter still off), stay in `ready` so the next
    // adapter-on event re-invokes `start()`.
    try {
      if (shouldAdvertise) {
        try {
          await _ble.startAdvertising(
            serviceUuid: identity.bleServiceUuid,
            characteristicUuid: _grassrootsCharacteristicUuid,
            localName: localName,
            bondless: true,
          );
          _advertisedSlot = GrassrootsIdentity.currentBleSlot();
          _advertiseLocalName = localName;
          _startSlotTimer();
        } catch (e) {
          debugPrint('Failed to start advertising: $e');
          // Undiscoverable: no inbound legs, no peripheral role, for as long
          // as this persists — while the transport still reports active
          // because the scan side came up.
          //
          // The reason is the whole value of this record. A run that ends
          // with nothing on the air is diagnosed from here or not at all,
          // and "the advertiser refused" without saying what it said leaves
          // the one question that matters unanswered.
          if (_tracing) {
            unawaited(trace!.log({
              'type': 'link',
              't': DateTime.now().millisecondsSinceEpoch,
              'event': 'advertiseFailed',
              'transport': 'ble',
              'reason': e is PlatformException
                  ? '${e.code}: ${e.message ?? ''}'.trim()
                  : e.toString(),
            }));
          }
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
        _scanTargetUuids = _scanTargets();
        if (await _startContinuousScan()) {
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

      // Debug link-diagnostics poll: runs for every role mode; each tick is
      // a no-op unless the settings toggle is on.
      _armLinkSnapshotPoll();

      // No promotion here: the calls above returning means the requests were
      // accepted. `active` is stamped by the confirmation handlers once the
      // controller says the requested roles are on the air.
      _promoteIfBooted();
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

  void _armLinkSnapshotPoll() {
    _linkSnapshotTimer?.cancel();
    _linkSnapshotTimer = Timer.periodic(
      _linkSnapshotInterval,
      (_) {
        _pruneNeverReadyPaths();
        unawaited(_pollLinkSnapshot());
      },
    );
  }

  /// Project the plugin's OS-level link snapshot into Redux — only while the
  /// diagnostics toggle is on (a fresh empty snapshot is dispatched once when
  /// the toggle turns off, so stale links never linger in the UI).
  Future<void> _pollLinkSnapshot() async {
    if (_stopped) return;
    if (!store.state.settings.showLinkDiagnostics) {
      if (store.state.transports.bleLinks.isNotEmpty) {
        store.dispatch(BleLinkSnapshotAction(const []));
      }
      return;
    }
    try {
      final links = await _ble.linkSnapshot();
      store.dispatch(BleLinkSnapshotAction([
        for (final l in links)
          BleLinkDiagnostic(
            address: l.address,
            clientRole: l.clientRole,
            serverRole: l.serverRole,
          ),
      ]));
    } catch (e) {
      debugPrint('[ble] link snapshot failed: $e');
    }
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
    _scanTargetUuids = _scanTargets();
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
    final restarted = await _startContinuousScan();
    // The silence window that triggered this was a discovery-dead interval —
    // indistinguishable in the trace from an empty room until now.
    if (_tracing) {
      unawaited(trace!.log({
        'type': 'link',
        't': DateTime.now().millisecondsSinceEpoch,
        'event': 'scanRestart',
        'transport': 'ble',
        'silenceSec': scanSilenceRestart.inSeconds,
        'filtered': _scanTargetUuids.isNotEmpty,
        'ok': restarted,
      }));
    }
  }

  /// Whether this device refuses to meet peers it has not friended.
  bool get _closedTrust =>
      store.state.settings.coldCallTrustLevel == ColdCallTrustLevel.closed;

  /// Candidate service UUIDs of every accepted friend — the scan filter that
  /// makes a closed-trust node BLIND to strangers.
  ///
  /// The service UUID is a pure function of the peer's public key
  /// ([GrassrootsIdentity.deriveServiceUuidForSlot]), so we can compute what
  /// each friend will be advertising without ever having met them this slot.
  /// Handing that list to the OS moves the filter into the scanner — hardware
  /// filters on Android, and the only form of scanning iOS honours in the
  /// background — so a stranger's advertisement never reaches us at all,
  /// rather than reaching us and being discarded a layer up.
  ///
  /// This is the discovery half of closed trust; the dial half already lives
  /// in [connectToDevice]. What it deliberately does NOT do is stop us
  /// relaying: the outer envelope carries only a recipient, so packets that
  /// cross a friend link are still forwarded and still buffered for ANY
  /// recipient. Closed trust narrows which LINKS traffic may travel over, not
  /// whose traffic it is.
  Set<String> _friendScanTargets() {
    final targets = <String>{};
    for (final friend in _peersState.friends) {
      targets.addAll(GrassrootsIdentity.candidateServiceUuids(
        friend.publicKey,
      ));
    }
    return targets;
  }

  /// The UUIDs the scanner should filter on right now: the friend set when
  /// trust is closed, plus any stuck reverse legs in either mode.
  ///
  /// In closed trust a stuck reverse leg is necessarily a friend already, so
  /// the union costs nothing; in open trust the friend set is omitted, because
  /// filtering to friends is exactly the behaviour open trust exists to
  /// refuse — an open node must keep meeting strangers.
  Set<String> _scanTargets() {
    final targets = <String>{
      if (_closedTrust) ..._friendScanTargets(),
      ..._reverseLegScanTargets(),
    };
    return targets;
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
    // Closed trust with nobody to look for. An unfiltered prefix scan here
    // would surface precisely the strangers closed trust exists to ignore, so
    // the honest thing is to not scan at all: there is no peer on the air we
    // are willing to link with. Advertising continues, so a friend added later
    // can still find US, and the watchdog's recompute picks them up.
    if (_closedTrust && _scanTargetUuids.isEmpty) {
      try {
        await _ble.stopScan();
      } catch (_) {}
      debugPrint(
        '[ble] scan: closed trust with no friends — not scanning '
        '(an unfiltered scan would surface only strangers)',
      );
      return false;
    }
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
          'candidate UUID(s) — '
          '${_closedTrust ? 'closed trust (friends only)' : 'stuck reverse-leg peers'}',
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
    // Reverse-leg targets are an auto-mode concern, but the closed-trust
    // friend filter is not: it must hold in every role mode that scans, or a
    // central-only node would quietly keep meeting strangers.
    if (!_closedTrust &&
        store.state.settings.bleRoleMode != BleRoleMode.auto) {
      return;
    }
    final targets = _scanTargets();
    if (setEquals(targets, _scanTargetUuids)) return;
    _scanTargetUuids = targets;
    if (await _startContinuousScan()) {
      _lastAdvertisementAt = DateTime.now();
    }
  }

  /// Apply a runtime trust-level change (open ⇄ closed).
  ///
  /// Closing must take effect at once — the whole point is to stop meeting
  /// strangers — and opening must too, or the node would stay blind to
  /// everyone it has not already friended. Live links are left alone: a
  /// friend link survives either way, and a stranger link that predates the
  /// switch is torn down by the layer that refuses to ANNOUNCE to it, not
  /// here.
  Future<void> applyTrustModeChange() async {
    if (state != TransportState.active) return;
    _scanTargetUuids = _scanTargets();
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
  Future<void> stop({bool keepAdvertiser = false}) async {
    _stopped = true;
    // A kept advertiser stays confirmed: its set is still on the air and the
    // plugin re-emits the state on the next start.
    if (!keepAdvertiser) _advertisingConfirmed = false;
    _scanConfirmed = false;
    _scanWatchdog?.cancel();
    _scanWatchdog = null;
    _linkSnapshotTimer?.cancel();
    _linkSnapshotTimer = null;
    if (!keepAdvertiser) {
      _stopSlotTimer();
      _advertisedSlot = null;
    }
    try {
      await _ble.stopScan();
    } catch (_) {}
    if (!keepAdvertiser) {
      try {
        await _ble.stopAdvertising();
      } catch (_) {}
    }

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

  /// Whether this leg can carry [data] intact, naming it when it cannot.
  ///
  /// These writes are WRITE_TYPE_NO_RESPONSE, so the stack cannot promote an
  /// oversized payload to a GATT long write — it clamps at `MTU - 3` and the
  /// receiver gets a prefix it cannot parse (`bleRx`/`deserialize` on the far
  /// side, with nothing on this one). Every regular packet is sized against
  /// the floor MTU by FragmentHandler, so anything over is a budgeting bug in
  /// the code that built it, not a property of the peer. Logged with the
  /// negotiated MTU because a peer that settled below the floor is a
  /// different fault from a payload that was mis-sized.
  ///
  /// False stops the write, so the caller can try the pair's other leg. The
  /// refusal is still recorded, so how often this happens and to whom stays
  /// visible in the run.
  bool _checkWritable(Uint8List data, ble.BlePath path, String site) {
    final usable = path.mtu - 3;
    if (data.length <= usable) return true;
    debugPrint('[ble-mtu] REFUSED $site ${data.length}B > ${usable}B usable '
        '(mtu ${path.mtu}) on ${path.pathId} — not written; the caller falls '
        'back to the pair\'s other leg');
    _traceDrop(site, 'oversized', {
      'path': path.pathId,
      'bytes': data.length,
      'usable': usable,
      'mtu': path.mtu,
    });
    return false;
  }

  /// The neighbour-fragment chunk budget for [deviceId], sized to that leg's
  /// DISCOVERED MTU: `(mtu - 3) - packetHeader - frameHeader - 8`, floored so a
  /// pre-negotiation default MTU still makes progress. The frame header is the
  /// cleartext [SecureFrame] carrying the fragment (ANNOUNCE / handshake).
  ///
  /// A packet whose payload is one such chunk serialises to at most
  /// `mtu - 3 - 8` on the wire — the 8-byte margin absorbs a leg that settled
  /// a little below the value we sized against, so a fragment is at worst cut
  /// slightly small, never truncated. With no ready path (device gone, or the
  /// MTU not yet reported) it returns the floor: fragmenting small is safe.
  int usableFragmentBudgetFor(String deviceId) {
    const floor = 32;
    final path = _paths[deviceId];
    final mtu = (path != null && _isReady(path)) ? path.mtu : _defaultAttMtu;
    final budget = (mtu - 3) -
        GrassrootsPacket.headerSize -
        SecureFrame.headerSize -
        8;
    return budget < floor ? floor : budget;
  }

  @override
  Future<bool> sendToPeer(String peerId, Uint8List data) async {
    final path = _paths[peerId];
    if (path == null || !_isReady(path)) {
      // A refused write gets a record: an unlogged false is the silent-est send
      // failure in the codebase. Sync conveyances and directed sends vanish
      // here when a path dies mid-operation.
      _traceDrop('bleSend', path == null ? 'noPath' : 'notReady',
          {'path': peerId});
      return false;
    }
    return _writeToPeer(path, data, 'bleSend');
  }

  /// Write [data] on [path], and if that write never got in, write it on the
  /// pair's OTHER leg.
  ///
  /// This is the redundancy the second leg is kept for, and it is not the
  /// double-send the one-leg-per-flood rule forbids: the fallback runs only
  /// after a throw, and a throw means the bytes never reached the controller.
  /// Both platforms fail *before* transmitting — Android's `sendCentral`
  /// throws while validating the path and `sendPeripheral` when
  /// `notifyCharacteristicChanged` refuses the buffer, iOS on `valueTooLarge`
  /// or a full pending queue — so the packet cannot end up on the air twice.
  ///
  /// Until now a refused write was final: it was traced and the packet was
  /// gone for that peer, with no retry anywhere in the stack. The peripheral
  /// leg has no queue at all (the notify goes straight at the stack), so it is
  /// the leg that refuses under load, and it is also the leg the flood
  /// prefers.
  Future<bool> _writeToPeer(
      ble.BlePath path, Uint8List data, String site) async {
    if (await _writeLeg(path, data, site)) return true;
    final other = otherLegFor(
      path: path,
      ready: _readyPaths,
      pubkeyFor: getPubkeyForPeerId,
      bytes: data.length,
    );
    // Nothing else to try, and the leg we have is still at the ATT default:
    // the write is not too big for the link, only for the link SO FAR. Hold
    // it until the MTU lands rather than spending the packet on a leg that
    // cannot carry it.
    if (other == null && path.mtu <= _defaultAttMtu) {
      return _deferUntilMtu(path, data, site);
    }
    if (other == null) return false;
    if (!await _writeLeg(other, data, '$site:otherLeg')) return false;
    _traceRetry(site, {'path': path.pathId, 'via': other.pathId});
    return true;
  }

  /// Hold [data] until [path] reports a bigger MTU, then write it.
  ///
  /// Reports failure to the caller IMMEDIATELY -- the same answer a refused
  /// write gave before deferral existed -- and flushes in the background when
  /// the MTU lands. Callers iterate peers serially (the announce loop, the
  /// flood), so awaiting the MTU here would let one cold leg hold up every
  /// peer behind it for the full deadline; nothing upstream acts on the
  /// success either, since a buffered packet leaves custody only on ACK. The
  /// deadline is the safety valve: a leg whose peer never negotiates still
  /// gets the attempt, refused exactly as before, so deferral can only turn
  /// a certain loss into a chance of delivery.
  bool _deferUntilMtu(ble.BlePath path, Uint8List data, String site) {
    final pending = _DeferredWrite(data, site);
    _awaitingMtu.putIfAbsent(path.pathId, () => []).add(pending);
    _traceDrop(site, 'awaitingMtu', {
      'path': path.pathId,
      'bytes': data.length,
      'mtu': path.mtu,
    });
    pending.deadline = Timer(_mtuWait, () {
      if (_awaitingMtu[path.pathId]?.remove(pending) ?? false) {
        unawaited(_flushDeferred(path.pathId, [pending], timedOut: true));
      }
    });
    return false;
  }

  /// Send everything that was waiting on [pathId] now that its leg can carry
  /// it. A path that dropped instead of negotiating loses its writes — the
  /// caller was already told they failed, and the DTN buffer is what carries
  /// a packet past a dead leg, not this queue.
  Future<void> _flushDeferred(String pathId, List<_DeferredWrite> waiting,
      {bool timedOut = false}) async {
    final path = _paths[pathId];
    for (final w in waiting) {
      w.deadline?.cancel();
      if (path == null || !_isReady(path)) continue;
      if (timedOut) {
        debugPrint('[ble-mtu] ${w.site} waited ${_mtuWait.inSeconds}s on '
            '$pathId without an MTU — sending anyway');
      }
      await _writeLeg(path, w.data, w.site);
    }
  }

  /// Release anything held for [path] once its MTU rises above the default.
  void _releaseOnMtu(ble.BlePath path) {
    if (path.mtu <= _defaultAttMtu) return;
    final waiting = _awaitingMtu.remove(path.pathId);
    if (waiting == null || waiting.isEmpty) return;
    unawaited(_flushDeferred(path.pathId, waiting));
  }

  /// Evict a dead address and dial the identity's newest other sighting now.
  ///
  /// The measured cause of a fast-failing dial is an address that no longer
  /// exists: every advertising restart gives the peer a fresh random address,
  /// and the first post-bounce sighting can still be the dying pre-restart
  /// advertisement — the CONNECT_IND goes out and nobody on the air owns the
  /// address (HCI 0x3E under the opaque 133). The cooldown answers an
  /// alive-and-refusing address; a dead one deserves the opposite. Drop the
  /// entry and dial the same identity's newest OTHER sighting immediately —
  /// newest strictly after the failed entry's last sighting, so the chase
  /// only ever moves toward information that arrived after the address we
  /// just proved dead. The cooldown record for the failed address stays
  /// armed: if it re-advertises (alive after all), its re-added entry is
  /// still rate-limited, so nothing hammers a refusing peer.
  void _chaseNewerAddress(String failedPathId) {
    if (_stopped) return;
    final failed = _peersState.discoveredBlePeers[failedPathId];
    if (failed == null) return;
    store.dispatch(BleDeviceRemovedAction(failedPathId));
    final uuid = failed.serviceUuid;
    if (uuid == null) return;
    // The identity's freshest OTHER sighting, full stop. The original
    // strictly-newer-than-the-failure requirement assumed the dead address
    // predated the live one; under mid-window rotation the peer retires
    // addresses repeatedly and the freshest sighting is simply the best
    // information there is. Eviction plus the cooldown still bound the
    // chain: every failure removes an address, so the chase always makes
    // progress toward the live one.
    DiscoveredPeerState? newest;
    for (final e in _peersState.discoveredBlePeersList) {
      if (e.transportId == failedPathId) continue;
      if (e.serviceUuid != uuid) continue;
      if (e.isConnected || e.isConnecting) continue;
      if (newest == null || e.lastSeen.isAfter(newest.lastSeen)) newest = e;
    }
    if (newest == null) return;
    if (_tracing) {
      unawaited(trace!.log({
        'type': 'link',
        't': DateTime.now().millisecondsSinceEpoch,
        'event': 'dialChase',
        'transport': 'ble',
        'path': failedPathId,
        'to': newest.transportId,
      }));
    }
    unawaited(connectToDevice(newest.transportId, via: 'chase'));
  }

  /// One write attempt on one leg. False means the bytes did not get in.
  Future<bool> _writeLeg(
      ble.BlePath path, Uint8List data, String site) async {
    try {
      // Do not air a write this leg would truncate. The peer would get a
      // prefix it must discard, the airtime is spent either way, and
      // reporting it as sent hides the one remedy that exists: a pair holds
      // two legs, they negotiate their MTUs separately, and the other may
      // carry what this one cannot.
      if (!_checkWritable(data, path, site)) return false;
      await _ble.send(path.pathId, data);
      if (_tracing) _wireLedger.onTx(data);
      return true;
    } catch (e) {
      debugPrint('send() failed for ${path.pathId}: $e');
      _traceDrop(site, 'writeFailed', {'path': path.pathId});
      return false;
    }
  }

  /// The same peer's other GATT leg, when the pair has converged, that leg is
  /// ready, and [bytes] fits its MTU.
  ///
  /// The MTU test is not paranoia: the two legs negotiate separately (and on
  /// iOS the notify limit is a per-central property), so a packet sized for
  /// one leg can exceed the other. Retrying onto a leg that will truncate it
  /// puts an unparseable write on the air and reports success.
  ///
  /// An unidentified path has no known pair and gets no fallback: without a
  /// pubkey there is no way to tell the pair's other leg from a stranger's.
  @visibleForTesting
  static ble.BlePath? otherLegFor({
    required ble.BlePath path,
    required Iterable<ble.BlePath> ready,
    required Uint8List? Function(String pathId) pubkeyFor,
    required int bytes,
  }) {
    final pubkey = pubkeyFor(path.pathId);
    if (pubkey == null) return null;
    final key = _pubkeyHex(pubkey);
    for (final other in ready) {
      if (other.pathId == path.pathId) continue;
      // Same role is not the other leg — it is another connection in the same
      // direction, which a converged pair does not have.
      if (other.role == path.role) continue;
      final otherKey = pubkeyFor(other.pathId);
      if (otherKey == null || _pubkeyHex(otherKey) != key) continue;
      if (bytes > other.mtu - 3) continue;
      return other;
    }
    return null;
  }

  @override
  Future<int> broadcast(Uint8List data, {Set<String>? excludePeerIds}) async {
    // Sort by RSSI descending so the strongest signals get the data first.
    // Paths without a known RSSI (peripheral-role on iOS/Android, where the
    // OS doesn't expose remote signal strength) sort last via a very-weak
    // fallback so they still receive the broadcast.
    final ready = _readyPaths.toList()
      ..sort((a, b) => (b.rssi ?? -100).compareTo(a.rssi ?? -100));
    final targets = selectBroadcastTargets(
      ready: ready,
      pubkeyFor: getPubkeyForPeerId,
      excludePeerIds: excludePeerIds,
    );
    var sent = 0;
    for (final path in targets) {
      // A refused write falls back to the pair's other leg rather than
      // dropping the packet for that neighbour: the flood chose ONE of the
      // two legs, and the one it did not choose is still connected.
      if (await _writeToPeer(path, data, 'bleBroadcast')) sent++;
    }
    return sent;
  }

  /// DEBUG/TESTBED ONLY. Which GATT leg a raw-throughput blob rides.
  ///
  /// `notify` = our peripheral leg, `write` = our central leg, `stripe` =
  /// alternate by [seq] parity — the arm that asks whether a converged
  /// pair's two legs are two usable pipes for bulk transfer.
  static ble.BlePath? pickRawPath({
    required Iterable<ble.BlePath> ready,
    required Uint8List? Function(String pathId) pubkeyFor,
    required String peerHex,
    required String leg,
    required int seq,
  }) {
    ble.BlePath? peripheral;
    ble.BlePath? central;
    for (final path in ready) {
      final pubkey = pubkeyFor(path.pathId);
      if (pubkey == null || _pubkeyHex(pubkey) != peerHex) continue;
      if (path.role == ble.BleRole.peripheral) {
        peripheral ??= path;
      } else {
        central ??= path;
      }
    }
    return switch (leg) {
      'notify' => peripheral,
      'write' => central,
      // Stripe wants BOTH pipes; with one leg missing it degrades to the
      // one that exists rather than stalling every other blob.
      'stripe' => seq.isEven
          ? (peripheral ?? central)
          : (central ?? peripheral),
      _ => null,
    };
  }

  /// DEBUG/TESTBED ONLY. Send one raw blob to [peerHex] over [leg], sized to
  /// the chosen path's negotiated MTU (ATT payload = MTU - 3). Returns the
  /// blob size, or null when the leg does not exist / is not ready.
  Future<int?> sendRawBlob({
    required String peerHex,
    required String leg,
    required int seq,
    int sizeDelta = 0,
  }) async {
    final path = pickRawPath(
      ready: _readyPaths,
      pubkeyFor: getPubkeyForPeerId,
      peerHex: peerHex,
      leg: leg,
      seq: seq,
    );
    if (path == null) return null;
    // `mtu - 3` is the ATT ceiling: one byte of opcode plus two of attribute
    // handle come out of every write. [sizeDelta] deliberately overshoots or
    // undershoots it — the ATT-ceiling probe's arm variable — so 0 writes at
    // the ceiling and +1 one byte past it. Recorded with the negotiated MTU
    // rather than the requested one, because that is the number the fragment
    // budget is actually betting on.
    final size = (path.mtu - 3 + sizeDelta).clamp(1, 512);
    if (_tracing) {
      unawaited(trace!.log({
        'type': 'wire',
        't': DateTime.now().millisecondsSinceEpoch,
        'event': 'rawTx',
        'mtu': path.mtu,
        'sizeDelta': sizeDelta,
        'len': size,
        'leg': leg,
      }));
    }
    final blob = Uint8List(size);
    blob[0] = rawPacketType;
    // Fill so the radio cannot run-length anything (paranoia; BLE does not
    // compress, but a constant fill would make that assumption silent).
    for (var i = 1; i < size; i++) {
      blob[i] = (seq + i) & 0xff;
    }
    try {
      await _ble.send(path.pathId, blob);
      if (_tracing) _wireLedger.onTx(blob);
      return size;
    } catch (e) {
      debugPrint('raw blob send failed on ${path.pathId}: $e');
      return null;
    }
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
  /// Central-role paths need nothing here: the peer opens its own reverse leg.
  void onPeerIdentified(String pathId, Uint8List pubkey) {
    final path = _paths[pathId];
    if (path == null) return;
    final role = _roleFromPathId(pathId);
    // Stamp the IDENTIFIED stage for every path, both roles, before any of the
    // reverse-leg early-outs below — this is a measurement fact about the
    // link, not a step in the reverse-leg policy, and it is the stage that
    // separates "the link came up" from "we know who is on the other end".
    // Without it a run cannot tell a dial that failed from one that connected
    // to a peer which never announced.
    _peerHexByPath[pathId] =
        pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    if (role != null) _traceLink('identified', path, role);
    if (role != null) _dropDuplicateLegFor(pathId, role);
    if (!_isReady(path)) return;
    if (role != BleRole.peripheral) return;

    if (store.state.settings.bleRoleMode != BleRoleMode.auto) return;

    // Already have the central direction (live or mid-handshake)? Nothing
    // to do — without this, every periodic ANNOUNCE over the peripheral leg
    // of a healthy dual-role pair would re-run the reverse-leg attempt.
    final pair = _pairViewFor(GrassrootsIdentity.deriveServiceUuidForSlot(
        pubkey, GrassrootsIdentity.currentBleSlot()));
    if (pair.liveCentralPathId != null) return;
    if (pair.centralInFlight) {
      // Our inbound leg from this identity is READY, so if our own dial
      // toward them is still stuck in `connecting`, it has provably lost the
      // race — the measured wedge holds `connectGatt` for its full 20 s
      // timeout, and the one-central-per-identity rule then keeps the
      // reverse leg shut the whole time. Tear the loser down and open the
      // reverse leg over the ACL that won. A dial past `connecting` is
      // 140 ms of GATT setup from ready and is left to finish.
      final wedged = pair.inFlightConnectingPathId;
      if (wedged == null) return;
      _cancellingDials.add(wedged);
      if (_tracing) {
        unawaited(trace!.log({
          'type': 'link',
          't': DateTime.now().millisecondsSinceEpoch,
          'event': 'wedgeCancel',
          'transport': 'ble',
          'path': wedged,
          'via': pathId,
        }));
      }
      unawaited(disconnectDevice(wedged, forget: false));
    }

    unawaited(_openReverseLeg(pathId, pubkey));
  }

  /// Open the reverse (central) leg toward a peer whose inbound peripheral
  /// leg [peripheralPathId] just became attributable.
  ///
  /// Preferred target: the inbound link's OWN remote address. Connecting to a
  /// device we already share an ACL link with attaches our GATT client over
  /// that existing link — no second ACL is created. This matters because a
  /// second ACL between the same two radios is refused by spec-conformant
  /// stacks: on Android 16 every dial to the peer's advertised MAC fast-fails
  /// GATT 133 while the first link exists, though Android 8.1 pairs tolerate
  /// dual ACLs. The iOS refusal to open a second link is plausibly the same
  /// LL rule.
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
    _traceReverseDial('overAcl', 'central:$remoteId');
    if (await connectToDevice('central:$remoteId',
        serviceUuidOverride: gattUuid, via: 'reverseAcl')) {
      // Started is not survived: if this dial dies before ready, the
      // terminal-state handler retries once at a fresh advertised MAC.
      _reverseDialPending
          .removeWhere((pathId, _) => !_paths.containsKey(pathId));
      _reverseDialPending['central:$remoteId'] = pubkey;
      return;
    }

    // The over-ACL dial did not start (choke-point guard or a stack that
    // cannot connect to a connection address) — fall back to a fresh ACL
    // toward the scanned advertising MAC.
    if (_dialAdvertisedFallback(pubkey)) return;

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

  /// Dial the peer's freshest scanned advertising MAC, looked up at call
  /// time — under address rotation the entry that existed when the reverse
  /// leg was first attempted may already name a dead address. True when a
  /// dial was started.
  bool _dialAdvertisedFallback(Uint8List pubkey) {
    for (final uuid in GrassrootsIdentity.candidateServiceUuids(pubkey)) {
      for (final dp in _peersState.getDiscoveredBlePeersByServiceUuid(uuid)) {
        if (dp.isConnected || dp.isConnecting) continue;
        debugPrint('[ble] reverse leg: dialing advertised '
            '${dp.transportId} instead.');
        _traceReverseDial('advertised', dp.transportId);
        unawaited(connectToDevice(dp.transportId, via: 'reverseAdv'));
        return true;
      }
    }
    return false;
  }

  /// One `reverseDial` link record per attempt: which method carried it —
  /// `overAcl` (attach to the inbound link's address) or `advertised` (fresh
  /// ACL to a scanned MAC). The run's convergence story is unreadable
  /// without these: a pair that settled fast over the ACL and one that
  /// burned an election cycle both end at `connected`.
  void _traceReverseDial(String method, String pathId) {
    if (!_tracing) return;
    unawaited(trace!.log({
      'type': 'link',
      't': DateTime.now().millisecondsSinceEpoch,
      'event': 'reverseDial',
      'transport': 'ble',
      'method': method,
      'path': pathId,
    }));
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

  /// Pick the paths a flood is actually written to: ONE leg per peer
  /// identity. A converged pair holds two GATT legs, so writing every ready
  /// path put the same packet on the air twice for the same peer — pure
  /// waste, since the receiver's packetId bloom drops the second copy.
  ///
  /// The kept leg is our PERIPHERAL one where a pair has both (we notify the
  /// peer's central): a notification is unacknowledged at ATT level and
  /// several can pack into one connection interval, whereas the central leg
  /// writes to the peer's characteristic. The other leg stays connected — it
  /// is the pair's other direction and its fallback — it just does not carry
  /// a duplicate of the same packet.
  ///
  /// Legs whose identity is not yet known cannot be deduplicated and are all
  /// kept: dropping them would silence a pair that has connected but not yet
  /// exchanged ANNOUNCE.
  ///
  /// [excludePeerIds] is resolved to IDENTITIES for the same reason. The
  /// relay excludes the path a packet arrived on so it is not echoed back at
  /// its sender, but a pathId names only ONE leg — without this the reverse
  /// leg of that same pair echoed it straight back.
  ///
  /// Input order is preserved (callers sort by RSSI), and identified targets
  /// precede unidentified ones.
  @visibleForTesting
  static List<ble.BlePath> selectBroadcastTargets({
    required Iterable<ble.BlePath> ready,
    required Uint8List? Function(String pathId) pubkeyFor,
    Set<String>? excludePeerIds,
  }) {
    final excludedKeys = <String>{};
    for (final peerId in excludePeerIds ?? const <String>{}) {
      final pubkey = pubkeyFor(peerId);
      if (pubkey != null) excludedKeys.add(_pubkeyHex(pubkey));
    }
    final chosen = <String, ble.BlePath>{};
    final unidentified = <ble.BlePath>[];
    for (final path in ready) {
      final pubkey = pubkeyFor(path.pathId);
      if (pubkey == null) {
        if (excludePeerIds == null || !excludePeerIds.contains(path.pathId)) {
          unidentified.add(path);
        }
        continue;
      }
      final key = _pubkeyHex(pubkey);
      if (excludedKeys.contains(key)) continue;
      final existing = chosen[key];
      if (existing == null ||
          (existing.role != ble.BleRole.peripheral &&
              path.role == ble.BleRole.peripheral)) {
        chosen[key] = path;
      }
    }
    return [...chosen.values, ...unidentified];
  }

  static String _pubkeyHex(Uint8List pubkey) =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

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
  Future<void> dispose({bool keepAdvertiser = false}) async {
    await stop(keepAdvertiser: keepAdvertiser);
    // Cancel every held write's deadline before anything closes: a timer
    // firing after dispose would flush into a transport that no longer
    // exists.
    for (final waiting in _awaitingMtu.values) {
      for (final w in waiting) {
        w.deadline?.cancel();
      }
    }
    _awaitingMtu.clear();
    _wireLedgerTimer?.cancel();
    _wireLedgerTimer = null;
    await _adapterSub?.cancel();
    await _advertisementSub?.cancel();
    await _advertisingStateSub?.cancel();
    await _scanStateSub?.cancel();
    await _pathSub?.cancel();
    await _payloadSub?.cancel();
    await _logSub?.cancel();
    try {
      await _ble.dispose(keepAdvertiser: keepAdvertiser);
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
    int? sightingRssi,
    String via = 'sighting',
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
      _traceDialSkip(pathId, 'pairHasCentral');
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
    // BLE address rotation produces a fresh pathId every ~30s for the same
    // peer. Cap the number of in-flight central dials so a chatty rotator
    // can't exhaust the BLE stack's connection slots. This cap is also the
    // dial grid's independent variable (see [maxInFlightCentralDials]) — no
    // dial is ever exempt from it.
    if (_inFlightCentralDials() >= maxInFlightCentralDials) {
      _traceDialSkip(pathId, 'dialCap');
      return false;
    }
    // Rate-limit redials of an address that just failed: the peer's next
    // advertisement after the cooldown re-arms it (see [_centralDialCooldown]).
    final failedAt = _centralDialFailedAt[pathId];
    if (failedAt != null) {
      if (DateTime.now().difference(failedAt) < _centralDialCooldown) {
        _traceDialSkip(pathId, 'cooldown');
        return false;
      }
      _centralDialFailedAt.remove(pathId);
    }

    if (_dialingNow.contains(pathId)) {
      _traceDialSkip(pathId, 'dialing');
      return false;
    }
    final remoteId = pathId.substring('central:'.length);
    _dialingNow.add(pathId);
    try {
      // Provenance: what evidence produced this dial. Every 133 postmortem
      // so far had to infer where the address came from; this states it —
      // the issuing path, the sighting's signal, and how old the discovery
      // entry was at the instant of dialing. An entry that is minutes old
      // or absent names the suspect outright.
      if (_tracing) {
        final now = DateTime.now();
        unawaited(trace!.log({
          'type': 'link',
          't': now.millisecondsSinceEpoch,
          'event': 'dialIssued',
          'transport': 'ble',
          'path': pathId,
          'via': via,
          if (sightingRssi != null) 'rssi': sightingRssi,
          if (discovered != null) ...{
            'entryAgeMs': now.difference(discovered.lastSeen).inMilliseconds,
            'firstSeenAgeMs':
                now.difference(discovered.discoveredAt).inMilliseconds,
            if (sightingRssi == null) 'rssi': discovered.rssi,
          } else
            'entry': 'absent',
        }));
      }

      await _ble.connect(
        remoteId: remoteId,
        // The peer's GATT service carries the same derived UUID it
        // advertises (design: advertisement and GATT service rotate
        // together), so the discovered UUID is the service to attach to.
        serviceUuid: serviceUuid,
        characteristicUuid: _grassrootsCharacteristicUuid,
        androidMtu: _requestedAndroidMtu,
        // Sized to the sighting's signal strength (see
        // [connectTimeoutForRssi]): the strong-signal deadlock breaks in
        // ~2 s, the weak-signal connect keeps its 20 s of legitimate
        // link-layer patience, and a dial with no reading stays patient.
        timeout: connectTimeoutForRssi(sightingRssi),
      );
      return true;
    } catch (e) {
      // The plugin throws synchronously only for invalid args / adapter off.
      // No path event will fire, so dispatch a failure action ourselves so
      // Redux doesn't show the peer stuck in `isConnecting` (which the
      // plugin would otherwise correct via a `failed` event).
      _dialingNow.remove(pathId);
      store.dispatch(BleDeviceConnectionFailedAction(pathId));
      return false;
    }
  }

  Future<void> disconnectDevice(String pathId, {bool forget = true}) async {
    final uuid = _peersState.getDiscoveredBlePeer(pathId)?.serviceUuid;
    if (uuid != null) _firstSightingAt[uuid.toLowerCase()] = DateTime.now();
    try {
      await _ble.disconnect(pathId, forget: forget);
    } catch (e) {
      debugPrint('disconnect() failed for $pathId: $e');
    }
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
      // The far side's counterpart to `bleSend`/`oversized`: a payload the
      // sender's stack clamped at `MTU - 3` arrives as a parseable-looking
      // prefix and dies here. Recording the LENGTH is what distinguishes a
      // truncation (a length that sits suspiciously at a usable-MTU
      // boundary, and a header whose declared size overruns what arrived)
      // from a corrupt or foreign packet — without it, every cause looks
      // identical in the drop table.
      final mtu = _paths[fromDeviceId]?.mtu;
      debugPrint('[ble-rx] deserialize failed after ${data.length}B'
          '${mtu == null ? '' : ' (peer mtu $mtu, usable ${mtu - 3})'}'
          ' from $fromDeviceId: $e');
      _traceDrop('bleRx', 'deserialize', {
        'path': fromDeviceId,
        'bytes': data.length,
        if (mtu != null) 'mtu': mtu,
        if (mtu != null) 'atUsableLimit': data.length == mtu - 3,
      });
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
      _advertisingConfirmed = false;
      _scanConfirmed = false;
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

  /// The plugin reports whether the radio is broadcasting our advertisement.
  ///
  /// A device that is not advertising still scans, still dials, and still
  /// reports the transport active, while no peer can discover it and no
  /// inbound peripheral leg can form. The scan side says nothing about it, so
  /// this is the only record that a run's missing links are a silent radio
  /// rather than an empty room.
  void _onScanStateChanged(ble.BleScanState scan) {
    store.dispatch(BleScanningChangedAction(scan.active));
    // A deliberate stop (no reason) is the watchdog's own restart or a mode
    // change — not a boot regression. Only a refused scan un-confirms.
    if (scan.active) {
      _scanConfirmed = true;
      _promoteIfBooted();
    } else if (scan.reason != null) {
      _scanConfirmed = false;
    }
    if (!_tracing) return;
    unawaited(trace!.log({
      'type': 'link',
      't': DateTime.now().millisecondsSinceEpoch,
      'event': 'scanState',
      'transport': 'ble',
      'active': scan.active,
      if (scan.reason != null) 'reason': scan.reason,
    }));
  }

  void _onAdvertisingStateChanged(ble.BleAdvertisingState advertising) {
    final reason = advertising.reason;
    final failure = advertising.failure;
    final txPower = advertising.txPowerLevel;
    store.dispatch(BleAdvertisingChangedAction(advertising.active));
    if (advertising.active) {
      _advertisingConfirmed = true;
      _promoteIfBooted();
    } else if (advertising.failure != null) {
      _advertisingConfirmed = false;
    }
    debugPrint(advertising.active
        ? 'BLE advertising active (tx level ${txPower ?? '?'})'
        : 'BLE advertising stopped'
            '${failure == null ? '' : ' (${failure.name}: $reason)'}');
    if (!_tracing) return;
    unawaited(trace!.log({
      'type': 'link',
      't': DateTime.now().millisecondsSinceEpoch,
      'event': 'advertisingState',
      'transport': 'ble',
      'active': advertising.active,
      // The power the radio GRANTED, not the one we asked for. Every RSSI a
      // peer reports for us is measured against this, so a trace that records
      // the signal without it cannot tell a quiet transmitter from a distant
      // one.
      if (txPower != null) 'txPowerLevel': txPower,
      if (failure != null) 'failure': failure.name,
      if (reason != null) 'reason': reason,
    }));
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
    _traceRssi(pathId, adv.rssi, source: 'adv');
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
      _traceDialSkip(pathId, 'centralActive');
      return;
    }
    // Only the deterministic initiator dials on sight; the other holds for
    // [_initiatorGrace] so the pair never has two dials in flight at once.
    // A mutual wedge cannot be signalled away — both stacks are deaf while
    // connecting — so it is prevented here rather than recovered from by
    // timeout downstream.
    if (!_isBleDialInitiator(serviceUuid) && !_graceElapsed(serviceUuid)) {
      _traceDialSkip(pathId, 'awaitingInitiator');
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
          serviceUuidOverride: serviceUuid, via: 'reverseAcl'));
      return;
    }

    unawaited(connectToDevice(pathId, sightingRssi: adv.rssi));
  }

  /// Connect leash for a dial triggered by a sighting at [rssi] dBm.
  ///
  /// The timeout's job is to tell a slowly-progressing connect from one that
  /// will never land, and the sighting's signal strength is the best prior
  /// there is: at −40 dBm a real connect lands in ~0.3 s and twenty seconds
  /// of patience is pure deadlock exposure (two phones dialing each other
  /// suspend their own inbound acceptance — measured as both sides burning
  /// the full leash in lockstep), while at −85 dBm seconds of link-layer
  /// retransmission are legitimate and an eager cut would censor exactly the
  /// marginal-range establishment the line experiment measures. Linear in dB
  /// between those anchors. The two directions of a pair read several dB
  /// apart and every sighting re-samples, so the two sides get different
  /// leashes for free — a symmetric deadlock breaks on the shorter one and
  /// cannot re-synchronize.
  ///
  /// Null (no reading — and every iOS dial, where CoreBluetooth may take
  /// 10–15 s legitimately) keeps the full leash.
  @visibleForTesting
  static Duration connectTimeoutForRssi(int? rssi) {
    if (rssi == null) return const Duration(seconds: 20);
    final frac = ((-40 - rssi) / 45).clamp(0.0, 1.0);
    return Duration(milliseconds: 2000 + (18000 * frac).round());
  }

  /// Which of the two peers dials first.
  ///
  /// "Central" is not a role either side can claim up front — it is what a
  /// peer BECOMES by dialing. Before any link exists the two are symmetric:
  /// both advertising, both scanning. So the pair needs a rule computable by
  /// both from what they already share, that returns opposite answers: the
  /// lower derived service UUID dials, the higher takes the inbound leg and
  /// reverse-dials over that ACL for its own central leg. Mirrors the UDP
  /// "smaller pubkey initiates" convention.
  ///
  /// Without it both sides dial on sight and collide, and a collision cannot
  /// be signalled away: two in-flight connectGatts leave the pair deaf, so
  /// the only exit is a timeout — measured at ~30% of windows costing 20 s
  /// each. Ordering prevents what no recovery can undo cheaply.
  bool _isBleDialInitiator(String peerServiceUuid) {
    return identity.bleServiceUuid.toLowerCase().compareTo(
              peerServiceUuid.toLowerCase(),
            ) <
        0;
  }

  /// Whether the initiator's uncontested window has passed, so the higher
  /// peer may dial anyway. Covers the initiator that never comes: a muted
  /// scanner, a failed dial, a peer that is only advertising.
  bool _graceElapsed(String serviceUuid) {
    final key = serviceUuid.toLowerCase();
    final since = _firstSightingAt[key];
    if (since == null) {
      _firstSightingAt[key] = DateTime.now();
      // Bound: entries only matter for one grace window.
      if (_firstSightingAt.length > 128) {
        final cutoff = DateTime.now().subtract(_initiatorGrace * 8);
        _firstSightingAt.removeWhere((_, t) => t.isBefore(cutoff));
      }
      return false;
    }
    return DateTime.now().difference(since) >= _initiatorGrace;
  }

  /// Cap on simultaneous in-flight central dials (paths `connecting` /
  /// `connected` / `subscribed` — a `ready` path has landed and no longer
  /// counts). Each `connectGatt` consumes a controller slot for ~5s on
  /// Android; too many parallel dials starve real connections.
  ///
  /// Settable, and that is the whole dial-grid experiment: the transport
  /// already dials greedily — every discovered peer, election-driven, topped
  /// up automatically as slots free — so the grid does not script bursts, it
  /// simply moves this bound to M for the step and counts what the ordinary
  /// dial path establishes. Nothing is ever exempt from it; an exemption
  /// would delete the independent variable. Testbed-only writer
  /// ([setDialParallelism]); [defaultMaxInFlightCentralDials] is what
  /// production runs at and what the runner restores when a run ends.
  int maxInFlightCentralDials = defaultMaxInFlightCentralDials;

  static const int defaultMaxInFlightCentralDials = 7;

  /// DEBUG/TESTBED ONLY. The dial grid's two step variables, stamped on
  /// every central establishment (see [_traceLink]) so an establishment is
  /// attributable to the cell it happened in. Null outside a dial-grid step.
  int? dialProbeMaxParallel;
  int? dialProbePopN;

  /// Central legs that reached GATT-usable since [resetEstablishmentCount],
  /// i.e. the establishments this device produced. Monotonic within a step;
  /// the runner snapshots it at the step boundary so the per-step count is a
  /// recorded fact rather than something the analyzer re-derives from link
  /// records.
  int get establishmentCount => _establishmentCount;
  int _establishmentCount = 0;

  void resetEstablishmentCount() => _establishmentCount = 0;

  /// DEBUG/TESTBED ONLY. Set the in-flight central dial cap for a dial-grid
  /// step, together with the step context the establishment records carry.
  /// A null [maxParallel] restores the production cap.
  void setDialParallelism({int? maxParallel, int? popN}) {
    maxInFlightCentralDials = maxParallel ?? defaultMaxInFlightCentralDials;
    dialProbeMaxParallel = maxParallel;
    dialProbePopN = popN;
  }

  int _inFlightCentralDials() {
    var count = 0;
    for (final p in _paths.values) {
      if (p.role != ble.BleRole.central) continue;
      if (_cancellingDials.contains(p.pathId)) continue;
      if (p.state == ble.BlePathState.connecting ||
          p.state == ble.BlePathState.connected ||
          p.state == ble.BlePathState.subscribed) {
        count++;
      }
    }
    return count;
  }

  /// After a central dial fails, that address is not redialed again until this
  /// cooldown elapses — then its next advertisement re-arms it.
  ///
  /// This replaces the one-strike address eviction. The scanner runs
  /// `allowDuplicates`, so the peer re-advertises the SAME address every scan
  /// tick; evicting it neither stopped the redials (the next tick re-added it)
  /// nor let a present peer settle — it churned the discovery entry (the
  /// nearby-list flicker) and, with each redial holding a native GATT slot for
  /// its full connect timeout, exhausted the table into a GATT-133 storm. An
  /// advertisement is proof the peer still answers at that address, so we DO
  /// retry the same address — but no faster than once per cooldown, and never
  /// more than [maxInFlightCentralDials] at once. A peer that is truly gone
  /// stops advertising and ages out of discovery, taking its cooldown with it.
  static const Duration _centralDialCooldown = Duration(seconds: 3);
  final Map<String, DateTime> _centralDialFailedAt = {};

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
    // The identity this path was PROVEN to belong to, learned from its
    // ANNOUNCE. This is the rotation-stable match and it outranks the two
    // heuristics below, which both read caches that expire on their own
    // schedule: the discovery entry can be pruned while its link is still
    // up, and once it is, a live leg becomes invisible here — `centralActive`
    // reads false and the peer is dialed a second time. That is how
    // same-role duplicate legs accumulate despite this suppression.
    final identityHex = identified == null
        ? null
        : identified.publicKey
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
    var inFlight = false;
    String? inFlightConnecting;
    for (final p in _paths.values) {
      if (p.role != ble.BleRole.central) continue;
      // A dial being cancelled is already lost: counting it would hold the
      // reverse leg shut for exactly the window the cancel exists to skip.
      if (_cancellingDials.contains(p.pathId)) continue;
      final du = _peersState
          .getDiscoveredBlePeer(p.pathId)
          ?.serviceUuid
          ?.toLowerCase();
      final matchesByUuid = du != null && candidates.contains(du);
      final matchesByRemoteId = peripheralRemoteId != null &&
          p.pathId.substring('central:'.length) == peripheralRemoteId;
      final matchesByIdentity =
          identityHex != null && _peerHexByPath[p.pathId] == identityHex;
      if (!matchesByUuid && !matchesByRemoteId && !matchesByIdentity) continue;
      if (_isReady(p)) {
        liveCentral ??= p.pathId;
      } else if (p.state == ble.BlePathState.connecting) {
        inFlight = true;
        inFlightConnecting ??= p.pathId;
      } else if (p.state == ble.BlePathState.connected ||
          p.state == ble.BlePathState.subscribed) {
        inFlight = true;
      }
    }

    return _PairView(
      liveCentralPathId: liveCentral,
      centralInFlight: inFlight,
      inFlightConnectingPathId: inFlightConnecting,
      livePeripheralPathId: livePeripheralPathId,
    );
  }

  void _onPathChanged(ble.BlePath path) {
    _dialingNow.remove(path.pathId);
    var wasCancelledDial = false;
    if (path.state == ble.BlePathState.failed ||
        path.state == ble.BlePathState.disconnected ||
        path.state == ble.BlePathState.stale) {
      wasCancelledDial = _cancellingDials.remove(path.pathId);
    }
    final previous = _paths[path.pathId];
    _paths[path.pathId] = path;
    _releaseOnMtu(path);

    // Stamp when a path first became live-but-not-ready, so [_reapStuck] can
    // tell a slow handshake from one that will never finish. FIRST moment
    // only — re-stamping on every event would make a path that keeps emitting
    // look perpetually fresh and never age out.
    if (path.state == ble.BlePathState.connecting ||
        path.state == ble.BlePathState.connected ||
        path.state == ble.BlePathState.subscribed) {
      _notReadySince.putIfAbsent(path.pathId, DateTime.now);
    }

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
        // Not yet sendable — wait for `ready`. Stamped for the trace all the
        // same: this is the raw GATT link coming up, BEFORE service
        // discovery / subscribe / MTU complete (the `connected` link stage
        // is only stamped at `ready`). The gap between this stamp and the
        // `connected` one is exactly where parallel central dials serialize
        // on the stack, which is what the dial-probe analysis measures.
        // Upward transitions only — a path drifting ready→subscribed is a
        // degradation, not a second link formation.
        if (previous == null ||
            previous.state == ble.BlePathState.discovered ||
            previous.state == ble.BlePathState.connecting) {
          // The link is UP. This is the establishment the dial grid counts —
          // it is the outcome a dial produces. Identity and the Noise session
          // are later, separate stages that can each fail on their own without
          // unmaking the fact that this link established.
          if (role == BleRole.central) _establishmentCount++;
          _traceLink('gattConnected', path, role);
        }
        break;
      case ble.BlePathState.ready:
        _notReadySince.remove(path.pathId);
        // A successful connect clears any dial-failure cooldown for this path.
        _centralDialFailedAt.remove(path.pathId);
        if (previous?.state != ble.BlePathState.ready) {
          store.dispatch(BleDeviceConnectedAction(path.pathId));
          // `ready` is its OWN stage (GATT-usable: identified, MTU negotiated,
          // subscribed). It is not the establishment — that was counted when
          // the link came up — so nothing increments here.
          _traceLink('connected', path, role);
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
          _reverseDialPending.remove(path.pathId);
        } else if (path.rssi != null) {
          // ready → ready re-emit: the plugin's periodic connected-RSSI poll
          // (or an MTU update). Sample it for the evaluation trace.
          _traceRssi(path.pathId, path.rssi!, source: 'conn', role: role.name);
        }
        break;
      case ble.BlePathState.failed:
      case ble.BlePathState.disconnected:
      case ble.BlePathState.stale:
        // A reverse dial that started and died before ready: retry ONCE at
        // the peer's freshly advertised MAC. Without this the pair waits for
        // the next advertisement election, and that wait — not GATT setup,
        // not the handshake — was where convergence time went.
        final reversePeer = _reverseDialPending.remove(path.pathId);
        if (reversePeer != null && !_stopped) {
          if (!_dialAdvertisedFallback(reversePeer)) {
            unawaited(_applyScanTargets());
          }
        }
        if (path.state == ble.BlePathState.failed &&
            path.role == ble.BleRole.central) {
          // Rate-limit the redial instead of evicting the address. A failed
          // connectGatt holds one of Android's ~32 native GATT slots for its
          // full connect timeout, so redialing a failing address once per scan
          // tick exhausts the table into a GATT-133 storm. Evicting the address
          // did not fix this — the scanner runs allowDuplicates, so the peer's
          // very next advertisement re-added it — it only churned the discovery
          // entry (the nearby-list flicker). Record the failure time instead:
          // [connectToDevice] holds off for [_centralDialCooldown], then the
          // peer's next advertisement retries the SAME address, which is proof
          // it still answers there. A truly gone peer stops advertising and
          // ages out of discovery, so nothing hammers a dead address.
          final now = DateTime.now();
          // Bound the map: a rotated-away address that stops failing ages out.
          _centralDialFailedAt
              .removeWhere((_, at) => now.difference(at) > _centralDialCooldown * 4);
          _centralDialFailedAt[path.pathId] = now;
          // The dial that arms the cooldown leaves no other mark: `drop` is
          // emitted only for a path that was READY, so one dying in
          // `connecting` is invisible and the cooldown that follows looks
          // unprovoked. Record it with whatever the stack said.
          if (_tracing) {
            unawaited(trace!.log({
              'type': 'link',
              't': now.millisecondsSinceEpoch,
              'event': 'dialFailed',
              'transport': 'ble',
              'path': path.pathId,
              if (path.error != null) 'error': path.error,
            }));
          }
          // A cancelled dial failed because WE cancelled it — the inbound leg
          // won and the pair is forming; chasing would dial the peer again.
          if (!wasCancelledDial) _chaseNewerAddress(path.pathId);
        }
        // Mirror the connect emit at the `ready` case: surface a disconnect
        // to the upper layer only on a true transition out of `ready`.
        // Failed dials from `connecting` never produced a "connected" event,
        // and re-emits of an already-dead path (the iOS `.failed → .disconnected`
        // pair, and scan re-discoveries that keep firing path-changed with
        // the cached state) would otherwise spam disconnect logs.
        if (previous?.state == ble.BlePathState.ready) {
          _traceLink('drop', path, role);
          _emitDisconnect(path, role);
        }
        _paths.remove(path.pathId);
        _peerHexByPath.remove(path.pathId);
        _notReadySince.remove(path.pathId);
        // A dropped leg may add or clear a reverse-leg scan target.
        unawaited(_applyScanTargets());
        break;
    }
  }

  /// Identification is the first moment an address can be tied to a peer, so
  /// it is the only place a redundant leg can be recognised.
  ///
  /// Android rotates its advertised address, and the plugin surfaces no
  /// rotation event and no identity resolution (Grassroots does not bond, so
  /// the OS cannot resolve the RPA either). A rotated peer therefore looks
  /// like a brand new device: it is discovered, dialed, and `connectGatt`
  /// opens a SECOND connection to hardware we are already linked to, because a
  /// different address is a different `BluetoothDevice`. The duplicates
  /// overlap for as long as both survive, each holding a real controller slot
  /// that the dial cap then counts against genuinely new peers.
  ///
  /// The pair wants exactly one leg per role. When a newly identified path
  /// duplicates a role we already hold to that peer, the NEW one goes: the
  /// existing leg is already carrying the pair and may have a session and
  /// traffic on it, and dropping the proven one to keep an unproven one
  /// would trade a working link for a fresh handshake. If the survivor later
  /// dies, the peer is re-dialed under whatever address it advertises then.
  void _dropDuplicateLegFor(String pathId, BleRole role) {
    final hex = _peerHexForPathId(pathId);
    if (hex == null) return;
    for (final other in _paths.values) {
      if (other.pathId == pathId) continue;
      if (_roleFromPathId(other.pathId) != role) continue;
      if (!_isReady(other)) continue;
      if (_peerHexForPathId(other.pathId) != hex) continue;
      debugPrint('[ble] duplicate $role leg to ${hex.substring(0, 8)}: '
          'dropping $pathId, keeping ${other.pathId}');
      if (_tracing) {
        unawaited(trace!.log({
          'type': 'link',
          't': DateTime.now().millisecondsSinceEpoch,
          'event': 'duplicateLeg',
          'path': pathId,
          'role': role.name,
          'keptPath': other.pathId,
          'peer': hex,
        }));
      }
      unawaited(disconnectDevice(pathId));
      return;
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
    // Count on-air bytes before any drop gate below: the radio already spent
    // them whether or not the path is deemed ready.
    if (_tracing) _wireLedger.onRx(payload.value);
    // Raw-throughput blobs (DEBUG/TESTBED): counted above, dropped here —
    // they are deliberately not packets and must never reach the parser.
    if (payload.value.isNotEmpty && payload.value[0] == rawPacketType) {
      // The LENGTH THAT ARRIVED is the whole point of the ATT-ceiling probe.
      // A write the stack truncates shows up here shorter than it was sent, a
      // write it refuses never shows up at all, and a write that lands whole
      // matches — three outcomes the byte totals alone cannot separate.
      if (_tracing) {
        unawaited(trace!.log({
          'type': 'wire',
          't': DateTime.now().millisecondsSinceEpoch,
          'event': 'rawRx',
          'len': payload.value.length,
          'path': payload.pathId,
        }));
      }
      return;
    }
    // Drop payloads unless the plugin currently marks the path ready. This
    // prevents late ANNOUNCE packets, hot-restart leftovers, or connected-but-
    // not-sendable paths from populating PeerState BLE role fields. NOTE the
    // wire ledger counted these bytes above — rx totals include them — so
    // the drop record is what reconciles "bytes on the air" with "packets
    // processed".
    final path = _paths[payload.pathId];
    if (path == null || !_isReady(path)) {
      _traceDrop('bleRx', path == null ? 'unknownPath' : 'notReady',
          {'path': payload.pathId, 'bytes': payload.value.length});
      return;
    }

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

  /// The in-flight central dial's pathId while it is still in `connecting` —
  /// the only state a wedge-cancel may target. A dial at `connected` or
  /// `subscribed` is 140 ms of GATT setup from ready and is left to finish.
  final String? inFlightConnectingPathId;

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
    this.inFlightConnectingPathId,
    required this.livePeripheralPathId,
  });
}

/// One write held back until its leg negotiates an MTU: the bytes, the trace
/// site they belong to, and the timer that sends them anyway if no MTU ever
/// arrives.
class _DeferredWrite {
  final Uint8List data;
  final String site;
  Timer? deadline;

  _DeferredWrite(this.data, this.site);
}
