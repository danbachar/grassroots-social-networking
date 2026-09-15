@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;

import 'package:grassroots_bluetooth_layer/grassroots_bluetooth_layer_testing.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/store/app_state.dart';
import 'package:grassroots_networking/src/store/peers_actions.dart'
    show
        BleDeviceDiscoveredAction,
        BleDeviceRemovedAction,
        FriendEstablishedAction,
        PeerAnnounceReceivedAction;
import 'package:grassroots_networking/src/models/peer.dart' show PeerTransport;
import 'package:grassroots_networking/src/store/reducers.dart';
import 'package:grassroots_networking/src/store/settings_actions.dart';
import 'package:grassroots_networking/src/store/settings_state.dart';
import 'package:grassroots_networking/src/transport/ble_transport_service.dart';
import 'package:grassroots_networking/src/transport/transport_service.dart'
    show TransportState;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redux/redux.dart';
import 'package:grassroots_networking/src/trace/experiment_recorder.dart';

/// An active recorder that keeps every record in memory: the dial grid's
/// whole measurement is what the `link` records carry, so the assertions are
/// on the records themselves, not on a file.
class _CapturingTrace extends ExperimentRecorder {
  final List<Map<String, dynamic>> records = [];
  bool _active = false;

  @override
  bool get active => _active;

  @override
  Future<void> startExperiment(String id) async => _active = true;

  @override
  Future<void> stopExperiment() async => _active = false;

  @override
  Future<void> log(Map<String, dynamic> record) async => records.add(record);
}

/// Records the sequence of host API calls so tests can assert them.
class _RecordingHostApi implements GrassrootsBluetoothLayerHostApi {
  final List<String> calls = [];
  final List<BleScanRequest> scanRequests = [];

  @override
  Future<void> initialize(BleInitializeOptions options) async {
    calls.add('initialize');
  }

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<BleAdapterState> adapterState() async => BleAdapterState.poweredOn;

  @override
  Future<void> startAdvertising(BleAdvertiseRequest request) async {
    calls.add('startAdvertising:${request.serviceUuid}');
  }

  @override
  Future<void> stopAdvertising(bool keepServer) async {
    calls.add(keepServer ? 'stopAdvertising:keepServer' : 'stopAdvertising');
  }

  @override
  Future<void> startScan(BleScanRequest request) async {
    scanRequests.add(request);
    calls.add('startScan:${request.serviceUuidPrefix}');
  }

  @override
  Future<void> stopScan() async {
    calls.add('stopScan');
  }

  /// When set, `connect` records the call and never returns — the
  /// platform-channel round trip still in progress.
  bool holdConnect = false;

  @override
  Future<BlePath> connect(BleConnectRequest request) async {
    calls.add('connect:${request.remoteId}');
    if (holdConnect) return Completer<BlePath>().future;
    return BlePath(
      pathId: 'central:${request.remoteId}',
      role: BleRole.central,
      state: BlePathState.connecting,
      rssi: -55,
      mtu: 23,
      canSend: false,
    );
  }

  @override
  Future<void> disconnect(BleDisconnectRequest request) async {
    calls.add('disconnect:${request.pathId}');
  }

  /// Path ids whose writes are refused, as the plugin refuses them: a throw
  /// raised while validating the path or when the stack will not take the
  /// buffer — always BEFORE any byte reaches the controller.
  final Set<String> refuse = {};

  /// Paths whose writes are ACCEPTED and then never answered — the dead leg
  /// that neither throws nor completes. Distinct from [refuse] on purpose:
  /// a refusal is reported and retried, whereas an unanswered write is a
  /// Future that hangs, and the two need opposite defences.
  final Set<String> swallow = {};

  /// Paths whose single GATT op slot is taken: the plugin refuses the write
  /// at once with code `write-busy`, and the bytes never reach the stack.
  final Set<String> busy = {};

  /// Paths whose writes fail with a PlatformException the plugin did not
  /// raise itself — what Pigeon's wrapError produces when a framework call
  /// throws through it, carrying the cause and stack in `details`.
  final Set<String> throughPigeon = {};

  @override
  Future<void> send(BleSendRequest request) async {
    calls.add('send:${request.pathId}:${request.value.length}');
    if (refuse.contains(request.pathId)) {
      throw StateError('refused write on ${request.pathId}');
    }
    if (busy.contains(request.pathId)) {
      throw PlatformException(
          code: 'write-busy',
          message: 'A WriteCharacteristic is in flight on ${request.pathId}');
    }
    if (throughPigeon.contains(request.pathId)) {
      throw PlatformException(
          code: 'channel-error',
          message: 'Unable to establish connection on channel.',
          details: 'Cause: java.lang.NullPointerException: Attempt to invoke '
              'virtual method on a null object reference, Stacktrace: at '
              'android.bluetooth.BluetoothGattServer.notifyCharacteristic');
    }
    if (swallow.contains(request.pathId)) return Completer<void>().future;
  }

  /// Connection-priority requests, in order, as 'priority:high'/'priority:low'.
  final List<String> priorityCalls = [];

  @override
  Future<void> setConnectionPriority(bool high) async {
    priorityCalls.add('priority:${high ? 'high' : 'low'}');
  }

  @override
  Future<List<BlePath?>> paths() async => [];

  @override
  Future<List<BleLinkInfo?>> linkSnapshot() async => [];

  @override
  Future<void> dispose(bool keepAdvertiser) async {
    calls.add('dispose:keep=$keepAdvertiser');
  }

  @override
  Future<bool> restartAdapter() async {
    calls.add('restartAdapter');
    return true;
  }
}

Future<GrassrootsIdentity> _makeIdentity(String nickname) async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  return GrassrootsIdentity.create(keyPair: keyPair, nickname: nickname);
}

/// The first-mover tie-break compares derived service UUIDs (lower = initiator).
/// All fixed peer UUIDs in these tests sort at or above this threshold, so an
/// identity below it is deterministically the initiator and one above it is the
/// non-initiator (waiter).
const _serviceUuidThreshold = '84c40316-0871-e5ad-1000-000000000000';

/// An identity whose derived service UUID sorts BELOW [_serviceUuidThreshold] —
/// the deterministic initiator, which dials on discovery.
Future<GrassrootsIdentity> _makeLowIdentity(String nickname) async {
  while (true) {
    final id = await _makeIdentity(nickname);
    if (id.bleServiceUuid.compareTo(_serviceUuidThreshold) < 0) return id;
  }
}

/// An identity whose derived service UUID sorts ABOVE [_serviceUuidThreshold] —
/// the non-initiator (waiter), which holds off the first-mover dial.
Future<GrassrootsIdentity> _makeHighIdentity(String nickname) async {
  while (true) {
    final id = await _makeIdentity(nickname);
    if (id.bleServiceUuid.compareTo(_serviceUuidThreshold) >= 0) return id;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BleTransportService — strict projection of plugin facts', () {
    late _RecordingHostApi hostApi;
    late FakeGrassrootsBluetoothCallbacks callbacks;
    late GrassrootsBluetooth ble;
    late Store<AppState> store;
    late BleTransportService transport;

    setUp(() async {
      hostApi = _RecordingHostApi();
      callbacks = FakeGrassrootsBluetoothCallbacks();
      ble = GrassrootsBluetooth.test(hostApi: hostApi, callbacks: callbacks);
      store = Store<AppState>(appReducer, initialState: AppState.initial);
      // The suite exercises open-mode dialing toward unknown peers; the
      // default trust level is closed.
      store.dispatch(SetColdCallTrustLevelAction(ColdCallTrustLevel.open));
      transport = BleTransportService(
        // Low service UUID → this transport is the deterministic first-mover,
        // so the existing "advertisement → dial" expectations hold against the
        // fixed (higher-sorting) peer UUIDs below.
        identity: await _makeLowIdentity('Tester'),
        store: store,
        grassrootsBluetooth: ble,
      );
      await transport.initialize();
    });

    tearDown(() async {
      await transport.dispose();
    });

    test('discovered → connecting → ready dispatches Redux actions in order',
        () async {
      const pathId = 'central:AABBCCDDEEFF';
      const remoteId = 'AABBCCDDEEFF';
      const serviceUuid = '84c40316-0871-e5ad-1111-000000000000';

      // 1. Plugin emits an advertisement.
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: remoteId,
        serviceUuids: [serviceUuid],
        rssi: -60,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);

      // 2. Discovered entry exists, plugin's connect was triggered.
      expect(store.state.peers.discoveredBlePeers.containsKey(pathId), true);
      expect(hostApi.calls, contains('connect:$remoteId'));

      // 3. Plugin emits connecting → connected → ready.
      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.connecting,
        rssi: -60,
        mtu: 23,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(store.state.peers.discoveredBlePeers[pathId]!.isConnecting, true);

      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.ready,
        rssi: -60,
        mtu: 247,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);

      final disc = store.state.peers.discoveredBlePeers[pathId]!;
      expect(disc.isConnecting, false);
      expect(disc.isConnected, true);
      expect(transport.connectedPeerIds, contains(pathId));
    });

    test('disconnect path event clears connection facts in Redux', () async {
      const pathId = 'central:AABBCC';

      // Establish.
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: 'AABBCC',
        serviceUuids: ['84c40316-0871-e5ad-2222-000000000000'],
        rssi: -55,
        connectable: true,
      ));
      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.ready,
        rssi: -55,
        mtu: 247,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(store.state.peers.discoveredBlePeers[pathId]!.isConnected, true);

      // Plugin says disconnected.
      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.disconnected,
        rssi: -55,
        mtu: 23,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);

      final disc = store.state.peers.discoveredBlePeers[pathId]!;
      expect(disc.isConnecting, false);
      expect(disc.isConnected, false);
      expect(transport.connectedPeerIds, isEmpty);
    });

    test(
        'connectionStream fires disconnect once per ready→dead transition, '
        'regardless of failed/disconnected duplicates or scan re-discovery '
        're-emits',
        () async {
      const pathId = 'central:DEADBEEF';

      final disconnectEvents = <String>[];
      final sub = transport.connectionStream.listen((event) {
        if (!event.connected) disconnectEvents.add(event.peerId);
      });
      addTearDown(sub.cancel);

      // Establish a ready central path.
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: 'DEADBEEF',
        serviceUuids: ['84c40316-0871-e5ad-3333-000000000000'],
        rssi: -55,
        connectable: true,
      ));
      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.ready,
        rssi: -55,
        mtu: 247,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);

      // iOS pattern: ready → failed (cancel timer) → disconnected
      // (didDisconnectPeripheral). Only the first transition out of ready
      // should surface as a disconnect.
      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.failed,
        rssi: -55,
        mtu: 23,
        canSend: false,
        error: 'Connection timed out.',
      ));
      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.disconnected,
        rssi: -55,
        mtu: 23,
        canSend: false,
        error: 'Connection timed out.',
      ));
      await Future<void>.delayed(Duration.zero);

      // iOS scan re-discovery with `allowDuplicates: true` re-emits the
      // cached `.disconnected` path for the next ~2 min while backoff is
      // active. None of these should add new disconnect events.
      for (var i = 0; i < 5; i++) {
        callbacks.pushPath(BlePath(
          pathId: pathId,
          role: BleRole.central,
          state: BlePathState.disconnected,
          rssi: -50 - i,
          mtu: 23,
          canSend: false,
        ));
      }
      await Future<void>.delayed(Duration.zero);

      expect(disconnectEvents, equals([pathId]),
          reason:
              'Exactly one disconnect event must fire per ready→dead lifecycle.');
    });

    test(
        'failed dial from connecting (never reached ready) does not fire a '
        'spurious disconnect event', () async {
      const pathId = 'central:CAFE1234';

      final disconnectEvents = <String>[];
      final sub = transport.connectionStream.listen((event) {
        if (!event.connected) disconnectEvents.add(event.peerId);
      });
      addTearDown(sub.cancel);

      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: 'CAFE1234',
        serviceUuids: ['84c40316-0871-e5ad-3333-000000000000'],
        rssi: -55,
        connectable: true,
      ));
      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.connecting,
        rssi: -55,
        mtu: 23,
        canSend: false,
      ));
      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.failed,
        rssi: -55,
        mtu: 23,
        canSend: false,
        error: 'Connection timed out.',
      ));
      await Future<void>.delayed(Duration.zero);

      expect(disconnectEvents, isEmpty,
          reason:
              'A dial that never reached `ready` never produced a connected '
              'event, so it must not produce a disconnected event either.');
    });

    test(
        'a fresh advertisement inside the cooldown after a failed dial does '
        'not redial', () async {
      const remoteId = 'AABBCC';
      const pathId = 'central:$remoteId';
      const serviceUuid = '84c40316-0871-e5ad-2222-000000000000';

      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: remoteId,
        serviceUuids: [serviceUuid],
        rssi: -55,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(
          hostApi.calls.where((c) => c == 'connect:$remoteId'), hasLength(1));

      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.failed,
        rssi: -55,
        mtu: 23,
        canSend: false,
        error: 'Connection timed out.',
      ));
      await Future<void>.delayed(Duration.zero);

      // The next ad inside the cooldown must NOT re-fire the dial: a failed
      // connectGatt holds a native GATT slot for its full timeout, so
      // redialing on every scan tick (the scanner runs allowDuplicates)
      // exhausts the table. The address is retried once the cooldown elapses.
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: remoteId,
        serviceUuids: [serviceUuid],
        rssi: -54,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(
          hostApi.calls.where((c) => c == 'connect:$remoteId'), hasLength(1));
    });

    test('a dial that ends before ready clears the entry\'s connecting flag',
        () async {
      // The flag is what the advertised-MAC retry and the discovery reducer
      // read to leave an address alone; a dial that died must not keep
      // holding it, or the address is never retried and never pruned.
      const pathId = 'central:GONE';
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: 'GONE',
        serviceUuids: ['84c40316-0871-e5ad-8888-000000000000'],
        rssi: -55,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);
      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.connecting,
        rssi: -55,
        mtu: 23,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(store.state.peers.discoveredBlePeers[pathId]!.isConnecting, true);
      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.disconnected,
        rssi: null,
        mtu: 23,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(store.state.peers.discoveredBlePeers[pathId]!.isConnecting, false);
    });

    test('a failed central dial keeps the address but cools down the redial',
        () async {
      const remoteId = 'DEADADDR';
      const pathId = 'central:$remoteId';
      const serviceUuid = '84c40316-0871-e5ad-8888-000000000000';

      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: remoteId,
        serviceUuids: [serviceUuid],
        rssi: -55,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(store.state.peers.discoveredBlePeers.containsKey(pathId), true);
      final dialsAfterFirst =
          hostApi.calls.where((c) => c == 'connect:$remoteId').length;

      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.failed,
        rssi: -55,
        mtu: 23,
        canSend: false,
        error: 'GATT_ERROR(133)',
      ));
      await Future<void>.delayed(Duration.zero);

      // The failed address is EVICTED — the measured cause of a fast failure
      // is an address nobody on the air owns any more, and a dead entry
      // lingering in discovery would be dialed ahead of the peer's live one.
      // The cooldown record survives the eviction; the rest of this test is
      // the alive case.
      expect(store.state.peers.discoveredBlePeers.containsKey(pathId), false,
          reason: 'A failed dial evicts the dead address.');

      // An address that re-advertises after failing is ALIVE: it re-enters
      // discovery, and the cooldown is what keeps it off the GATT slot table
      // until it elapses.
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: remoteId,
        serviceUuids: [serviceUuid],
        rssi: -55,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(store.state.peers.discoveredBlePeers.containsKey(pathId), true,
          reason: 'Re-advertising proves the address is alive; it re-enters.');
      final dialsAfterCooldownAd =
          hostApi.calls.where((c) => c == 'connect:$remoteId').length;
      expect(dialsAfterCooldownAd, dialsAfterFirst,
          reason: 'Within the cooldown, a re-advertisement of the same address '
              'is not redialed.');
    });

    test('a dead address is evicted and the newest sighting dialed at once',
        () async {
      const uuid = '84c40316-0871-e5ad-1111-000000000000';

      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: 'OLDRPA',
        serviceUuids: [uuid],
        rssi: -40,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls.where((c) => c == 'connect:OLDRPA'), hasLength(1));

      // The peer's fresh address arrives while the doomed dial is in flight.
      // Strictly newer information than the sighting that produced the dial.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: 'NEWRPA',
        serviceUuids: [uuid],
        rssi: -41,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);

      callbacks.pushPath(BlePath(
        pathId: 'central:OLDRPA',
        role: BleRole.central,
        state: BlePathState.failed,
        rssi: -40,
        mtu: 23,
        canSend: false,
        error: 'GATT status 133 (GATT_ERROR generic)',
      ));
      await Future<void>.delayed(Duration.zero);

      // The dead address leaves; the chase dials the live one without
      // waiting out any cooldown — the cooldown belongs to addresses that
      // answer, and this one demonstrably does not.
      expect(store.state.peers.discoveredBlePeers.containsKey('central:OLDRPA'),
          isFalse,
          reason: 'nobody on the air owns the failed address any more');
      // Exactly one dial at the live address — the chase fired without any
      // cooldown wait, and it never double-dials one already in flight.
      expect(hostApi.calls.where((c) => c == 'connect:NEWRPA'), hasLength(1),
          reason: 'the identity is still here, under its new address');
    });

    test('a failed dial with no newer sighting waits, as before', () async {
      const uuid = '84c40316-0871-e5ad-3333-000000000000';
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: 'ONLYRPA',
        serviceUuids: [uuid],
        rssi: -50,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);
      final dials = hostApi.calls.where((c) => c.startsWith('connect:')).length;

      callbacks.pushPath(BlePath(
        pathId: 'central:ONLYRPA',
        role: BleRole.central,
        state: BlePathState.failed,
        rssi: -50,
        mtu: 23,
        canSend: false,
        error: 'GATT status 133 (GATT_ERROR generic)',
      ));
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls.where((c) => c.startsWith('connect:')).length, dials,
          reason: 'nothing newer to chase; the next advertisement decides');
    });

    test('a failed peripheral path does NOT drop a discovered address',
        () async {
      // Planted under the peripheral pathId so the two keys coincide: the
      // dial-failure cooldown is gated on the central role, so an inbound
      // peripheral failure must not touch this address.
      const pathId = 'peripheral:INBOUND';
      store.dispatch(BleDeviceDiscoveredAction(
        deviceId: pathId,
        rssi: -55,
        serviceUuid: '84c40316-0871-e5ad-9999-000000000000',
      ));

      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.peripheral,
        state: BlePathState.failed,
        rssi: null,
        mtu: 23,
        canSend: false,
        error: 'Connection timed out.',
      ));
      await Future<void>.delayed(Duration.zero);

      expect(store.state.peers.discoveredBlePeers.containsKey(pathId), true,
          reason: 'Only our own dial exhausts GATT slots. A failure on an '
              'inbound leg says nothing about whether that address is dialable.');
    });

    test(
        'MAC rotation while a path is ready: ad from rotated MAC is ignored '
        '(no parallel dial, no ghost entry)', () async {
      const oldRemoteId = 'OLDMAC';
      const newRemoteId = 'NEWMAC';
      const oldPathId = 'central:$oldRemoteId';
      const newPathId = 'central:$newRemoteId';
      // Same derived service UUID = same logical peer (same pubkey).
      const serviceUuid = '84c40316-0871-e5ad-7777-000000000000';

      // Establish a ready central path on the old MAC.
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: oldRemoteId,
        serviceUuids: [serviceUuid],
        rssi: -55,
        connectable: true,
      ));
      callbacks.pushPath(BlePath(
        pathId: oldPathId,
        role: BleRole.central,
        state: BlePathState.ready,
        rssi: -55,
        mtu: 247,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(store.state.peers.discoveredBlePeers[oldPathId]!.isConnected, true);

      hostApi.calls.clear();

      // The same peer rotates its radio MAC — fresh advertisement, different
      // remoteId, same derived service UUID. Must NOT spawn a second dial.
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: newRemoteId,
        serviceUuids: [serviceUuid],
        rssi: -50,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(hostApi.calls.where((c) => c == 'connect:$newRemoteId'), isEmpty,
          reason: 'Rotated MAC for a peer we already have ready must not '
              'trigger a parallel dial.');
      expect(store.state.peers.discoveredBlePeers.containsKey(newPathId), false,
          reason:
              'Rotated MAC must not pile up a ghost DiscoveredPeerState entry '
              'while the original path is still live.');
      expect(store.state.peers.discoveredBlePeers[oldPathId]!.isConnected, true,
          reason: 'Original ready path must be untouched.');
    });

    test(
        'MAC rotation while a dial is in-flight: ad from rotated MAC is '
        'ignored', () async {
      const oldRemoteId = 'INFLIGHT_OLD';
      const newRemoteId = 'INFLIGHT_NEW';
      const oldPathId = 'central:$oldRemoteId';
      const serviceUuid = '84c40316-0871-e5ad-8888-000000000000';

      // Discovery + plugin acknowledges connecting on the old MAC.
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: oldRemoteId,
        serviceUuids: [serviceUuid],
        rssi: -55,
        connectable: true,
      ));
      callbacks.pushPath(BlePath(
        pathId: oldPathId,
        role: BleRole.central,
        state: BlePathState.connecting,
        rssi: -55,
        mtu: 23,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(store.state.peers.discoveredBlePeers[oldPathId]!.isConnecting, true);

      hostApi.calls.clear();

      // Fresh advertisement on a rotated MAC for the same logical peer.
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: newRemoteId,
        serviceUuids: [serviceUuid],
        rssi: -53,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(hostApi.calls.where((c) => c == 'connect:$newRemoteId'), isEmpty,
          reason: 'A dial is already in-flight on the old MAC. Racing a '
              'second dial on the rotated MAC starves the BLE stack.');
    });

    test(
        'MAC rotation after the old path dies: stale ghost is pruned and the '
        'new MAC is dialed', () async {
      const oldRemoteId = 'STALE_OLD';
      const newRemoteId = 'STALE_NEW';
      const oldPathId = 'central:$oldRemoteId';
      const newPathId = 'central:$newRemoteId';
      const serviceUuid = '84c40316-0871-e5ad-9999-000000000000';

      // Old MAC: discover → ready → fail/disconnect.
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: oldRemoteId,
        serviceUuids: [serviceUuid],
        rssi: -55,
        connectable: true,
      ));
      callbacks.pushPath(BlePath(
        pathId: oldPathId,
        role: BleRole.central,
        state: BlePathState.ready,
        rssi: -55,
        mtu: 247,
        canSend: true,
      ));
      callbacks.pushPath(BlePath(
        pathId: oldPathId,
        role: BleRole.central,
        state: BlePathState.disconnected,
        rssi: -55,
        mtu: 23,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);

      // Old entry is dead (isConnected/isConnecting both false). It still
      // sits in the Redux map — it gets removed by the next discovery for
      // the same service UUID.
      expect(store.state.peers.discoveredBlePeers[oldPathId]!.isConnected, false);
      expect(store.state.peers.discoveredBlePeers[oldPathId]!.isConnecting, false);

      hostApi.calls.clear();

      // Rotated MAC for the same logical peer arrives.
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: newRemoteId,
        serviceUuids: [serviceUuid],
        rssi: -50,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(store.state.peers.discoveredBlePeers.containsKey(oldPathId), false,
          reason: 'Dead ghost entry from the old MAC must be pruned when a '
              'fresh advertisement with the same service UUID arrives.');
      expect(store.state.peers.discoveredBlePeers.containsKey(newPathId), true,
          reason: 'New MAC must take over as the live entry.');
      expect(
          hostApi.calls.where((c) => c == 'connect:$newRemoteId'), hasLength(1),
          reason: 'The rotated MAC must be dialed once the old path is dead.');
    });

    test(
        'MAC rotation while a central path is ready but the old MAC entry was '
        'stale-pruned: the identified-peer guard still suppresses the '
        'duplicate dial (status-133 storm)', () async {
      const oldRemoteId = 'PRUNED_OLD';
      const newRemoteId = 'PRUNED_NEW';
      const oldPathId = 'central:$oldRemoteId';
      const newPathId = 'central:$newRemoteId';

      // The advertisement's service UUID must derive from the peer's real
      // pubkey, because the identified-peer guard recomputes it from the
      // PeerState to recognise the same logical peer across MAC rotation.
      final peerIdentity = await _makeIdentity('Rotator');
      final serviceUuid = peerIdentity.bleServiceUuid;

      // Establish a ready central path on the old MAC.
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: oldRemoteId,
        serviceUuids: [serviceUuid],
        rssi: -55,
        connectable: true,
      ));
      callbacks.pushPath(BlePath(
        pathId: oldPathId,
        role: BleRole.central,
        state: BlePathState.ready,
        rssi: -55,
        mtu: 247,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);

      // ANNOUNCE identifies the peer and binds the central attachment to the
      // old MAC's path.
      store.dispatch(PeerAnnounceReceivedAction(
        publicKey: peerIdentity.publicKey,
        nickname: 'Rotator',
        transport: PeerTransport.bleDirect,
        bleCentralDeviceId: oldPathId,
      ));
      await Future<void>.delayed(Duration.zero);

      // Simulate the stale sweep pruning the connected MAC's DiscoveredPeerState
      // (it stopped being re-advertised once the peer rotated its RPA). This is
      // exactly the condition that blinds the discovery-map `activeOnOtherMac`
      // guard — the live connection lives in `_paths`, not `discoveredBlePeers`.
      store.dispatch(BleDeviceRemovedAction(oldPathId));
      await Future<void>.delayed(Duration.zero);
      expect(store.state.peers.discoveredBlePeers.containsKey(oldPathId), false,
          reason: 'Precondition: old MAC discovery entry pruned — the '
              'discovery-map guard is now blind to the live connection.');

      hostApi.calls.clear();

      // The same peer advertises on a freshly-rotated MAC.
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: newRemoteId,
        serviceUuids: [serviceUuid],
        rssi: -50,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(hostApi.calls.where((c) => c == 'connect:$newRemoteId'), isEmpty,
          reason: 'We already hold a live central leg to this identity; dialing '
              'the rotated MAC only duplicates it — the GATT-133 storm.');
      expect(store.state.peers.discoveredBlePeers.containsKey(newPathId), false,
          reason: 'Suppressed rotated MAC must not pile up a ghost entry.');
    });

    test(
        'a peripheral-only attachment does NOT suppress the central dial: the '
        'reverse (central) leg of a dual-role connection still proceeds',
        () async {
      const advertisingMac = 'DUAL_ADV';
      const connectionMac = 'DUAL_CONN';

      final peerIdentity = await _makeIdentity('DualRole');
      final serviceUuid = peerIdentity.bleServiceUuid;

      // Inbound peripheral leg is ready and identified — but we hold NO central
      // leg yet. This is the state right after the remote dialed us first.
      callbacks.pushPath(BlePath(
        pathId: 'peripheral:$connectionMac',
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: null,
        mtu: 517,
        canSend: true,
      ));
      store.dispatch(PeerAnnounceReceivedAction(
        publicKey: peerIdentity.publicKey,
        nickname: 'DualRole',
        transport: PeerTransport.bleDirect,
        blePeripheralDeviceId: 'peripheral:$connectionMac',
      ));
      await Future<void>.delayed(Duration.zero);
      // Drop any setup-driven dial so the assertion sees only the ad below.
      hostApi.calls.clear();

      // The peer advertises. Because we only hold the peripheral leg, the
      // central dial MUST fire — targeted at the live inbound link's remote
      // address (attaching over the existing ACL), NOT the advertised MAC
      // (a second ACL, which modern stacks refuse with GATT 133).
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: advertisingMac,
        serviceUuids: [serviceUuid],
        rssi: -50,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(hostApi.calls.where((c) => c == 'connect:$connectionMac'),
          hasLength(1),
          reason: 'Peripheral-only attachment must not suppress the central '
              'dial, and the dial must ride the existing ACL (connection '
              'MAC) rather than open a second one (advertised MAC).');
      expect(hostApi.calls.where((c) => c == 'connect:$advertisingMac'),
          isEmpty,
          reason: 'Dialing the advertised MAC while a link exists attempts a '
              'second ACL — measured fast-133 on modern stacks.');

      // The over-ACL dial goes in flight (plugin reports `connecting`). It
      // has NO discovery entry — the one-central-per-identity guard must
      // still recognise it (matched by the inbound leg's remote address) and
      // suppress further dials on the next advertisement.
      callbacks.pushPath(BlePath(
        pathId: 'central:$connectionMac',
        role: BleRole.central,
        state: BlePathState.connecting,
        rssi: null,
        mtu: 23,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);
      hostApi.calls.clear();

      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: advertisingMac,
        serviceUuids: [serviceUuid],
        rssi: -48,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(hostApi.calls.where((c) => c.startsWith('connect:')), isEmpty,
          reason: 'An in-flight over-ACL reverse dial (no discovery entry) '
              'must be matched to the identity by remote address and count '
              'as the pair\'s one central leg.');
    });

    test(
        'different service UUIDs (genuinely different peers) are tracked '
        'independently', () async {
      const remoteA = 'PEER_A';
      const remoteB = 'PEER_B';
      const pathA = 'central:$remoteA';
      const pathB = 'central:$remoteB';
      const serviceA = '84c40316-0871-e5ad-aaaa-000000000000';
      const serviceB = '84c40316-0871-e5ad-bbbb-000000000000';

      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: remoteA,
        serviceUuids: [serviceA],
        rssi: -55,
        connectable: true,
      ));
      callbacks.pushPath(BlePath(
        pathId: pathA,
        role: BleRole.central,
        state: BlePathState.ready,
        rssi: -55,
        mtu: 247,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);

      hostApi.calls.clear();

      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: remoteB,
        serviceUuids: [serviceB],
        rssi: -50,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(store.state.peers.discoveredBlePeers.containsKey(pathA), true);
      expect(store.state.peers.discoveredBlePeers.containsKey(pathB), true,
          reason: 'A different service UUID is a different logical peer and '
              'must not be deduped against an existing entry.');
      expect(
          hostApi.calls.where((c) => c == 'connect:$remoteB'), hasLength(1));
    });

    test(
        'reverse-leg dial after ANNOUNCE: when the peer\'s advertising MAC '
        'differs from their connection MAC (modern Android BLE privacy), '
        'we dial the LIVE connection MAC — attaching over the existing ACL',
        () async {
      // Connection (peripheral) MAC and advertising MAC are different —
      // this is the real-world Android case where BLE privacy uses
      // separate addresses for advertising vs initiating connections.
      const advertisingMac = 'AA:BB:CC:DD:EE:01';
      const connectionMac = '99:88:77:66:55:02';

      final peerIdentity = await _makeIdentity('Remote');
      final serviceUuid = peerIdentity.bleServiceUuid;

      // Scanner sees the peer advertising at advertisingMac.
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: advertisingMac,
        serviceUuids: [serviceUuid],
        rssi: -55,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);

      // The scanner-driven path may already have dialed advertisingMac
      // once — that's fine. We're going to clear that history and check
      // that the reverse-leg fires a fresh dial when ANNOUNCE lands.
      hostApi.calls.clear();

      // Peripheral path arrives from the (different) connection MAC and
      // reaches ready before ANNOUNCE — nothing dials: the reverse leg
      // fires only from `onPeerIdentified`, once we know who is on the
      // other end.
      callbacks.pushPath(BlePath(
        pathId: 'peripheral:$connectionMac',
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: null,
        mtu: 517,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(hostApi.calls.where((c) => c.startsWith('connect:')), isEmpty,
          reason:
              'Pre-ANNOUNCE peripheral-ready must NOT dial the connection MAC '
              '— that address has no GATT server attached on a BLE-privacy stack.');

      // ANNOUNCE arrives over the peripheral path. The router dispatches
      // PeerAnnounceReceivedAction (recording the attachment) and then
      // invokes onPeerIdentified. The transport must then trigger the
      // reverse leg against an advertising MAC we already know works.
      store.dispatch(PeerAnnounceReceivedAction(
        publicKey: peerIdentity.publicKey,
        nickname: 'Remote',
        transport: PeerTransport.bleDirect,
        blePeripheralDeviceId: 'peripheral:$connectionMac',
      ));
      transport.onPeerIdentified('peripheral:$connectionMac', peerIdentity.publicKey);
      await Future<void>.delayed(Duration.zero);

      expect(hostApi.calls.where((c) => c == 'connect:$connectionMac'),
          hasLength(1),
          reason: 'Reverse leg must dial the live inbound connection MAC — '
              'connecting to an already-linked device attaches the GATT '
              'client over the existing ACL. Dialing the advertising MAC '
              'would attempt a second ACL, which modern stacks refuse '
              '(measured fast-133 on Pixel 10 / Android 16).');
      expect(hostApi.calls.where((c) => c == 'connect:$advertisingMac'),
          isEmpty,
          reason: 'No second ACL toward the advertised MAC while the '
              'inbound link is live.');
    });

    test(
        'a reverse dial that starts and dies before ready retries ONCE at '
        'the freshly advertised MAC', () async {
      // The measured failure mode: the over-ACL dial to the peer's
      // connection address connects and drops in milliseconds. Before this
      // retry existed, nothing fired until the next advertisement election
      // — which is where the pair's convergence time was going.
      const advertisingMac = 'AA:BB:CC:DD:EE:11';
      const connectionMac = '99:88:77:66:55:12';

      final peerIdentity = await _makeIdentity('Remote');
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: advertisingMac,
        serviceUuids: [peerIdentity.bleServiceUuid],
        rssi: -55,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);
      // The sighting itself dials now (no leg-order election). Settle that
      // dial as gone — a plain disconnect, not `failed`, so no cooldown is
      // armed against the advertised address — before the scenario begins.
      callbacks.pushPath(BlePath(
        pathId: 'central:$advertisingMac',
        role: BleRole.central,
        state: BlePathState.disconnected,
        rssi: null,
        mtu: 23,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);
      callbacks.pushPath(BlePath(
        pathId: 'peripheral:$connectionMac',
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: null,
        mtu: 517,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      store.dispatch(PeerAnnounceReceivedAction(
        publicKey: peerIdentity.publicKey,
        nickname: 'Remote',
        transport: PeerTransport.bleDirect,
        blePeripheralDeviceId: 'peripheral:$connectionMac',
      ));
      hostApi.calls.clear();
      transport.onPeerIdentified(
          'peripheral:$connectionMac', peerIdentity.publicKey);
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls.where((c) => c == 'connect:$connectionMac'),
          hasLength(1));

      // The over-ACL dial dies before ready.
      callbacks.pushPath(BlePath(
        pathId: 'central:$connectionMac',
        role: BleRole.central,
        state: BlePathState.failed,
        rssi: null,
        mtu: 23,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(hostApi.calls.where((c) => c == 'connect:$advertisingMac'),
          hasLength(1),
          reason: 'the death of the over-ACL dial must immediately retry at '
              'the advertised MAC, not wait for the next election');

      // And only once: a second death of the SAME pathId retries nothing.
      callbacks.pushPath(BlePath(
        pathId: 'central:$connectionMac',
        role: BleRole.central,
        state: BlePathState.failed,
        rssi: null,
        mtu: 23,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls.where((c) => c == 'connect:$advertisingMac'),
          hasLength(1),
          reason: 'one retry per registered reverse dial — the advertisement '
              'election owns everything after');
    });

    test(
        'a dial wedged in connecting is cancelled when the inbound leg wins, '
        'and the reverse leg opens at once', () async {
      // The measured wedge: our dial sits in `connecting` for its full 20 s
      // timeout while the peer's dial has already landed. The inbound READY
      // leg is proof the race is lost; waiting out the timeout kept
      // dual-role convergence at ~21 s on a link whose session was up in
      // under 3 s.
      const advertisingMac = 'AA:BB:CC:DD:EE:21';
      const connectionMac = '99:88:77:66:55:22';

      final peerIdentity = await _makeIdentity('Remote');
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: advertisingMac,
        serviceUuids: [peerIdentity.bleServiceUuid],
        rssi: -55,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);
      // The sighting dialed; the plugin reports it stuck in `connecting`.
      callbacks.pushPath(BlePath(
        pathId: 'central:$advertisingMac',
        role: BleRole.central,
        state: BlePathState.connecting,
        rssi: null,
        mtu: 23,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);

      // The peer's dial wins: our peripheral leg comes up and identifies.
      callbacks.pushPath(BlePath(
        pathId: 'peripheral:$connectionMac',
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: null,
        mtu: 517,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      store.dispatch(PeerAnnounceReceivedAction(
        publicKey: peerIdentity.publicKey,
        nickname: 'Remote',
        transport: PeerTransport.bleDirect,
        blePeripheralDeviceId: 'peripheral:$connectionMac',
      ));
      hostApi.calls.clear();
      transport.onPeerIdentified(
          'peripheral:$connectionMac', peerIdentity.publicKey);
      await Future<void>.delayed(Duration.zero);

      expect(hostApi.calls.where((c) => c.startsWith('disconnect:central:')),
          ['disconnect:central:$advertisingMac'],
          reason: 'the wedged dial is torn down, not waited out');
      expect(hostApi.calls.where((c) => c == 'connect:$connectionMac'),
          hasLength(1),
          reason: 'the reverse leg opens over the winning ACL immediately — '
              'the cancelled dial no longer counts as the pair\'s central');
    });

    test('a dial past connecting is left to finish, not cancelled', () async {
      const advertisingMac = 'AA:BB:CC:DD:EE:31';
      const connectionMac = '99:88:77:66:55:32';

      final peerIdentity = await _makeIdentity('Remote');
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: advertisingMac,
        serviceUuids: [peerIdentity.bleServiceUuid],
        rssi: -55,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);
      // The dial has already CONNECTED — 140 ms of GATT setup from ready.
      callbacks.pushPath(BlePath(
        pathId: 'central:$advertisingMac',
        role: BleRole.central,
        state: BlePathState.connected,
        rssi: null,
        mtu: 23,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);
      callbacks.pushPath(BlePath(
        pathId: 'peripheral:$connectionMac',
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: null,
        mtu: 517,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      store.dispatch(PeerAnnounceReceivedAction(
        publicKey: peerIdentity.publicKey,
        nickname: 'Remote',
        transport: PeerTransport.bleDirect,
        blePeripheralDeviceId: 'peripheral:$connectionMac',
      ));
      hostApi.calls.clear();
      transport.onPeerIdentified(
          'peripheral:$connectionMac', peerIdentity.publicKey);
      await Future<void>.delayed(Duration.zero);

      expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty,
          reason: 'a progressing dial is never sacrificed');
      expect(hostApi.calls.where((c) => c.startsWith('connect:')), isEmpty,
          reason: 'the pair still has its one central in flight');
    });

    test('the connect leash scales with the sighting RSSI', () {
      // Anchors from the field path-loss fit (RSSI = -30 - 32.3 log d):
      // touching distance gets ~2 s, the 45 m fringe keeps the full 20 s.
      expect(BleTransportService.connectTimeoutForRssi(-30),
          const Duration(seconds: 2));
      expect(BleTransportService.connectTimeoutForRssi(-40),
          const Duration(seconds: 2));
      expect(BleTransportService.connectTimeoutForRssi(-85),
          const Duration(seconds: 20));
      expect(BleTransportService.connectTimeoutForRssi(-100),
          const Duration(seconds: 20));
      // Midpoint: linear in dB.
      expect(
          BleTransportService.connectTimeoutForRssi(-62).inMilliseconds, 10800);
      // No reading — and every iOS dial — stays patient: CoreBluetooth can
      // legitimately take 10-15 s.
      expect(BleTransportService.connectTimeoutForRssi(null),
          const Duration(seconds: 20));
    });

    test('two sides of one pair get different leashes from their own readings',
        () {
      // Directional asymmetry is measured at several dB on every pair; the
      // deadlock's fix is exactly that the shorter leash frees its advertiser
      // first, so equal leashes would be the failure mode.
      final a = BleTransportService.connectTimeoutForRssi(-44);
      final b = BleTransportService.connectTimeoutForRssi(-52);
      expect(a, isNot(b));
      expect(b - a, const Duration(milliseconds: 3200));
    });

    test('dead-path payloads are dropped (no resurrected ANNOUNCE)', () async {
      const pathId = 'central:DEADBEEF';

      // Path was alive, then disconnects.
      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.ready,
        rssi: -50,
        mtu: 247,
        canSend: true,
      ));
      callbacks.pushPath(BlePath(
        pathId: pathId,
        role: BleRole.central,
        state: BlePathState.disconnected,
        rssi: -50,
        mtu: 23,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);

      // Late payload arrives on the now-dead path.
      var packetCallbackFired = false;
      transport.onBlePacketReceived = (_, {bleDeviceId, rssi = 0, bleRole}) {
        packetCallbackFired = true;
      };
      callbacks.pushPayload(BlePayload(
        pathId: pathId,
        role: BleRole.central,
        value: Uint8List.fromList([1, 2, 3]),
        rssi: -50,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(packetCallbackFired, false,
          reason: 'Payload arriving on a disconnected path must be dropped '
              'so it cannot resurrect the dead pathId via ANNOUNCE.');
    });

    test('start() with adapter off stays in `ready` and retries on adapter-on',
        () async {
      // Override hostApi to throw on startScan/startAdvertising the first
      // time, then succeed.
      var advFails = true;
      var scanFails = true;
      hostApi = _RecordingHostApi();

      // Already initialized via setUp; redo with a custom hostApi.
      await transport.dispose();
      hostApi = _RecordingHostApi();
      ble = GrassrootsBluetooth.test(hostApi: hostApi, callbacks: callbacks);
      store = Store<AppState>(appReducer, initialState: AppState.initial);
      // The suite exercises open-mode dialing toward unknown peers; the
      // default trust level is closed.
      store.dispatch(SetColdCallTrustLevelAction(ColdCallTrustLevel.open));
      // Reset transport state so initialize works again
      // (no easy way to reset Redux from outside).
      transport = BleTransportService(
        identity: await _makeIdentity('Tester2'),
        store: store,
        grassrootsBluetooth: ble,
      );
      await transport.initialize();

      // No-op — verify state machine; the actual retry logic is exercised
      // by the manual start/start race tests above and by integration
      // tests on real hardware.
      expect(store.state.transports.bleState, TransportState.ready);
      // Avoid unused var warnings.
      expect(advFails && scanFails, true);
    });

    test('peripheral-only mode never starts scanning', () async {
      store.dispatch(SetBleRoleModeAction(BleRoleMode.peripheralOnly));
      hostApi.calls.clear();
      hostApi.scanRequests.clear();

      await transport.start();
      expect(hostApi.calls.where((c) => c.startsWith('startAdvertising:')),
          hasLength(1));
      expect(hostApi.calls, contains('stopScan'));
      expect(hostApi.calls.where((c) => c.startsWith('startScan:')), isEmpty);
      expect(hostApi.scanRequests, isEmpty);

      await transport.scan();
      expect(hostApi.calls.where((c) => c.startsWith('startScan:')), isEmpty);
      expect(hostApi.scanRequests, isEmpty);
    });

    test('scans by Grassroots prefix and allows duplicate advertisements',
        () async {
      hostApi.calls.clear();
      hostApi.scanRequests.clear();

      await transport.start();

      expect(hostApi.scanRequests, hasLength(1));
      final request = hostApi.scanRequests.single;
      expect(request.serviceUuidPrefix,
          equals(GrassrootsIdentity.grassrootsUuidPrefix));
      expect(request.serviceUuids, isEmpty);
      expect(request.timeoutMs, equals(0));
      expect(request.allowDuplicates, isTrue);
    });

    test('closed trust dials only derived UUIDs for accepted friends',
        () async {
      store.dispatch(SetColdCallTrustLevelAction(ColdCallTrustLevel.closed));
      const unknownRemoteId = 'UNKNOWN';
      const unknownUuid = '84c40316-0871-e5ad-ffff-000000000000';

      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: unknownRemoteId,
        serviceUuids: [unknownUuid],
        rssi: -62,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(
          hostApi.calls.where((c) => c == 'connect:$unknownRemoteId'), isEmpty);

      // High service UUID so our (low) Tester identity is the initiator and
      // actually dials the friend — isolating the closed-trust gate from the
      // first-mover gate.
      final friend = await _makeHighIdentity('Friend');
      store.dispatch(FriendEstablishedAction(publicKey: friend.publicKey));

      const friendRemoteId = 'FRIEND';
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: friendRemoteId,
        serviceUuids: [friend.bleServiceUuid],
        rssi: -50,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(hostApi.calls.where((c) => c == 'connect:$friendRemoteId'),
          hasLength(1));
    });

    test('closed trust scans ONLY for its friends\' derived UUIDs', () async {
      final friend = await _makeIdentity('Friend');
      store.dispatch(FriendEstablishedAction(publicKey: friend.publicKey));
      store.dispatch(SetColdCallTrustLevelAction(ColdCallTrustLevel.closed));
      hostApi.calls.clear();
      hostApi.scanRequests.clear();

      await transport.start();

      expect(hostApi.scanRequests, hasLength(1));
      final request = hostApi.scanRequests.single;
      // The prefix stays — it is what makes the filter a Grassroots filter —
      // but the scan now carries the friend's candidate UUIDs, so a stranger's
      // advertisement is dropped by the scanner and never reaches us.
      expect(request.serviceUuidPrefix,
          equals(GrassrootsIdentity.grassrootsUuidPrefix));
      expect(
        request.serviceUuids.map((u) => u!.toLowerCase()).toSet(),
        equals(GrassrootsIdentity.candidateServiceUuids(friend.publicKey)),
      );
    });

    test('closed trust with no friends does not scan at all', () async {
      store.dispatch(SetColdCallTrustLevelAction(ColdCallTrustLevel.closed));
      hostApi.calls.clear();
      hostApi.scanRequests.clear();

      await transport.start();

      // An unfiltered prefix scan here would surface exactly the strangers
      // closed trust exists to ignore, so we scan nothing.
      expect(hostApi.scanRequests, isEmpty);
      expect(hostApi.calls.where((c) => c.startsWith('startScan:')), isEmpty);
      expect(hostApi.calls, contains('stopScan'));
      // Advertising continues regardless: a friend added later must still be
      // able to find US, and being findable is not the same as meeting.
      expect(hostApi.calls.where((c) => c.startsWith('startAdvertising:')),
          hasLength(1));
    });

    test('open trust never filters the scan to friends', () async {
      final friend = await _makeIdentity('Friend');
      store.dispatch(FriendEstablishedAction(publicKey: friend.publicKey));
      hostApi.scanRequests.clear();

      await transport.start();

      // Filtering to friends is the behaviour open trust exists to refuse.
      expect(hostApi.scanRequests, hasLength(1));
      expect(hostApi.scanRequests.single.serviceUuids, isEmpty);
    });

    test('closing trust at runtime re-filters the live scan at once', () async {
      final friend = await _makeIdentity('Friend');
      store.dispatch(FriendEstablishedAction(publicKey: friend.publicKey));
      await transport.start();
      // Boot completes when the controller confirms the requested roles —
      // `active` is the booted state, and the trust re-filter gates on it.
      callbacks.pushScanState(BleScanState(active: true));
      callbacks.pushAdvertisingState(BleAdvertisingState(active: true));
      await Future<void>.delayed(Duration.zero);
      hostApi.scanRequests.clear();

      store.dispatch(SetColdCallTrustLevelAction(ColdCallTrustLevel.closed));
      await transport.applyTrustModeChange();

      // Waiting for the scan watchdog would leave the node meeting strangers
      // for up to a silence window after the user asked it to stop.
      expect(hostApi.scanRequests, hasLength(1));
      expect(
        hostApi.scanRequests.single.serviceUuids
            .map((u) => u!.toLowerCase())
            .toSet(),
        equals(GrassrootsIdentity.candidateServiceUuids(friend.publicKey)),
      );
    });
  });

  group('BleTransportService — symmetric connection invariants', () {
    test(
        'a path that is `subscribed` but not yet `ready` does NOT count as '
        'connected', () async {
      final hostApi = _RecordingHostApi();
      final callbacks = FakeGrassrootsBluetoothCallbacks();
      final ble =
          GrassrootsBluetooth.test(hostApi: hostApi, callbacks: callbacks);
      final store = Store<AppState>(appReducer, initialState: AppState.initial);
      store.dispatch(SetColdCallTrustLevelAction(ColdCallTrustLevel.open));
      final transport = BleTransportService(
        identity: await _makeIdentity('Sym'),
        store: store,
        grassrootsBluetooth: ble,
      );
      await transport.initialize();

      callbacks.pushPath(BlePath(
        pathId: 'central:abc',
        role: BleRole.central,
        state: BlePathState.subscribed,
        rssi: -50,
        mtu: 247,
        canSend: false, // not yet sendable
      ));
      await Future<void>.delayed(Duration.zero);

      expect(transport.connectedPeerIds, isEmpty,
          reason: '`subscribed` is mid-handshake; ready+canSend is required '
              'before either side is permitted to claim "connected".');
      await transport.dispose();
    });
  });

  group('BleTransportService — one deterministic initiator per pair', () {
    // "Central" is not a role a peer can claim before a link exists — it is
    // what one BECOMES by dialing. These identities sit at opposite ends of
    // the UUID sort order, which is the rule both sides compute to reach
    // opposite verdicts about who dials.
    const lowPeerUuid = '84c40316-0871-e5ad-0000-000000000001';
    const highPeerUuid = '84c40316-0871-e5ad-ffff-fffffffffffe';

    Future<
        (
          _RecordingHostApi,
          FakeGrassrootsBluetoothCallbacks,
          Store<AppState>,
          BleTransportService,
        )> build(GrassrootsIdentity identity) async {
      final hostApi = _RecordingHostApi();
      final callbacks = FakeGrassrootsBluetoothCallbacks();
      final ble =
          GrassrootsBluetooth.test(hostApi: hostApi, callbacks: callbacks);
      final store = Store<AppState>(appReducer, initialState: AppState.initial);
      store.dispatch(SetColdCallTrustLevelAction(ColdCallTrustLevel.open));
      final transport = BleTransportService(
        identity: identity,
        store: store,
        grassrootsBluetooth: ble,
      );
      await transport.initialize();
      addTearDown(transport.dispose);
      return (hostApi, callbacks, store, transport);
    }

    void sight(FakeGrassrootsBluetoothCallbacks callbacks, String uuid,
        {int rssi = -55, String remoteId = 'PEER'}) {
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: remoteId,
        serviceUuids: [uuid],
        rssi: rssi,
        connectable: true,
      ));
    }

    test('the initiator — lower service UUID — dials on sight', () async {
      final (hostApi, callbacks, _, _) =
          await build(await _makeLowIdentity('Initiator'));
      sight(callbacks, highPeerUuid);
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls.where((c) => c == 'connect:PEER'), hasLength(1));
    });

    test('a second sighting while the dial is still being placed does not '
        'dial again', () async {
      // The plugin reports every scan result of an undialled address as a
      // `discovered` path event, and the next advertisement follows it. A
      // dial takes a platform-channel round trip to place, so a sighting can
      // land in that gap: measured in the ring runs as two dialIssued
      // records for the same address 12-14 ms apart, both counting zero
      // dials in flight.
      final (hostApi, callbacks, _, _) =
          await build(await _makeLowIdentity('Initiator'));
      hostApi.holdConnect = true;
      sight(callbacks, highPeerUuid);
      await Future<void>.delayed(Duration.zero);
      callbacks.pushPath(BlePath(
        pathId: 'central:PEER',
        role: BleRole.central,
        state: BlePathState.discovered,
        rssi: -55,
        mtu: 23,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);
      sight(callbacks, highPeerUuid, rssi: -54);
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls.where((c) => c == 'connect:PEER'), hasLength(1),
          reason: 'the first dial is still being placed; a second connectGatt '
              'to the same address is the 133 that follows');
    });

    test('a rotated address seen while the dial is still being placed is not '
        'dialled alongside it', () async {
      // Same peer, fresh random address, same gap: the first dial is in the
      // channel and has no path to show for it yet. Two connectGatts to one
      // peer over two addresses are the status-133 storm the one-central-leg
      // rule exists to prevent.
      final (hostApi, callbacks, _, _) =
          await build(await _makeLowIdentity('Initiator'));
      hostApi.holdConnect = true;
      sight(callbacks, highPeerUuid, remoteId: 'OLD');
      await Future<void>.delayed(Duration.zero);
      sight(callbacks, highPeerUuid, remoteId: 'NEW');
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls.where((c) => c.startsWith('connect:')),
          ['connect:OLD']);
    });

    test('the higher peer holds its dial, so the pair is never both-dialing',
        () async {
      // The property that matters: two in-flight connectGatts leave both
      // stacks deaf, and a deadlock nothing can signal away costs a full
      // connect timeout — measured at ~30% of windows at 20 s each.
      final (hostApi, callbacks, _, _) =
          await build(await _makeHighIdentity('Waiter'));
      sight(callbacks, lowPeerUuid);
      await Future<void>.delayed(Duration.zero);
      sight(callbacks, lowPeerUuid, rssi: -54);
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls.where((c) => c.startsWith('connect:')), isEmpty,
          reason: 'inside the grace the initiator dials uncontested');
    });

    test('the higher peer dials once the grace passes — an initiator that '
        'never comes must not strand the pair', () async {
      final (hostApi, callbacks, _, _) =
          await build(await _makeHighIdentity('Waiter'));
      sight(callbacks, lowPeerUuid);
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls.where((c) => c.startsWith('connect:')), isEmpty);

      // 1.5 s of grace — a few connect-latencies, not the five seconds that
      // made the ordering look like the culprit.
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      sight(callbacks, lowPeerUuid, rssi: -54);
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls.where((c) => c == 'connect:PEER'), hasLength(1),
          reason: 'the fallback still exists; only its constant changed');
    });

    test('an inbound leg needs no grace: the reverse dial goes at once',
        () async {
      // Holding here would be waiting for a race already lost — the peer's
      // link is up, and this dial attaches over its ACL rather than racing.
      const connectionMac = '99:88:77:66:55:42';
      final (hostApi, callbacks, store, transport) =
          await build(await _makeHighIdentity('Waiter'));
      final peer = await _makeIdentity('Remote');
      callbacks.pushPath(BlePath(
        pathId: 'peripheral:$connectionMac',
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: null,
        mtu: 517,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      store.dispatch(PeerAnnounceReceivedAction(
        publicKey: peer.publicKey,
        nickname: 'Remote',
        transport: PeerTransport.bleDirect,
        blePeripheralDeviceId: 'peripheral:$connectionMac',
      ));
      hostApi.calls.clear();
      transport.onPeerIdentified('peripheral:$connectionMac', peer.publicKey);
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls.where((c) => c == 'connect:$connectionMac'),
          hasLength(1));
    });
  });



  group('BleTransportService — testbed dial cap', () {
    // Fixed peer UUIDs above the initiator threshold: the transport under
    // test is built with a LOW identity, so it is always the election's
    // initiator and every advertisement below auto-dials. That greedy dial
    // is the mechanism the grid measures — the cap is a bound ON it, never
    // a replacement for it.
    String peerUuid(int i) =>
        '84c40316-0871-e5ad-aaaa-00000000000${i.toRadixString(16)}';

    late _RecordingHostApi hostApi;
    late FakeGrassrootsBluetoothCallbacks callbacks;
    late Store<AppState> store;
    late _CapturingTrace trace;
    late BleTransportService transport;

    setUp(() async {
      hostApi = _RecordingHostApi();
      callbacks = FakeGrassrootsBluetoothCallbacks();
      final ble = GrassrootsBluetooth.test(hostApi: hostApi, callbacks: callbacks);
      store = Store<AppState>(appReducer, initialState: AppState.initial);
      store.dispatch(SetColdCallTrustLevelAction(ColdCallTrustLevel.open));
      trace = _CapturingTrace();
      await trace.startExperiment('dial-cap');
      transport = BleTransportService(
        identity: await _makeLowIdentity('Prober'),
        store: store,
        grassrootsBluetooth: ble,
        trace: trace,
      );
      await transport.initialize();
    });

    tearDown(() async {
      await transport.dispose();
    });

    Future<void> adv(int i, {int rssi = -55}) async {
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: 'MAC$i',
        serviceUuids: [peerUuid(i)],
        rssi: rssi,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);
    }

    /// What the plugin does after a `connect()` it accepted: the path shows
    /// up as `connecting`. Only then does the dial occupy a slot, exactly as
    /// on a device — the cap reads `_paths`, not the calls we made.
    Future<void> pushState(int i, BlePathState state) async {
      callbacks.pushPath(BlePath(
        pathId: 'central:MAC$i',
        role: BleRole.central,
        state: state,
        rssi: -55,
        mtu: state == BlePathState.ready ? 247 : 23,
        canSend: state == BlePathState.ready,
      ));
      await Future<void>.delayed(Duration.zero);
    }

    int dials(int i) =>
        hostApi.calls.where((c) => c == 'connect:MAC$i').length;

    test('the cap defaults to the production value', () {
      expect(transport.maxInFlightCentralDials,
          BleTransportService.defaultMaxInFlightCentralDials);
      expect(BleTransportService.defaultMaxInFlightCentralDials, 1,
          reason: 'The Android stack runs one LE connection attempt at a '
              'time and queues the rest. Our per-dial deadline cancelling a '
              'QUEUED dial is refused by the stack and leaves that address '
              'failing instantly until a link to it comes and goes; with one '
              'dial in flight every cancel hits a dial the stack started.');
    });

    test('at the production cap a second sighting waits for the first dial',
        () async {
      await adv(1);
      expect(dials(1), 1);
      await pushState(1, BlePathState.connecting);

      await adv(2);
      expect(dials(2), 0,
          reason: 'A second dial would sit in the stack\'s queue, where the '
              'deadline cannot cancel it cleanly.');
      final skip = trace.records.lastWhere(
          (r) => r['type'] == 'link' && r['event'] == 'dialSkip');
      expect(skip['path'], 'central:MAC2');
      expect(skip['reason'], 'dialCap');

      await pushState(1, BlePathState.ready);
      await adv(2);
      expect(dials(2), 1, reason: 'The next sighting takes the freed slot.');
    });

    test('setDialParallelism sets the cap and restores it on null', () {
      transport.setDialParallelism(maxParallel: 2, popN: 5);
      expect(transport.maxInFlightCentralDials, 2);
      expect(transport.dialProbeMaxParallel, 2);
      expect(transport.dialProbePopN, 5);

      transport.setDialParallelism();
      expect(transport.maxInFlightCentralDials, 1,
          reason: 'A null M is how the runner puts production behaviour back '
              'when a run ends; nothing else ever writes this field.');
      expect(transport.dialProbeMaxParallel, isNull);
      expect(transport.dialProbePopN, isNull);
    });

    test('with the cap at M, never more than M central dials are in flight',
        () async {
      transport.setDialParallelism(maxParallel: 2, popN: 5);
      // Four peers appear. The transport wants to dial all four — that
      // greedy behaviour is untouched — but only two may be underway.
      for (var i = 1; i <= 4; i++) {
        await adv(i);
        if (dials(i) > 0) await pushState(i, BlePathState.connecting);
        expect(store.state.peers.discoveredBlePeersList.length, i);
      }

      final inFlight = [for (var i = 1; i <= 4; i++) if (dials(i) > 0) i];
      expect(inFlight, [1, 2],
          reason: 'The third and fourth advertisements are refused at the '
              'choke point while two dials occupy the cap.');
      expect(dials(3), 0);
      expect(dials(4), 0);
    });

    test('a freed slot lets a waiting peer dial — the cap tops up', () async {
      transport.setDialParallelism(maxParallel: 1, popN: 3);
      await adv(1);
      await pushState(1, BlePathState.connecting);
      await adv(2);
      expect(dials(2), 0, reason: 'One slot, and peer 1 is holding it.');

      // Peer 1 lands. A `ready` path has finished dialing, so it no longer
      // occupies an in-flight slot.
      await pushState(1, BlePathState.ready);
      // The scanner runs allowDuplicates: peer 2 re-advertises, and THAT is
      // the top-up — the election refires on its own, nothing re-drives it.
      await adv(2);
      expect(dials(2), 1);
      await pushState(2, BlePathState.connecting);

      await adv(3);
      expect(dials(3), 0,
          reason: 'The freed slot was taken by peer 2; the cap still holds.');
    });

    test('a sighting reported as a `discovered` path is not tracked', () async {
      // An advertisement is a sighting of an address, not a connection. A
      // rotating peer mints a fresh address every slot, so a table keeping
      // one entry per address seen grows for the life of the run while the
      // number of links stays under the controller's ceiling. Only a path
      // the plugin holds a connection object for belongs in the table.
      for (var i = 0; i < 50; i++) {
        callbacks.pushPath(BlePath(
          pathId: 'central:RPA$i',
          role: BleRole.central,
          state: BlePathState.discovered,
          rssi: -55,
          mtu: 23,
          canSend: false,
        ));
      }
      await Future<void>.delayed(Duration.zero);
      await adv(1);

      final rec = trace.records.lastWhere(
          (r) => r['type'] == 'link' && r['event'] == 'dialIssued');
      expect(rec['pathsTracked'], 0);
      expect(rec['pathsTrackedCentral'], 0);
    });

    test('the establishment is the LINK coming up, not `ready`', () async {
      // Anchoring the count on `ready` conflated three outcomes: reaching
      // `ready` also needs the peer's ANNOUNCE to identify the path, so a
      // link that demonstrably established was reported as a failed dial
      // whenever announces were not flowing (dial-3-cap-greedy-n6: 181 GATT
      // links up, ~0 establishments recorded).
      transport.setDialParallelism(maxParallel: 3, popN: 6);
      await adv(1);
      await pushState(1, BlePathState.connecting);
      await adv(2);
      await pushState(2, BlePathState.connecting);
      // Peer 1's link comes up while peer 2's dial is still underway.
      await pushState(1, BlePathState.connected);

      final rec = trace.records.lastWhere(
          (r) => r['type'] == 'link' && r['event'] == 'gattConnected');
      expect(rec['role'], 'central');
      expect(rec['establishment'], isTrue);
      expect(rec['inFlight'], 2,
          reason: 'Both dials hold a slot: this one is `connected` but not '
              'yet `ready`, and the cap counts it too — so the field runs '
              '1..M and equals M when saturated.');
      expect(rec['maxParallel'], 3);
      expect(rec['popN'], 6);
      expect(rec['peripheralLinks'], 0);
      expect(rec['totalLinks'], 1,
          reason: 'A slot is held from GATT connect, not from `ready` — this '
              'link is already consuming the controller budget.');

      // Reaching `ready` later is its own stage and must NOT re-count.
      await pushState(1, BlePathState.ready);
      expect(transport.establishmentCount, 1);
      final ready = trace.records.lastWhere(
          (r) => r['type'] == 'link' && r['event'] == 'connected');
      expect(ready.containsKey('establishment'), isFalse);
    });

    test('an establishment counts the inbound legs sharing the link budget',
        () async {
      transport.setDialParallelism(maxParallel: 2, popN: 8);
      // Two peers dialed US: inbound legs nothing caps, because only a
      // central issues connectGatt and nothing limits accepting.
      for (final mac in ['IN1', 'IN2']) {
        callbacks.pushPath(BlePath(
          pathId: 'peripheral:$mac',
          role: BleRole.peripheral,
          state: BlePathState.ready,
          rssi: -55,
          mtu: 247,
          canSend: true,
        ));
      }
      await Future<void>.delayed(Duration.zero);
      await adv(1);
      await pushState(1, BlePathState.connecting);
      await pushState(1, BlePathState.connected);

      final rec = trace.records.lastWhere((r) =>
          r['type'] == 'link' && r['event'] == 'gattConnected' &&
          r['role'] == 'central');
      expect(rec['peripheralLinks'], 2);
      expect(rec['totalLinks'], 3,
          reason: 'Both roles draw on ONE controller link budget, so a '
              'failure at high N has to be separable from "out of slots".');
      expect(rec['inFlight'], 1,
          reason: 'this dial itself still holds a slot at `connected`');
    });

    test('an inbound peripheral leg carries no dial context', () async {
      transport.setDialParallelism(maxParallel: 3, popN: 6);
      callbacks.pushPath(BlePath(
        pathId: 'peripheral:INBOUND',
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: -55,
        mtu: 247,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);

      final rec = trace.records.lastWhere(
          (r) => r['type'] == 'link' && r['event'] == 'connected');
      expect(rec['role'], 'peripheral');
      expect(rec.containsKey('establishment'), isFalse,
          reason: 'The grid counts what this phone DIALED; a leg someone '
              'else opened is not an establishment of ours.');
      expect(rec.containsKey('inFlight'), isFalse,
          reason: 'in-flight dials are a central-side fact');
      // maxParallel/popN DO ride every stage record: they are the step's
      // context, not a claim that this leg was an establishment. The analyzer
      // needs them on each stage to join stages to their (N, M) cell.
      expect(rec['maxParallel'], 3);
      expect(rec['popN'], 6);
    });

    test('establishmentCount counts central legs and resets on demand',
        () async {
      transport.setDialParallelism(maxParallel: 2, popN: 4);
      expect(transport.establishmentCount, 0);

      await adv(1);
      await pushState(1, BlePathState.connecting);
      await pushState(1, BlePathState.connected);
      expect(transport.establishmentCount, 1,
          reason: 'counted when the link came up');
      await pushState(1, BlePathState.ready);
      expect(transport.establishmentCount, 1,
          reason: '`ready` is a later stage, not a second establishment');

      // An inbound leg is not ours to count.
      callbacks.pushPath(BlePath(
        pathId: 'peripheral:INBOUND',
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: -55,
        mtu: 247,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(transport.establishmentCount, 1);

      transport.resetEstablishmentCount();
      expect(transport.establishmentCount, 0);
    });

    test('a second leg to an already-linked peer in the same role is dropped',
        () async {
      // Android rotates its advertised address and the plugin surfaces no
      // rotation event, so the same phone is rediscovered under a new address
      // and dialed again — connectGatt opens a SECOND real connection to
      // hardware we already hold a leg to. Measured on dial-5: 32 same-role
      // duplicates across six phones, overlapping up to 69s, each consuming a
      // controller slot the dial cap then denies to a genuinely new peer.
      final peer = Uint8List.fromList(List.generate(32, (i) => i + 7));
      for (final mac in ['AA:1', 'BB:2']) {
        callbacks.pushPath(BlePath(
          pathId: 'central:$mac',
          role: BleRole.central,
          state: BlePathState.ready,
          rssi: -50,
          mtu: 247,
          canSend: true,
        ));
      }
      await Future<void>.delayed(Duration.zero);

      // First identification: nothing to compare against, so it stands.
      transport.onPeerIdentified('central:AA:1', peer);
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty);

      // The rotated address resolves to the SAME peer in the SAME role.
      transport.onPeerIdentified('central:BB:2', peer);
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls, contains('disconnect:central:BB:2'),
          reason: 'the new duplicate goes, not the proven leg');
      expect(hostApi.calls, isNot(contains('disconnect:central:AA:1')));
    });

    test('the opposite role is NOT a duplicate — that is the dual-leg pair',
        () async {
      // Every pair is REQUIRED to converge to two legs, one per role. A
      // check that keyed on peer alone would tear the pair down.
      final peer = Uint8List.fromList(List.generate(32, (i) => i + 11));
      callbacks.pushPath(BlePath(
        pathId: 'central:CC:3',
        role: BleRole.central,
        state: BlePathState.ready,
        rssi: -50, mtu: 247, canSend: true,
      ));
      callbacks.pushPath(BlePath(
        pathId: 'peripheral:CC:3',
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: -50, mtu: 247, canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      transport.onPeerIdentified('central:CC:3', peer);
      transport.onPeerIdentified('peripheral:CC:3', peer);
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty,
          reason: 'one leg per role is the design, not a duplicate');
    });

    test('an address that never reaches ready is pruned; a ready one is not',
        () async {
      // Nothing else removes it: _paths.remove runs only from a plugin-reported
      // failed/disconnected/stale, so a peer that vanishes without the OS
      // saying so is counted forever — against the dial cap and against the
      // controller slot count. dial-6-n8: 300 of 1419 paths that came up (21%)
      // never reached ready and never dropped.
      await adv(1);
      await pushState(1, BlePathState.connecting);
      await pushState(1, BlePathState.connected);
      await adv(2);
      await pushState(2, BlePathState.connecting);
      await pushState(2, BlePathState.connected);
      await pushState(2, BlePathState.ready);

      // Not yet old enough — neither goes.
      transport.pruneNeverReadyPathsNow();
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty);

      // Age BOTH past the timeout. Only the one still short of `ready` dies:
      // a live link must never be reaped for being long-lived.
      transport.ageNotReadyForTest('central:MAC1', const Duration(seconds: 121));
      transport.ageNotReadyForTest('central:MAC2', const Duration(seconds: 121));
      transport.pruneNeverReadyPathsNow();
      await Future<void>.delayed(Duration.zero);

      expect(hostApi.calls, contains('disconnect:central:MAC1'),
          reason: 'stuck at `connected` for a full dwell — it is not coming');
      expect(hostApi.calls, isNot(contains('disconnect:central:MAC2')),
          reason: 'reached ready, so age is irrelevant');
      final rec = trace.records.singleWhere((r) => r['event'] == 'pruned');
      expect(rec['path'], 'central:MAC1');
      expect(rec['reason'], 'neverReady');
      expect(rec['stuckState'], 'connected',
          reason: 'the link came up and the peer never identified itself — '
              'distinct from a dial that never landed');
    });

    test('the failed-dial cooldown still refuses a redial', () async {
      transport.setDialParallelism(maxParallel: 4, popN: 5);
      await adv(2);
      final afterDial = dials(2);
      await pushState(2, BlePathState.failed);

      expect(await transport.connectToDevice('central:MAC2'), isFalse,
          reason: 'The cooldown is production behaviour and the grid leaves '
              'it exactly as it is — only the cap is the variable.');
      expect(dials(2), afterDial);
    });
  });

  group('BleTransportService — active means booted', () {
    late _RecordingHostApi hostApi;
    late FakeGrassrootsBluetoothCallbacks callbacks;
    late Store<AppState> store;
    late BleTransportService transport;

    Future<void> build(BleRoleMode mode) async {
      hostApi = _RecordingHostApi();
      callbacks = FakeGrassrootsBluetoothCallbacks();
      final ble =
          GrassrootsBluetooth.test(hostApi: hostApi, callbacks: callbacks);
      store = Store<AppState>(appReducer, initialState: AppState.initial);
      store.dispatch(SetBleRoleModeAction(mode));
      transport = BleTransportService(
        identity: await _makeIdentity('Boot'),
        store: store,
        grassrootsBluetooth: ble,
      );
      await transport.initialize();
      await transport.start();
      await Future<void>.delayed(Duration.zero);
    }

    tearDown(() async => transport.dispose());

    TransportState st() => store.state.transports.bleState;

    test('the requests returning does not boot the service', () async {
      await build(BleRoleMode.auto);
      expect(st(), TransportState.ready,
          reason: 'accepted requests are intent; active reports the fact');

      callbacks.pushScanState(BleScanState(active: true));
      await Future<void>.delayed(Duration.zero);
      expect(st(), TransportState.ready,
          reason: 'the mode asked for both roles; one confirmation is half '
              'a boot');

      callbacks.pushAdvertisingState(BleAdvertisingState(active: true));
      await Future<void>.delayed(Duration.zero);
      expect(st(), TransportState.active,
          reason: 'every requested role confirmed on the air — booted');
    });

    test('central-only boots on the scanner alone', () async {
      await build(BleRoleMode.centralOnly);
      callbacks.pushScanState(BleScanState(active: true));
      await Future<void>.delayed(Duration.zero);
      expect(st(), TransportState.active,
          reason: 'a mode that never advertises has nothing else to confirm');
    });

    test('a refused advertiser keeps the service un-booted', () async {
      await build(BleRoleMode.auto);
      callbacks.pushScanState(BleScanState(active: true));
      callbacks.pushAdvertisingState(BleAdvertisingState(
          active: false,
          failure: BleAdvertiseFailure.transient,
          reason: 'slots taken'));
      await Future<void>.delayed(Duration.zero);
      expect(st(), TransportState.ready,
          reason: 'scanning alone is the half-booted phone nobody can find');

      callbacks.pushAdvertisingState(BleAdvertisingState(active: true));
      await Future<void>.delayed(Duration.zero);
      expect(st(), TransportState.active,
          reason: 'the retry landing completes the boot');
    });

    test('the watchdog restarting the scan does not un-boot the service',
        () async {
      await build(BleRoleMode.auto);
      callbacks.pushScanState(BleScanState(active: true));
      callbacks.pushAdvertisingState(BleAdvertisingState(active: true));
      await Future<void>.delayed(Duration.zero);
      expect(st(), TransportState.active);

      // A deliberate stop carries no reason — the watchdog's own restart, a
      // mode change. Boot regressions carry the controller's refusal.
      callbacks.pushScanState(BleScanState(active: false));
      await Future<void>.delayed(Duration.zero);
      expect(st(), TransportState.active,
          reason: 'a deliberate stop is not a boot regression, and a marker '
              'flicker here would poison every establishment anchor');
    });

    test('a kept advertiser is not trusted: the next boot waits for a fresh '
        'answer', () async {
      await build(BleRoleMode.auto);
      callbacks.pushScanState(BleScanState(active: true));
      callbacks.pushAdvertisingState(BleAdvertisingState(active: true));
      await Future<void>.delayed(Duration.zero);
      expect(st(), TransportState.active);

      await transport.stop(keepAdvertiser: true);
      expect(st(), TransportState.ready);
      expect(hostApi.calls, isNot(contains('stopAdvertising')),
          reason: 'the set stays on the air at its address — that is what '
              'the keep is for');

      hostApi.calls.clear();
      await transport.start();
      callbacks.pushScanState(BleScanState(active: true));
      await Future<void>.delayed(Duration.zero);
      expect(st(), TransportState.ready,
          reason: 'legacy advertising ends at the controller on every '
              'accepted connection; what the last transport heard says '
              'nothing about now, and assuming it did left a fleet '
              'undiscoverable');
      expect(hostApi.calls, contains(startsWith('startAdvertising:')),
          reason: 'the plugin is asked again — it is the one that can '
              'verify the set with the controller');

      callbacks.pushAdvertisingState(BleAdvertisingState(
          active: true, reason: 'enabled by this plugin'));
      await Future<void>.delayed(Duration.zero);
      expect(st(), TransportState.active,
          reason: 'the controller answered — now it is a fact');
    });

    test('dispose with keepAdvertiser drops every link and keeps the set',
        () async {
      await build(BleRoleMode.auto);
      callbacks.pushPath(BlePath(
        pathId: 'peripheral:KEPT',
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: null,
        mtu: 247,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      hostApi.calls.clear();

      await transport.dispose(keepAdvertiser: true);

      expect(hostApi.calls, contains('disconnect:peripheral:KEPT'),
          reason: 'links are what a bounce resets');
      expect(hostApi.calls, isNot(contains('stopAdvertising')));
      expect(hostApi.calls, contains('dispose:keep=true'),
          reason: 'the plugin owns the set and is told to keep it');
    });

    test('a plain dispose still takes the advertiser down', () async {
      await build(BleRoleMode.auto);
      hostApi.calls.clear();
      await transport.dispose();
      expect(hostApi.calls, contains('stopAdvertising'));
      expect(hostApi.calls, contains('dispose:keep=false'));
    });
  });

  group('BleTransportService — scan-liveness watchdog', () {
    late _RecordingHostApi hostApi;
    late FakeGrassrootsBluetoothCallbacks callbacks;
    late Store<AppState> store;
    late BleTransportService transport;

    setUp(() async {
      hostApi = _RecordingHostApi();
      callbacks = FakeGrassrootsBluetoothCallbacks();
      final ble =
          GrassrootsBluetooth.test(hostApi: hostApi, callbacks: callbacks);
      store = Store<AppState>(appReducer, initialState: AppState.initial);
      // The suite exercises open-mode dialing toward unknown peers; the
      // default trust level is closed.
      store.dispatch(SetColdCallTrustLevelAction(ColdCallTrustLevel.open));
      transport = BleTransportService(
        identity: await _makeIdentity('Watchdog'),
        store: store,
        grassrootsBluetooth: ble,
      );
      await transport.initialize();
      addTearDown(transport.dispose);
    });

    test('does not restart the scan while advertisements are flowing',
        () async {
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: 'PEER',
        serviceUuids: ['84c40316-0871-e5ad-2222-000000000000'],
        rssi: -55,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);
      hostApi.calls.clear();

      await transport.checkScanLiveness(now: DateTime.now());

      expect(hostApi.calls.where((c) => c.startsWith('startScan:')), isEmpty,
          reason: 'A recent advertisement proves the scanner is alive.');
    });

    test(
        'restarts the scan after prolonged silence, once per silence window',
        () async {
      callbacks.pushAdvertisement(BleAdvertisement(
        remoteId: 'PEER',
        serviceUuids: ['84c40316-0871-e5ad-2222-000000000000'],
        rssi: -55,
        connectable: true,
      ));
      await Future<void>.delayed(Duration.zero);
      hostApi.calls.clear();

      final silent = DateTime.now().add(const Duration(seconds: 31));
      await transport.checkScanLiveness(now: silent);
      expect(hostApi.calls.where((c) => c.startsWith('startScan:')),
          hasLength(1),
          reason: '31s of silence in a scanning role means a muted scanner — '
              'restart it.');

      // The next tick inside the same window must not restart again.
      await transport.checkScanLiveness(
          now: silent.add(const Duration(seconds: 1)));
      expect(hostApi.calls.where((c) => c.startsWith('startScan:')),
          hasLength(1),
          reason: 'The restart resets the silence clock — at most one '
              'restart per window.');
    });

    test('never restarts in peripheral-only mode', () async {
      store.dispatch(SetBleRoleModeAction(BleRoleMode.peripheralOnly));
      await transport.checkScanLiveness(
          now: DateTime.now().add(const Duration(minutes: 5)));
      expect(hostApi.calls.where((c) => c.startsWith('startScan:')), isEmpty,
          reason: 'Peripheral-only devices do not scan; the watchdog must '
              'not start one.');
    });

    test(
        'a silent restart is hardware-filtered for a peer we hold only a '
        'peripheral leg from (so its advertising MAC is discoverable)',
        () async {
      // The peer connected to us (we are its GATT server): a ready peripheral
      // leg, ANNOUNCE-identified, with no central leg back. This is exactly
      // the stranded-single-link state where an unfiltered scan gets muted.
      final peer = await _makeIdentity('StuckPeer');
      const peripheralPathId = 'peripheral:AA:BB:CC:DD:EE:FF';
      callbacks.pushPath(BlePath(
        pathId: peripheralPathId,
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: -55,
        mtu: 247,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      store.dispatch(PeerAnnounceReceivedAction(
        publicKey: peer.publicKey,
        nickname: 'StuckPeer',
        transport: PeerTransport.bleDirect,
        blePeripheralDeviceId: peripheralPathId,
      ));
      await Future<void>.delayed(Duration.zero);
      hostApi.scanRequests.clear();

      await transport.checkScanLiveness(
          now: DateTime.now().add(const Duration(seconds: 31)));

      expect(hostApi.scanRequests, isNotEmpty,
          reason: 'Silence with a pending reverse leg must restart the scan.');
      final targets = hostApi.scanRequests.last.serviceUuids;
      final wanted = GrassrootsIdentity.candidateServiceUuids(peer.publicKey);
      for (final uuid in wanted) {
        expect(targets, contains(uuid),
            reason: "The peer's candidate UUIDs must be installed as hardware "
                'scan filters so Android reliably surfaces its advertisement.');
      }
    });

    test('a plain silent restart carries no hardware filters (broad scan)',
        () async {
      // No peripheral-only-attached peers → nothing to target → broad scan,
      // preserving normal discovery.
      await transport.checkScanLiveness(
          now: DateTime.now().add(const Duration(seconds: 31)));
      expect(hostApi.scanRequests.last.serviceUuids, isEmpty,
          reason: 'With no stranded reverse leg the scan stays unfiltered so '
              'new peers keep being discovered.');
    });
  });

  group('BleTransportService — retry on the pair\'s other leg', () {
    late _RecordingHostApi hostApi;
    late FakeGrassrootsBluetoothCallbacks callbacks;
    late Store<AppState> store;
    late BleTransportService transport;
    late _CapturingTrace trace;

    setUp(() async {
      hostApi = _RecordingHostApi();
      callbacks = FakeGrassrootsBluetoothCallbacks();
      final ble =
          GrassrootsBluetooth.test(hostApi: hostApi, callbacks: callbacks);
      store = Store<AppState>(appReducer, initialState: AppState.initial);
      store.dispatch(SetColdCallTrustLevelAction(ColdCallTrustLevel.open));
      trace = _CapturingTrace();
      await trace.startExperiment('other-leg');
      transport = BleTransportService(
        identity: await _makeIdentity('Sender'),
        store: store,
        grassrootsBluetooth: ble,
        trace: trace,
        writeAckTimeout: const Duration(milliseconds: 100),
      );
      await transport.initialize();
      addTearDown(transport.dispose);
    });

    /// A converged pair: both GATT legs ready and both attributed to one
    /// identity, which is the only state in which a fallback is possible.
    Future<GrassrootsIdentity> convergedPair({
      String centralPathId = 'central:PAIR',
      String peripheralPathId = 'peripheral:PAIR',
      int centralMtu = 247,
      int peripheralMtu = 247,
    }) async {
      final peer = await _makeIdentity('PairPeer');
      callbacks.pushPath(BlePath(
        pathId: centralPathId,
        role: BleRole.central,
        state: BlePathState.ready,
        rssi: -50,
        mtu: centralMtu,
        canSend: true,
      ));
      callbacks.pushPath(BlePath(
        pathId: peripheralPathId,
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: null,
        mtu: peripheralMtu,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      store.dispatch(PeerAnnounceReceivedAction(
        publicKey: peer.publicKey,
        nickname: 'PairPeer',
        transport: PeerTransport.bleDirect,
        bleCentralDeviceId: centralPathId,
        blePeripheralDeviceId: peripheralPathId,
      ));
      // An ANNOUNCE attaches its leg in Redux and identifies the same leg on
      // the transport in one step (MessageRouter dispatches the action, then
      // calls onBlePeerIdentified). A leg Redux knows and the transport does
      // not cannot occur, so a pair attributed on both legs was identified on
      // both.
      transport.onPeerIdentified(centralPathId, peer.publicKey);
      transport.onPeerIdentified(peripheralPathId, peer.publicKey);
      await Future<void>.delayed(Duration.zero);
      hostApi.calls.clear();
      return peer;
    }

    test("a refused write falls back to the pair's OTHER leg", () async {
      await convergedPair();
      // The flood prefers our peripheral leg, and the peripheral leg is the
      // one with no queue behind it — so it is the one that refuses first.
      hostApi.refuse.add('peripheral:PAIR');

      final aired = await transport.broadcast(Uint8List(40));

      expect(aired, 1,
          reason: 'The neighbour was reached — on the other leg, but reached.');
      expect(hostApi.calls, [
        'send:peripheral:PAIR:40',
        'send:central:PAIR:40',
      ], reason: 'Refused on the preferred leg, then written on the other. '
          'The order matters: the fallback is a consequence of the failure, '
          'never a second copy sent alongside the first.');
    });



    /// Rotate the pair's peripheral leg: a fresh address arrives, is
    /// identified, and the address it replaced then drops. Redux holds ONE
    /// peripheral device id per peer, so the rotation overwrites the slot and
    /// the drop clears it — while the ORIGINAL leg is still ready and still
    /// known to the transport by path. A peer presented up to 21 addresses to
    /// one device in thirty minutes, so this is the steady state, not an edge.
    Future<void> rotatePeripheralOnto(
        GrassrootsIdentity peer, String freshPathId) async {
      callbacks.pushPath(BlePath(
        pathId: freshPathId,
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: null,
        mtu: 247,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      store.dispatch(PeerAnnounceReceivedAction(
        publicKey: peer.publicKey,
        nickname: 'PairPeer',
        transport: PeerTransport.bleDirect,
        blePeripheralDeviceId: freshPathId,
      ));
      transport.onPeerIdentified(freshPathId, peer.publicKey);
      await Future<void>.delayed(Duration.zero);
      callbacks.pushPath(BlePath(
        pathId: freshPathId,
        role: BleRole.peripheral,
        state: BlePathState.disconnected,
        rssi: null,
        mtu: 247,
        canSend: false,
      ));
      await Future<void>.delayed(Duration.zero);
      hostApi.calls.clear();
    }

    test('a live peripheral leg the rotation orphaned is still the data leg',
        () async {
      final peer = await convergedPair();
      await rotatePeripheralOnto(peer, 'peripheral:PAIR2');

      expect(transport.isDeviceConnected('peripheral:PAIR'), isTrue,
          reason: 'The original leg never dropped — only the address that '
              'briefly superseded it did.');
      expect(transport.getPeerIdForPubkey(peer.publicKey), 'peripheral:PAIR',
          reason: 'Identity is a fact about the PATH, and the transport holds '
              'it per path. Redux keeps one device id per role per peer and '
              'cannot represent a rotation in flight, so asking it sends data '
              'to the acknowledged leg — one ATT op slot, and every write '
              'that arrives meanwhile refused as write-busy.');
    });

    test('a busy central write is rescued onto the orphaned peripheral leg',
        () async {
      final peer = await convergedPair();
      await rotatePeripheralOnto(peer, 'peripheral:PAIR2');

      hostApi.busy.add('central:PAIR');
      expect(
          await transport.sendToPeer('central:PAIR', Uint8List(40)), isTrue,
          reason: 'A busy op slot is a collision with our own traffic, and '
              'the pair still holds a live notify leg to carry the frame.');
      expect(hostApi.calls, [
        'send:central:PAIR:40',
        'send:peripheral:PAIR:40',
      ], reason: 'otherLegFor must find the live peripheral leg. Resolving it '
          'through Redux instead returns null and the conveyance is lost.');
    });

    test('a link record says whether the peer projection still names the path',
        () async {
      final peer = await convergedPair();
      Map<String, dynamic> lastIdentified() => trace.records.lastWhere(
          (r) => r['type'] == 'link' && r['event'] == 'identified');

      transport.onPeerIdentified('peripheral:PAIR', peer.publicKey);
      expect(lastIdentified()['reduxAttached'], isTrue,
          reason: 'Both authorities agree while the pair is settled.');

      await rotatePeripheralOnto(peer, 'peripheral:PAIR2');
      transport.onPeerIdentified('peripheral:PAIR', peer.publicKey);

      final record = lastIdentified();
      expect(record['peer'], isNotNull,
          reason: 'The transport still knows whose leg this is.');
      expect(record['reduxAttached'], isFalse,
          reason: 'The rotation took PeerState\'s one peripheral slot with '
              'it. Sends no longer care — identity comes from the per-path '
              'record — and this field is how a run counts the legs that '
              'would once have been unsendable.');
    });

    test('a write that succeeds never touches the second leg', () async {
      await convergedPair();
      final aired = await transport.broadcast(Uint8List(40));
      expect(aired, 1);
      expect(hostApi.calls, ['send:peripheral:PAIR:40'],
          reason: 'One leg per peer per flood: the same bytes on both legs is '
              'double airtime for a copy the packetId bloom drops.');
    });

    test('both legs refusing reports the neighbour as not reached', () async {
      await convergedPair();
      hostApi.refuse.addAll({'peripheral:PAIR', 'central:PAIR'});
      expect(await transport.broadcast(Uint8List(40)), 0);
      expect(hostApi.calls, hasLength(2),
          reason: 'Each leg is tried exactly once — no retry loop.');
    });

    test('sendToPeer falls back too (sync conveyance, directed sends)',
        () async {
      await convergedPair();
      hostApi.refuse.add('central:PAIR');
      expect(await transport.sendToPeer('central:PAIR', Uint8List(40)), isTrue);
      expect(hostApi.calls.last, 'send:peripheral:PAIR:40');
    });

    test('a write the stack never answers does not wedge the leg forever',
        () async {
      // The failure this bound exists for. An acknowledged central write waits
      // for its ATT response, and the plugin serialises GATT ops per path — so
      // a write that is accepted and then never answered stops that path dead:
      // every later message to the peer queues behind it and no caller is ever
      // replied to. Measured on 2026-09-01, one leg went quiet mid-run and
      // that ordered pair carried nothing for the remaining five minutes,
      // while the same device's other paths were untouched.
      //
      // A timeout turns the hang into a refusal, which the existing machinery
      // already knows how to survive: retry the pair's other leg, and leave
      // the packet in the DTN buffer either way.
      await convergedPair();
      hostApi.swallow.add('central:PAIR');
      expect(
        await transport
            .sendToPeer('central:PAIR', Uint8List(40))
            .timeout(const Duration(seconds: 30)),
        isFalse,
        reason: 'the unanswered write times out and is reported failed — the '
            'DTN buffer and the sync exchange are what redeliver it',
      );
      // And NOT on the other leg. The fallback exists for a refusal, where the
      // bytes provably never reached the controller; here they were accepted
      // and may already be on the air, so a retry would be the double-send the
      // one-leg-per-flood rule forbids.
      expect(hostApi.calls, ['send:central:PAIR:40'],
          reason: 'exactly one write attempt, on the leg that was asked');

      // And the path is usable again straight away — the wedge does not
      // outlive the write that caused it.
      hostApi.calls.clear();
      hostApi.swallow.clear();
      expect(await transport.sendToPeer('central:PAIR', Uint8List(40)), isTrue);
      expect(hostApi.calls, ['send:central:PAIR:40']);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('unanswered writes never drop the leg', () async {
      // A write the stack does not answer says nothing about the link: on a
      // loaded desk most such writes were received by the peer regardless,
      // the response was merely late. Liveness is the ANNOUNCE the peer
      // sends over every leg each interval, and only its absence condemns a
      // leg.
      await convergedPair();
      hostApi.swallow.add('central:PAIR');
      for (var i = 0; i < 5; i++) {
        await transport.sendToPeer('central:PAIR', Uint8List(40));
      }
      expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty);
    });


    test('a leg whose writes keep failing is dropped', () async {
      // Nothing about what the peer sends us enters this: a quiet leg may
      // simply have a peer with nothing to say. A leg that will not carry
      // our bytes is the whole verdict.
      final peer = await convergedPair();
      transport.onPeerIdentified('central:PAIR', peer.publicKey);
      hostApi.refuse.add('central:PAIR');
      // The send itself still succeeds: a refusal falls back to the other leg.
      await transport.sendToPeer('central:PAIR', Uint8List(40));
      transport.dropFailingLegsNow();
      expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty,
          reason: 'one refused write is a collision, not a verdict');
      await transport.sendToPeer('central:PAIR', Uint8List(40));
      transport.dropFailingLegsNow(
          now: DateTime.now().add(const Duration(seconds: 11)));
      expect(hostApi.calls, contains('disconnect:central:PAIR'));
      expect(hostApi.calls, isNot(contains('disconnect:peripheral:PAIR')),
          reason: 'the verdict is per leg; the other leg carries traffic');
    });

    test('a burst of refusals inside one announce interval is not a verdict',
        () async {
      // The measured failure mode this guards: under send load a leg refuses
      // several writes in a row within milliseconds, which condemned it and
      // took the pair down with it. A run lost 470 central legs this way —
      // against 174 that died of an actual radio fault — and with one dial in
      // flight the rebuild never caught up, so connectivity fell from 11.6
      // legs per device to 5 and kept falling.
      final peer = await convergedPair();
      transport.onPeerIdentified('central:PAIR', peer.publicKey);
      hostApi.refuse.add('central:PAIR');
      for (var i = 0; i < 8; i++) {
        await transport.sendToPeer('central:PAIR', Uint8List(40));
      }
      transport.dropFailingLegsNow();
      expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty,
          reason: 'Eight refusals arriving inside one announce interval are '
              'one congested moment, not eight verdicts. Contention refuses '
              'in bursts; a dead leg refuses across cycles.');
    });

    test('a refused write records WHAT refused it', () async {
      // Two runs went on guessing why writes fail under load because the
      // record named only that one had. The reason is what separates a
      // congested queue from a link the stack has given up on, and neither
      // the drop table nor the leg's own history could tell them apart.
      await convergedPair();
      hostApi.refuse.add('central:PAIR');
      await transport.sendToPeer('central:PAIR', Uint8List(40));

      final drop = trace.records.lastWhere(
          (r) => r['type'] == 'drop' && r['reason'] == 'writeFailed');
      expect(drop['error'], isNotNull,
          reason: 'A writeFailed with no cause is a dead end for analysis.');
      expect(drop['error'].toString(), contains('refused write'),
          reason: 'Carry what the stack actually said.');
    });

    test('a foreign exception keeps the cause Pigeon put in details',
        () async {
      // Pigeon's wrapError puts "Cause: ..., Stacktrace: ..." in `details` for
      // any throwable that is not one of the plugin's own FlutterErrors. That
      // is where a framework NPE thrown inside the Android BLE stack arrives,
      // and dropping it cost an hour of reading bytecode to reconstruct what
      // had already been delivered.
      await convergedPair();
      hostApi.throughPigeon.add('central:PAIR');
      await transport.sendToPeer('central:PAIR', Uint8List(40));

      final drop = trace.records.lastWhere(
          (r) => r['type'] == 'drop' && r['reason'] == 'writeFailed');
      expect(drop['error'].toString(), contains('NullPointerException'),
          reason: 'The cause is the whole value of the record.');
    });

    test('a refusal the plugin raised itself carries no stack', () async {
      // The plugin's own codes are self-describing, and their details are
      // empty or noise. Appending them would push the useful half of every
      // record past the eye.
      await convergedPair();
      hostApi.busy.add('central:PAIR');
      await transport.sendToPeerIdempotent('central:PAIR', Uint8List(40));

      final drop = trace.records.lastWhere((r) => r['type'] == 'drop');
      expect(drop['reason'], 'writeBusy');
    });

    test('coming out of quiet actually starts scanning again', () async {
      // The drains between dwells exist to let a lost leg re-form, which is
      // impossible if discovery never comes back. A run was observed holding
      // the NOT ADVERTISING banner through every drain: quiet went on and
      // never came off, so the phone was undiscoverable from the first dwell
      // to the end of the run.
      await convergedPair();
      await transport.setDiscoveryQuiet(true);
      hostApi.calls.clear();

      await transport.setDiscoveryQuiet(false);

      expect(transport.discoveryQuiet, isFalse);
      expect(hostApi.calls.any((c) => c.startsWith('startScan')), isTrue,
          reason: 'the drain must be able to find a lost leg again');
      expect(hostApi.calls.any((c) => c.startsWith('startAdvertising')), isTrue,
          reason: 'and the peer must be able to find us');
    });

    test('a quiet run never condemns a leg', () async {
      // The failing-leg sweep exists to free a slot for a better leg. With
      // discovery off no better leg can form, so condemning one only ends the
      // run — and a quiet run is exactly where the inbound-liveness veto
      // cannot protect it, because ANNOUNCE is off and acknowledgements are
      // suppressed, so the leg hears nothing and looks dead to the sweep.
      final peer = await convergedPair();
      transport.onPeerIdentified('central:PAIR', peer.publicKey);
      await transport.setDiscoveryQuiet(true);
      hostApi.calls.clear();

      hostApi.refuse.add('central:PAIR');
      await transport.sendToPeer('central:PAIR', Uint8List(40));
      await transport.sendToPeer('central:PAIR', Uint8List(40));
      transport.dropFailingLegsNow(
          now: DateTime.now().add(const Duration(seconds: 60)));

      expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty,
          reason: 'nothing may tear down the only link the run has');
    });

    test('the drain does not condemn the leg the quiet step was measuring',
        () async {
      // The sweep stands aside while quiet, but the streaks kept counting
      // behind that guard and the drain is where they came due: a run lost a
      // leg within seconds of every dwell end, eight times over, and delivered
      // 4 of 378 messages. Leaving quiet must discard what was counted under
      // it — a refused write there says the peer is silent, which is what a
      // one-way step with acknowledgements suppressed asked it to be.
      final peer = await convergedPair();
      transport.onPeerIdentified('central:PAIR', peer.publicKey);
      await transport.setDiscoveryQuiet(true);

      hostApi.refuse.add('central:PAIR');
      await transport.sendToPeer('central:PAIR', Uint8List(40));
      await transport.sendToPeer('central:PAIR', Uint8List(40));

      hostApi.refuse.remove('central:PAIR');
      await transport.setDiscoveryQuiet(false);
      hostApi.calls.clear();
      transport.dropFailingLegsNow(
          now: DateTime.now().add(const Duration(seconds: 60)));

      expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty,
          reason: 'failures counted while quiet must not come due at the drain');
    });

    test('going quiet stops discovery but keeps the links up', () async {
      // A throughput ceiling wants the radio carrying payload and nothing
      // else. Advertising and scanning cost airtime and controller time on
      // the same chip, so they are what a ceiling run has to silence — but
      // severing the link it is measuring would end the run, so the legs stay.
      await convergedPair();
      hostApi.calls.clear();

      await transport.setDiscoveryQuiet(true);

      expect(hostApi.calls, contains('stopScan'));
      // The GATT server must be KEPT. A plain stop takes it down with the
      // advertiser, and the peer's central leg — holding the characteristic
      // handle it discovered — then gets GATT status 1 on every write for the
      // rest of the run. Measured: 17,284 such failures, zero delivered.
      expect(hostApi.calls, contains('stopAdvertising:keepServer'));
      expect(hostApi.calls, isNot(contains('stopAdvertising')),
          reason: 'a plain stop here deletes the link under measurement');
      expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty,
          reason: 'the link under measurement must survive going quiet');
      expect(transport.isDeviceConnected('peripheral:PAIR'), isTrue);
      expect(transport.isDeviceConnected('central:PAIR'), isTrue);
    });

    test('a leg still hearing from its peer is never condemned', () async {
      // Refused writes are evidence about our queue, not about the link. A
      // leg the peer is still notifying us over is carrying traffic in the
      // direction only the peer controls, which no amount of local
      // congestion can fake. Under send load this is the difference between
      // shedding a live leg and keeping the mesh: a run condemned 27 legs in
      // one 15 s bucket against 7 lost to actual radio faults, and
      // connectivity fell from twelve legs per device to four.
      final peer = await convergedPair();
      transport.onPeerIdentified('central:PAIR', peer.publicKey);
      hostApi.refuse.add('central:PAIR');
      await transport.sendToPeer('central:PAIR', Uint8List(40));
      await transport.sendToPeer('central:PAIR', Uint8List(40));

      callbacks.pushPayload(BlePayload(
        pathId: 'central:PAIR',
        role: BleRole.central,
        value: Uint8List.fromList([1, 2, 3]),
        rssi: -50,
      ));
      await Future<void>.delayed(Duration.zero);

      transport.dropFailingLegsNow(
          now: DateTime.now().add(const Duration(seconds: 11)));
      expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty,
          reason: 'The peer is still talking on this leg. Silence is not '
              'evidence of death — we notify over our own peripheral leg, so '
              'quiet there is the design working — but inbound traffic IS '
              'evidence of life, and that is not the same claim.');
    });

    test('a leg refusing across announce intervals is still condemned',
        () async {
      // The rule the window must not weaken: every leg carries an ANNOUNCE
      // each interval, so a leg that has genuinely died goes on refusing
      // without anything having to probe it.
      final peer = await convergedPair();
      transport.onPeerIdentified('central:PAIR', peer.publicKey);
      hostApi.refuse.add('central:PAIR');
      await transport.sendToPeer('central:PAIR', Uint8List(40));
      await transport.sendToPeer('central:PAIR', Uint8List(40));
      transport.dropFailingLegsNow(
          now: DateTime.now().add(const Duration(seconds: 11)));
      expect(hostApi.calls, contains('disconnect:central:PAIR'),
          reason: 'Still refusing an announce interval later is a leg that '
              'will not carry bytes.');
    });

    test('a write that lands clears the leg\'s failure count', () async {
      final peer = await convergedPair();
      transport.onPeerIdentified('central:PAIR', peer.publicKey);
      hostApi.refuse.add('central:PAIR');
      await transport.sendToPeer('central:PAIR', Uint8List(40));
      hostApi.refuse.remove('central:PAIR');
      expect(await transport.sendToPeer('central:PAIR', Uint8List(40)), isTrue);
      hostApi.refuse.add('central:PAIR');
      await transport.sendToPeer('central:PAIR', Uint8List(40));
      transport.dropFailingLegsNow();
      expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty,
          reason: 'the run of failures restarted at the write that landed');
    });

    test('data leaves a peripheral leg whose writes are failing', () async {
      // Demotion without a teardown, and on FAILURE alone: silence on our
      // peripheral leg says nothing — it is the leg we notify over, so the
      // peer has no reason to send anything back on it. A write that will
      // not go out is the only evidence the leg cannot carry volume.
      final peer = await convergedPair();
      expect(transport.getPeerIdForPubkey(peer.publicKey), 'peripheral:PAIR');
      hostApi.refuse.add('peripheral:PAIR');
      await transport.sendToPeer('peripheral:PAIR', Uint8List(40));
      expect(transport.getPeerIdForPubkey(peer.publicKey), 'central:PAIR',
          reason: 'a leg that will not carry a write is not where data goes');
      expect(transport.isDeviceConnected('peripheral:PAIR'), isTrue,
          reason: 'demoted, not dropped');
      hostApi.refuse.remove('peripheral:PAIR');
      await transport.sendToPeer('peripheral:PAIR', Uint8List(40));
      expect(transport.getPeerIdForPubkey(peer.publicKey), 'peripheral:PAIR',
          reason: 'a write that lands restores the leg to the data role');
    });



    test('the write budget for a peer is its narrowest ready leg', () async {
      // The legs negotiate separately and a frame may go out on either, so
      // what one write can carry is the smaller of the two — not the leg the
      // sender happens to prefer.
      final peer = await convergedPair(centralMtu: 517, peripheralMtu: 185);
      expect(transport.usableWriteBytesForPubkey(peer.publicKey), 185 - 3);
    });

    test('an unknown or legless peer has no budget', () async {
      final stranger = await _makeIdentity('Stranger');
      expect(transport.usableWriteBytesForPubkey(stranger.publicKey), isNull);
    });

    test('a busy op slot is a refusal of its own kind', () async {
      // The plugin holds one GATT op per path and refuses a write that finds
      // the slot taken. That is a collision, not the stack saying no, and the
      // write-up needs to count the two apart.
      await convergedPair();
      hostApi.busy.add('central:PAIR');
      expect(
          await transport.sendToPeerIdempotent('central:PAIR', Uint8List(40)),
          isTrue);
      expect(hostApi.calls, [
        'send:central:PAIR:40',
        'send:peripheral:PAIR:40',
      ]);
      final drops = trace.records.where((r) => r['type'] == 'drop').toList();
      expect(drops.map((r) => r['reason']), ['writeBusy']);
    });

    test('an idempotent send retries the other leg after a timeout', () async {
      // Sync frames are safe to deliver twice — the receiver answers a filter
      // it has already seen with the same conveyance, and a duplicate frame
      // costs one round, not a double delivery. For those the double-send
      // rule gives way: a timed-out write is retried on the pair's other leg.
      await convergedPair();
      hostApi.swallow.add('central:PAIR');
      expect(
          await transport.sendToPeerIdempotent('central:PAIR', Uint8List(40)),
          isTrue);
      expect(hostApi.calls, [
        'send:central:PAIR:40',
        'send:peripheral:PAIR:40',
      ]);
    });

    test('no fallback onto a leg that would truncate the packet', () async {
      // The legs negotiate their MTUs separately, and on iOS the notify limit
      // is a per-central property. A 200-byte packet fits the peripheral leg
      // and not the central one; retrying there would put an unparseable
      // write on the air and count it as a success.
      await convergedPair(centralMtu: 23, peripheralMtu: 247);
      hostApi.refuse.add('peripheral:PAIR');
      expect(await transport.broadcast(Uint8List(200)), 0);
      expect(hostApi.calls, ['send:peripheral:PAIR:200'],
          reason: 'The undersized leg is not attempted at all.');
    });

    test('an unidentified path gets no fallback', () async {
      // Two ready legs, no ANNOUNCE on either: they cannot be shown to belong
      // to the same peer, and a "fallback" onto a stranger's leg would send
      // this packet to someone the flood did not choose.
      callbacks.pushPath(BlePath(
        pathId: 'central:UNKNOWN-A',
        role: BleRole.central,
        state: BlePathState.ready,
        rssi: -50,
        mtu: 247,
        canSend: true,
      ));
      callbacks.pushPath(BlePath(
        pathId: 'peripheral:UNKNOWN-B',
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: null,
        mtu: 247,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      hostApi.calls.clear();
      hostApi.refuse.addAll({'central:UNKNOWN-A', 'peripheral:UNKNOWN-B'});

      expect(await transport.broadcast(Uint8List(40)), 0);
      expect(hostApi.calls, hasLength(2),
          reason: 'Both unidentified legs are flood targets in their own '
              'right, but neither is the other one\'s fallback.');
    });

    test('data takes the peripheral leg, control takes the central one',
        () async {
      final peer = await convergedPair();

      expect(transport.getPeerIdForPubkey(peer.publicKey), 'peripheral:PAIR',
          reason: 'A notification costs no round trip and several pack into '
              'one connection interval, so everything with volume rides it.');
      expect(
          transport.getControlPeerIdForPubkey(peer.publicKey), 'central:PAIR',
          reason: 'A handshake flight is neither buffered nor re-offered, so '
              'it pays a round trip to be refused rather than to vanish.');
    });

    test('both preferences fall back to the only leg a pair holds', () async {
      final centralOnly = await _makeIdentity('CentralOnly');
      callbacks.pushPath(BlePath(
        pathId: 'central:SOLO',
        role: BleRole.central,
        state: BlePathState.ready,
        rssi: -50,
        mtu: 247,
        canSend: true,
      ));
      final peripheralOnly = await _makeIdentity('PeripheralOnly');
      callbacks.pushPath(BlePath(
        pathId: 'peripheral:SOLO',
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: null,
        mtu: 247,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      store.dispatch(PeerAnnounceReceivedAction(
        publicKey: centralOnly.publicKey,
        nickname: 'CentralOnly',
        transport: PeerTransport.bleDirect,
        bleCentralDeviceId: 'central:SOLO',
      ));
      store.dispatch(PeerAnnounceReceivedAction(
        publicKey: peripheralOnly.publicKey,
        nickname: 'PeripheralOnly',
        transport: PeerTransport.bleDirect,
        blePeripheralDeviceId: 'peripheral:SOLO',
      ));
      transport.onPeerIdentified('central:SOLO', centralOnly.publicKey);
      transport.onPeerIdentified('peripheral:SOLO', peripheralOnly.publicKey);
      await Future<void>.delayed(Duration.zero);

      expect(transport.getPeerIdForPubkey(centralOnly.publicKey),
          'central:SOLO',
          reason: 'A pair is single-legged for the whole of first contact, '
              'so a preference may never refuse to send.');
      expect(transport.getControlPeerIdForPubkey(peripheralOnly.publicKey),
          'peripheral:SOLO',
          reason: 'The handshake that converges a pair runs before the pair '
              'has a central leg to prefer.');
    });

  });

  group('BleTransportService — a write outruns its leg\'s MTU', () {
    late _RecordingHostApi hostApi;
    late FakeGrassrootsBluetoothCallbacks callbacks;
    late Store<AppState> store;
    late BleTransportService transport;

    setUp(() async {
      hostApi = _RecordingHostApi();
      callbacks = FakeGrassrootsBluetoothCallbacks();
      final ble =
          GrassrootsBluetooth.test(hostApi: hostApi, callbacks: callbacks);
      store = Store<AppState>(appReducer, initialState: AppState.initial);
      store.dispatch(SetColdCallTrustLevelAction(ColdCallTrustLevel.open));
      transport = BleTransportService(
        identity: await _makeIdentity('Sender'),
        store: store,
        grassrootsBluetooth: ble,
      );
      await transport.initialize();
      addTearDown(transport.dispose);
    });

    /// The measured field state this group pins: the peer has dialed us, so
    /// the pair holds ONE leg — our peripheral — still at the 23-byte ATT
    /// default, with the MTU request racing the first writes.
    Future<void> singleLegAtDefault() async {
      final peer = await _makeIdentity('PairPeer');
      callbacks.pushPath(BlePath(
        pathId: 'peripheral:PAIR',
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: null,
        mtu: 23,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      store.dispatch(PeerAnnounceReceivedAction(
        publicKey: peer.publicKey,
        nickname: 'PairPeer',
        transport: PeerTransport.bleDirect,
        blePeripheralDeviceId: 'peripheral:PAIR',
      ));
      transport.onPeerIdentified('peripheral:PAIR', peer.publicKey);
      await Future<void>.delayed(Duration.zero);
      hostApi.calls.clear();
    }

    test('the one-leg-per-peer picker prefers a leg that can CARRY the frame '
        'over the notify preference', () async {
      // Roughly three quarters of pairs hold one leg at the ATT default and
      // one at 517 at some point, and the default one lingers for a median
      // 1.5 s (p90 11-34 s under load). Preferring notify blindly picks the
      // small one and spends the packet.
      BlePath leg(String id, BleRole role, int mtu) => BlePath(
            pathId: id,
            role: role,
            state: BlePathState.ready,
            rssi: -50,
            mtu: mtu,
            canSend: true,
          );
      final key = Uint8List.fromList(List.filled(32, 9));
      Uint8List? pubkeyFor(String _) => key;
      final legs = [
        leg('peripheral:P', BleRole.peripheral, 23),
        leg('central:P', BleRole.central, 517),
      ];

      // Small frame: both legs carry it, so the notify preference decides.
      var picked = BleTransportService.selectBroadcastTargets(
          ready: legs, pubkeyFor: pubkeyFor, bytes: 10);
      expect(picked.single.pathId, 'peripheral:P',
          reason: 'notify is still preferred when the frame fits both');

      // Handshake-sized: only the wide leg can carry it.
      picked = BleTransportService.selectBroadcastTargets(
          ready: legs, pubkeyFor: pubkeyFor, bytes: 113);
      expect(picked.single.pathId, 'central:P',
          reason: 'being able to send at all outranks the notify preference');

      // No size given: unchanged behaviour.
      picked = BleTransportService.selectBroadcastTargets(
          ready: legs, pubkeyFor: pubkeyFor);
      expect(picked.single.pathId, 'peripheral:P');
    });

    test('a frame too big for the chosen leg goes out on the pair\'s wider '
        'leg instead of being spent on the small one', () async {
      // The measured field state: a pair holding one leg at the ATT default
      // and one at 517 in the same instant. A handshake frame is 86-113
      // bytes, so the default leg refuses it, and with no fallback found the
      // write is HELD for an MTU exchange the other leg already completed —
      // leaving the peer sessionless while its partner keeps sending.
      final peer = await _makeIdentity('WidePeer');
      for (final leg in [
        ('peripheral:WIDE', BleRole.peripheral, 23),
        ('central:WIDE', BleRole.central, 517),
      ]) {
        callbacks.pushPath(BlePath(
          pathId: leg.$1,
          role: leg.$2,
          state: BlePathState.ready,
          rssi: null,
          mtu: leg.$3,
          canSend: true,
        ));
      }
      await Future<void>.delayed(Duration.zero);
      store.dispatch(PeerAnnounceReceivedAction(
        publicKey: peer.publicKey,
        nickname: 'WidePeer',
        transport: PeerTransport.bleDirect,
        blePeripheralDeviceId: 'peripheral:WIDE',
        bleCentralDeviceId: 'central:WIDE',
      ));
      transport.onPeerIdentified('peripheral:WIDE', peer.publicKey);
      transport.onPeerIdentified('central:WIDE', peer.publicKey);
      await Future<void>.delayed(Duration.zero);
      hostApi.calls.clear();

      // Handshake-sized, far past the small leg's 20 usable bytes.
      final ok = await transport.sendToPeer(
          'peripheral:WIDE', Uint8List.fromList(List.filled(113, 7)));
      await Future<void>.delayed(Duration.zero);

      expect(ok, isTrue, reason: 'the pair could carry this frame');
      final sends = hostApi.calls.where((c) => c.startsWith('send:')).toList();
      expect(sends, hasLength(1), reason: 'exactly one leg is written');
      expect(sends.single, contains('central:WIDE'),
          reason: 'the wider leg carries it; the 23-byte leg is never tried');
    });

    test('a write onto a leg whose MTU has not landed is refused NOW, and '
        'named apart from a genuine oversize', () async {
      await singleLegAtDefault();

      // 113 bytes is the first Noise handshake message: too big for 20
      // usable bytes, and this pair has nowhere else to put it. The write is
      // refused immediately rather than held — holding it would be a
      // sender-side retry queue, which this design does not have. The DTN
      // buffer and the sync exchange are what redeliver an unplaced packet.
      final aired = await transport
          .broadcast(Uint8List(113))
          .timeout(const Duration(milliseconds: 500));
      expect(aired, 0, reason: 'refused, and the caller is told at once');
      expect(hostApi.calls, isEmpty, reason: 'nothing is spent on the air');

      // And when the MTU does land, nothing fires retroactively: the packet
      // is not owed a second life by this layer.
      callbacks.pushPath(BlePath(
        pathId: 'peripheral:PAIR',
        role: BleRole.peripheral,
        state: BlePathState.ready,
        rssi: null,
        mtu: 185,
        canSend: true,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(hostApi.calls, isEmpty,
          reason: 'no held queue drains behind the caller\'s back');
    });

    test('a small write still goes out on a default-MTU leg', () async {
      await singleLegAtDefault();
      // The refusal is about SIZE, not about the leg being young: 20 usable
      // bytes still carry anything that fits.
      final aired = await transport.broadcast(Uint8List(12));
      await Future<void>.delayed(Duration.zero);
      expect(aired, 1);
      expect(hostApi.calls, ['send:peripheral:PAIR:12']);
    });

    test('disposal cancels a held write instead of leaking its timer',
        () async {
      await singleLegAtDefault();

      expect(await transport.broadcast(Uint8List(113)), 0);
      await transport.dispose();
      // The deadline would fire at 3 s; nothing may reach the stack after
      // dispose, and no timer may be left running.
      await Future<void>.delayed(const Duration(milliseconds: 3400));
      expect(hostApi.calls.where((c) => c.startsWith('send:')), isEmpty,
          reason: 'teardown calls are dispose\'s own; a send would mean the '
              'deadline timer outlived the transport');
    });

    test('a small write is unaffected by the default MTU', () async {
      await singleLegAtDefault();
      expect(await transport.broadcast(Uint8List(16)), 1);
      expect(hostApi.calls, ['send:peripheral:PAIR:16']);
    });
  });
  /// The ring-radius link gate (DEBUG/TESTBED). See
  /// `lib/src/testbed/ring_topology.dart` for what the ring is.
  ///
  /// The dial tests drive [BleTransportService.connectToDevice] directly rather
  /// than through an advertisement. That is deliberate: `connectToDevice` is
  /// THE dial choke point, and going through a sighting would also drag in the
  /// first-mover election, whose UUID ordering is independent of the ring's
  /// pubkey ordering and would make which peer can be tested a matter of luck.
  /// The advertisement path is covered by the rest of this suite, which passes
  /// unchanged and is itself the proof that the gate is inert when unarmed.
  group('BleTransportService — ring-radius gate', () {
    late _RecordingHostApi hostApi;
    late FakeGrassrootsBluetoothCallbacks callbacks;
    late Store<AppState> store;
    late _CapturingTrace trace;
    late BleTransportService transport;
    late GrassrootsIdentity self;
    // The ring, in ring order (sorted pubkey hex). `self` is one of them.
    late List<GrassrootsIdentity> ring;

    String hexOf(GrassrootsIdentity id) =>
        id.publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    setUp(() async {
      hostApi = _RecordingHostApi();
      callbacks = FakeGrassrootsBluetoothCallbacks();
      final ble =
          GrassrootsBluetooth.test(hostApi: hostApi, callbacks: callbacks);
      store = Store<AppState>(appReducer, initialState: AppState.initial);
      store.dispatch(SetColdCallTrustLevelAction(ColdCallTrustLevel.open));
      trace = _CapturingTrace();
      await trace.startExperiment('ring-gate');

      // `self` is the NON-initiator toward the opposite peer (its service
      // UUID sorts higher), so the initiator grace applies to that pair.
      late List<GrassrootsIdentity> members;
      do {
        members = [
          for (var i = 0; i < 4; i++) await _makeIdentity('Ring$i'),
        ]..sort((a, b) => hexOf(a).compareTo(hexOf(b)));
      } while (
          members[2].bleServiceUuid.compareTo(members[0].bleServiceUuid) > 0);
      ring = members;
      self = members.first; // ring position 0

      transport = BleTransportService(
        identity: self,
        store: store,
        grassrootsBluetooth: ble,
        trace: trace,
      );
      await transport.initialize();
    });

    tearDown(() async {
      await transport.dispose();
    });

    void armRing({required int? radius}) {
      store.dispatch(SetRingGateAction(
        rosterHex: ring.map(hexOf).toList(),
        radius: radius,
      ));
    }

    /// Ring positions relative to `self` at index 0 on a 4-ring:
    /// 1 and 3 are the neighbours, 2 is the opposite peer (distance 2).
    GrassrootsIdentity neighbour() => ring[1];
    GrassrootsIdentity opposite() => ring[2];

    Future<bool> dial(GrassrootsIdentity peer, {String mac = 'MACX'}) =>
        transport.connectToDevice('central:$mac',
            serviceUuidOverride: peer.bleServiceUuid);

    List<Map<String, dynamic>> skipsWithReason(String reason) => trace.records
        .where((r) => r['event'] == 'dialSkip' && r['reason'] == reason)
        .toList();

    test('refuses a dial to the opposite peer at r=1', () async {
      armRing(radius: 1);
      hostApi.calls.clear();

      expect(await dial(opposite()), isFalse);

      expect(hostApi.calls.where((c) => c.startsWith('connect:')), isEmpty,
          reason: 'a peer two hops around the ring must not be dialed at r=1');
      expect(skipsWithReason('ringRadius'), hasLength(1),
          reason: 'the refusal must be attributable in the trace');
    });

    test('allows a dial to either ring neighbour at r=1', () async {
      armRing(radius: 1);
      hostApi.calls.clear();

      expect(await dial(neighbour(), mac: 'NEAR1'), isTrue);
      expect(await dial(ring[3], mac: 'NEAR2'), isTrue,
          reason: 'the wrap-around neighbour is adjacent too');

      expect(hostApi.calls.where((c) => c.startsWith('connect:')), hasLength(2));
      expect(skipsWithReason('ringRadius'), isEmpty);
    });

    test('at r=2 the 4-ring is complete, so the opposite peer is allowed',
        () async {
      armRing(radius: 2);
      hostApi.calls.clear();

      expect(await dial(opposite()), isTrue);
      expect(hostApi.calls.where((c) => c.startsWith('connect:')), hasLength(1));
    });

    test('refuses an off-roster peer while armed, under its own reason',
        () async {
      armRing(radius: 2); // complete graph for the roster — yet a stranger
      final stranger = await _makeIdentity('Stranger');
      hostApi.calls.clear();

      expect(await dial(stranger), isFalse);

      expect(hostApi.calls.where((c) => c.startsWith('connect:')), isEmpty,
          reason: 'a device outside the experiment would relay and collapse '
              'the diameter the ring exists to create');
      // Separable from an ordinary radius refusal: a misdeployed roster must
      // not be mistaken for the gate working as intended.
      expect(skipsWithReason('ringOffRoster'), hasLength(1));
      expect(skipsWithReason('ringRadius'), isEmpty);
    });

    test('is inert with no radius: the same stranger dials fine', () async {
      armRing(radius: null);
      final stranger = await _makeIdentity('Stranger');
      hostApi.calls.clear();

      expect(await dial(stranger), isTrue);
      expect(hostApi.calls.where((c) => c.startsWith('connect:')), hasLength(1));
    });

    test('is inert on a device that is not itself on the roster', () async {
      // A bystander handed a roster it is not in must not have its radio
      // constrained: the testbed knob may not leak into ordinary use.
      store.dispatch(SetRingGateAction(
        rosterHex: ring.skip(1).map(hexOf).toList(), // self excluded
        radius: 1,
      ));
      hostApi.calls.clear();

      expect(await dial(opposite()), isTrue);
      expect(hostApi.calls.where((c) => c.startsWith('connect:')), hasLength(1));
    });

    group('inbound backstop', () {
      Future<void> inboundLeg(String mac) async {
        callbacks.pushPath(BlePath(
          pathId: 'peripheral:$mac',
          role: BleRole.peripheral,
          state: BlePathState.ready,
          rssi: -55,
          mtu: 247,
          canSend: true,
        ));
        await Future<void>.delayed(Duration.zero);
      }

      test('drops an inbound leg from a peer outside the radius', () async {
        armRing(radius: 1);
        await inboundLeg('FAR');
        hostApi.calls.clear();

        transport.onPeerIdentified('peripheral:FAR', opposite().publicKey);
        await Future<void>.delayed(Duration.zero);

        expect(hostApi.calls, contains('disconnect:peripheral:FAR'));
        expect(
            trace.records.where((r) => r['event'] == 'ringDrop'), hasLength(1));
      });

      test('keeps an inbound leg from a ring neighbour', () async {
        armRing(radius: 1);
        await inboundLeg('NEAR');
        hostApi.calls.clear();

        transport.onPeerIdentified('peripheral:NEAR', neighbour().publicKey);
        await Future<void>.delayed(Duration.zero);

        expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty);
        expect(trace.records.where((r) => r['event'] == 'ringDrop'), isEmpty);
      });

      test('never gates ANNOUNCE: the peer record survives the dropped link',
          () async {
        armRing(radius: 1);
        await inboundLeg('FAR');
        // What the router does with an ANNOUNCE before the transport is told
        // who is on the path. The gate must take the LINK and nothing else:
        // identity, the peer record and any eager handshake are untouched.
        store.dispatch(PeerAnnounceReceivedAction(
          publicKey: opposite().publicKey,
          nickname: 'Opposite',
          transport: PeerTransport.bleDirect,
          blePeripheralDeviceId: 'peripheral:FAR',
        ));
        await Future<void>.delayed(Duration.zero);

        transport.onPeerIdentified('peripheral:FAR', opposite().publicKey);
        await Future<void>.delayed(Duration.zero);

        expect(hostApi.calls, contains('disconnect:peripheral:FAR'));
        expect(store.state.peers.getPeerByPubkeyHex(hexOf(opposite())),
            isNotNull,
            reason: 'the ring gate refuses links, never ANNOUNCE processing');
      });
    });

    group('ignored phone', () {
      // A phone that is in range but not part of the experiment: the ring
      // gate cannot exclude it (its roster is derived from the session
      // table, which the stray is in), so the testbed ignores it by pubkey.
      test('refuses a dial to an ignored phone with the gate disarmed',
          () async {
        store.dispatch(IgnorePeerAction(hexOf(opposite())));
        hostApi.calls.clear();

        expect(await dial(opposite()), isFalse);

        expect(hostApi.calls.where((c) => c.startsWith('connect:')), isEmpty);
        expect(skipsWithReason('ignored'), hasLength(1));
      });

      test('still dials everyone else', () async {
        store.dispatch(IgnorePeerAction(hexOf(opposite())));
        hostApi.calls.clear();

        expect(await dial(neighbour()), isTrue);
        expect(skipsWithReason('ignored'), isEmpty);
      });

      test('dials the phone again once it is no longer ignored', () async {
        store.dispatch(IgnorePeerAction(hexOf(opposite())));
        store.dispatch(UnignorePeerAction(hexOf(opposite())));
        hostApi.calls.clear();

        expect(await dial(opposite()), isTrue);
      });

      test('drops an inbound leg from an ignored phone', () async {
        store.dispatch(IgnorePeerAction(hexOf(opposite())));
        callbacks.pushPath(BlePath(
          pathId: 'peripheral:IGN',
          role: BleRole.peripheral,
          state: BlePathState.ready,
          rssi: -55,
          mtu: 247,
          canSend: true,
        ));
        await Future<void>.delayed(Duration.zero);
        hostApi.calls.clear();

        transport.onPeerIdentified('peripheral:IGN', opposite().publicKey);
        await Future<void>.delayed(Duration.zero);

        expect(hostApi.calls, contains('disconnect:peripheral:IGN'));
        expect(trace.records.where((r) => r['event'] == 'ignoreDrop'),
            hasLength(1));
      });
    });

    group('prune on shrink', () {
      /// Bring up BOTH legs of the pair with `peer`, identified, so
      /// `_pairViewFor` resolves the identity and the prune can find them.
      Future<void> dualRoleWith(GrassrootsIdentity peer, String mac) async {
        for (final role in [BleRole.central, BleRole.peripheral]) {
          callbacks.pushPath(BlePath(
            pathId: '${role.name}:$mac',
            role: role,
            state: BlePathState.ready,
            rssi: -55,
            mtu: 247,
            canSend: true,
          ));
        }
        await Future<void>.delayed(Duration.zero);
        store.dispatch(PeerAnnounceReceivedAction(
          publicKey: peer.publicKey,
          nickname: 'Peer',
          transport: PeerTransport.bleDirect,
          bleCentralDeviceId: 'central:$mac',
          blePeripheralDeviceId: 'peripheral:$mac',
        ));
        await Future<void>.delayed(Duration.zero);
      }

      test('shrinking to r=1 drops BOTH legs of the now-far pair', () async {
        armRing(radius: 2); // complete: the opposite peer is allowed
        await dualRoleWith(opposite(), 'OPP');
        hostApi.calls.clear();

        armRing(radius: 1); // the opposite peer is now two hops away
        await transport.applyRingGateChange();

        // A dual-role pair is ONE neighbour; leaving either leg up leaves the
        // pair adjacent and the measured diameter wrong.
        expect(hostApi.calls, contains('disconnect:central:OPP'));
        expect(hostApi.calls, contains('disconnect:peripheral:OPP'));
        expect(trace.records.where((r) => r['event'] == 'ringPrune'),
            hasLength(2));
      });

      test('widening prunes nothing', () async {
        armRing(radius: 1);
        await dualRoleWith(neighbour(), 'NB');
        hostApi.calls.clear();

        armRing(radius: 2);
        await transport.applyRingGateChange();

        expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty);
      });

      test('leaves an allowed pair alone, keeping both legs', () async {
        armRing(radius: 1);
        await dualRoleWith(neighbour(), 'NB');
        hostApi.calls.clear();

        await transport.applyRingGateChange();

        expect(hostApi.calls.where((c) => c.startsWith('disconnect:')), isEmpty,
            reason: 'the dual-role mandate: an allowed pair keeps both legs');
      });

      test('severLinksWith drops BOTH legs of a pair that is now ignored',
          () async {
        await dualRoleWith(opposite(), 'IGN');
        hostApi.calls.clear();

        store.dispatch(IgnorePeerAction(hexOf(opposite())));
        await transport.severLinksWith(hexOf(opposite()));

        expect(hostApi.calls, contains('disconnect:central:IGN'));
        expect(hostApi.calls, contains('disconnect:peripheral:IGN'));
        expect(trace.records.where((r) => r['event'] == 'ignorePrune'),
            hasLength(2));
      });
    });

    group('widening', () {
      test('re-arms the initiator grace for a pair the gate just allowed',
          () async {
        // A refused peer keeps being sighted the whole time it is refused, so
        // by the time the gate widens its first sighting is minutes old and
        // the grace has long elapsed. Without re-arming it, both sides of
        // every newly-allowed pair dial on the first sighting after the
        // change — measured at settle 1 of the ring sweep as all four phones
        // dialling at once and two of the dials failing.
        //
        void sightOpposite() => callbacks.pushAdvertisement(BleAdvertisement(
              remoteId: 'OPP',
              serviceUuids: [opposite().bleServiceUuid],
              rssi: -55,
              connectable: true,
            ));

        armRing(radius: 1);
        sightOpposite();
        await Future<void>.delayed(const Duration(milliseconds: 1600));
        sightOpposite();
        await Future<void>.delayed(Duration.zero);
        expect(skipsWithReason('ringRadius'), isNotEmpty,
            reason: 'refused, with the grace already elapsed');
        hostApi.calls.clear();

        armRing(radius: 2);
        await transport.applyRingGateChange();
        sightOpposite();
        await Future<void>.delayed(Duration.zero);

        expect(hostApi.calls.where((c) => c.startsWith('connect:')), isEmpty,
            reason: 'the initiator gets its uncontested window again');
        expect(skipsWithReason('awaitingInitiator'), isNotEmpty);
      });
    });

    group('severAllLinks', () {
      Future<void> twoLiveLinks() async {
        for (final mac in ['L1', 'L2']) {
          callbacks.pushPath(BlePath(
            pathId: 'central:$mac',
            role: BleRole.central,
            state: BlePathState.ready,
            rssi: -55,
            mtu: 247,
            canSend: true,
          ));
        }
        await Future<void>.delayed(Duration.zero);
      }

      test('disconnects every path', () async {
        await transport.start();
        await twoLiveLinks();
        hostApi.calls.clear();

        await transport.severAllLinks();

        expect(hostApi.calls, contains('disconnect:central:L1'));
        expect(hostApi.calls, contains('disconnect:central:L2'));
      });

      test('leaves discovery running — it does NOT stop scan or advertising',
          () async {
        await transport.start();
        await twoLiveLinks();
        final stateBefore = store.state.transports.bleState;
        hostApi.calls.clear();

        await transport.severAllLinks();

        // Discovery is load-bearing at every instant: suspending it during
        // dwells collapsed delivery from ~75% to ~26%, because these links
        // churn constantly and scanning is what re-establishes them.
        expect(hostApi.calls, isNot(contains('stopScan')));
        expect(hostApi.calls, isNot(contains('stopAdvertising')));
        expect(store.state.transports.bleState, stateBefore);
      });

      test('the transport still dials afterwards — _stopped was not set',
          () async {
        await transport.start();
        await twoLiveLinks();
        await transport.severAllLinks();
        hostApi.calls.clear();

        // The sharpest assertion available: a severed transport that cannot
        // dial again is [stop] wearing a different name, and the ring sweep
        // would measure a mesh that never comes back.
        armRing(radius: null);
        expect(await dial(await _makeIdentity('Later'), mac: 'AFTER'), isTrue);
        expect(hostApi.calls, contains('connect:AFTER'));
      });

      test('dispatches nothing: the plugin reports the disconnects', () async {
        await transport.start();
        await twoLiveLinks();
        final discoveredBefore = store.state.peers.discoveredBlePeers.length;
        var dispatches = 0;
        final unsubscribe = store.onChange.listen((_) => dispatches++);
        addTearDown(unsubscribe.cancel);

        await transport.severAllLinks();
        await Future<void>.delayed(Duration.zero);

        // A manual dispatch here would be a Redux inference rather than a
        // projection of a transport fact, and would double-count once the
        // plugin's own path events arrive.
        expect(dispatches, 0);
        expect(store.state.peers.discoveredBlePeers.length, discoveredBefore,
            reason: 'unlike the BLE bounce, the sever does not clear discovery');
      });
    });
  });
}
