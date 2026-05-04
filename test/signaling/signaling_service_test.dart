import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:redux/redux.dart';
import 'package:bitchat_transport/src/signaling/signaling_service.dart';
import 'package:bitchat_transport/src/signaling/signaling_codec.dart';
import 'package:bitchat_transport/src/signaling/address_table.dart';
import 'package:bitchat_transport/src/models/peer.dart';
import 'package:bitchat_transport/src/store/store.dart';

// ===== Helpers =====

Uint8List _testPubkey(int seed) {
  final key = Uint8List(32);
  for (int i = 0; i < 32; i++) {
    key[i] = (seed + i) % 256;
  }
  return key;
}

String _pubkeyHex(Uint8List key) =>
    key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Store<AppState> _storeWithPeers(
  Map<String, PeerState> peers, {
  SettingsState settings = const SettingsState(),
}) {
  return Store<AppState>(
    appReducer,
    initialState: AppState(
      peers: PeersState(peers: peers),
      settings: settings,
    ),
  );
}

PeerState _wellConnectedFriend(Uint8List pubkey, {String? udpAddress}) {
  return PeerState(
    publicKey: pubkey,
    nickname: 'Friend-${_pubkeyHex(pubkey).substring(0, 4)}',
    connectionState: PeerConnectionState.connected,
    isFriend: true,
    udpAddress: udpAddress ?? '[2606:4700::1]:4001',
    lastDirectReachAt: DateTime.now(),
  );
}

PeerState _regularFriend(Uint8List pubkey, {String? udpAddress}) {
  return PeerState(
    publicKey: pubkey,
    nickname: 'Peer-${_pubkeyHex(pubkey).substring(0, 4)}',
    connectionState: PeerConnectionState.connected,
    isFriend: true,
    udpAddress: udpAddress,
  );
}

PeerState _stranger(Uint8List pubkey) {
  return PeerState(
    publicKey: pubkey,
    nickname: 'Stranger',
    connectionState: PeerConnectionState.connected,
    isFriend: false,
  );
}

void main() {
  final aliceKey = _testPubkey(1);
  final bobKey = _testPubkey(2);
  final friendKey = _testPubkey(3);
  final friend2Key = _testPubkey(4);
  final anchorKey = _testPubkey(5);
  final anchor2Key = _testPubkey(6);
  final aliceHex = _pubkeyHex(aliceKey);
  final bobHex = _pubkeyHex(bobKey);
  final friendHex = _pubkeyHex(friendKey);
  final friend2Hex = _pubkeyHex(friend2Key);
  final anchorHex = _pubkeyHex(anchorKey);
  final anchor2Hex = _pubkeyHex(anchor2Key);
  const anchorAddress = '[2001:db8:ffff::1]:9514';
  const anchor2Address = '198.51.100.44:9514';
  const reflectedIp = '2400::12';
  const directPunchIp = '2400::13';
  const codec = SignalingCodec();

  // ==========================================================================
  // Outgoing: fanOutReconnect / fanOutAvailable
  // ==========================================================================

  group('fanOutReconnect', () {
    late SignalingService service;
    late List<(Uint8List, Uint8List)> sentMessages;

    setUp(() {
      sentMessages = [];
    });

    tearDown(() => service.dispose());

    test('sends RECONNECT to every well-connected friend', () async {
      service = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
          friend2Hex: _wellConnectedFriend(friend2Key),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };

      final sent = await service.fanOutReconnect(bobKey);

      expect(sent, equals(2));
      expect(sentMessages, hasLength(2));
      for (final (recipient, payload) in sentMessages) {
        final decoded = codec.decode(payload) as ReconnectMessage;
        expect(decoded.peerPubkey, equals(bobKey));
        expect([friendKey, friend2Key].any((k) => _pubkeyHex(k) == _pubkeyHex(recipient)),
            isTrue);
      }
    });

    test('sends RECONNECT to configured rendezvous servers when no friends exist', () async {
      service = SignalingService(
        store: _storeWithPeers(
          {},
          settings: SettingsState(
            rendezvousServers: [
              RendezvousServerSettings(pubkeyHex: anchorHex, address: anchorAddress),
            ],
          ),
        ),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };

      final sent = await service.fanOutReconnect(bobKey);

      expect(sent, equals(1));
      expect(sentMessages, hasLength(1));
      expect(_pubkeyHex(sentMessages.single.$1), equals(anchorHex));
      final decoded = codec.decode(sentMessages.single.$2) as ReconnectMessage;
      expect(decoded.peerPubkey, equals(bobKey));
    });

    test('returns 0 when there are no facilitators', () async {
      service = SignalingService(store: _storeWithPeers({}));
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };

      final sent = await service.fanOutReconnect(bobKey);

      expect(sent, equals(0));
      expect(sentMessages, isEmpty);
    });

    test('excludes the target itself from the facilitator set', () async {
      // Bob is one of the well-connected friends — he can't be a facilitator
      // for his own reconnection.
      service = SignalingService(
        store: _storeWithPeers({
          bobHex: _wellConnectedFriend(bobKey),
          friendHex: _wellConnectedFriend(friendKey),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };

      await service.fanOutReconnect(bobKey);

      expect(sentMessages, hasLength(1));
      expect(_pubkeyHex(sentMessages.single.$1), equals(friendHex));
    });

    test('orders facilitators lexicographically by pubkey hex', () async {
      // Configure two rendezvous servers — pubkeys are seed=5 and seed=6, so
      // anchorHex < anchor2Hex. The fan-out must hit them in that order.
      service = SignalingService(
        store: _storeWithPeers(
          {},
          settings: SettingsState(
            rendezvousServers: [
              // intentionally listed in reverse lexicographic order
              RendezvousServerSettings(pubkeyHex: anchor2Hex, address: anchor2Address),
              RendezvousServerSettings(pubkeyHex: anchorHex, address: anchorAddress),
            ],
          ),
        ),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };

      await service.fanOutReconnect(bobKey);

      expect(sentMessages, hasLength(2));
      expect(
        sentMessages.map((m) => _pubkeyHex(m.$1)).toList(),
        equals([anchorHex, anchor2Hex]),
        reason: 'facilitators must be visited in lexicographic order',
      );
    });
  });

  group('fanOutAvailable', () {
    late SignalingService service;
    late List<(Uint8List, Uint8List)> sentMessages;

    setUp(() {
      sentMessages = [];
    });

    tearDown(() => service.dispose());

    test("sends AVAILABLE to target's known RVs at the advertised address",
        () async {
      // Bob has previously told us he uses anchor as his RV at anchorAddress.
      // AVAILABLE should target Bob's RV at exactly that address.
      service = SignalingService(
        store: _storeWithPeers({
          bobHex: PeerState(
            publicKey: bobKey,
            nickname: 'Bob',
            connectionState: PeerConnectionState.connected,
            isFriend: true,
            knownRvServers: {anchorHex: anchorAddress},
          ),
        }),
      );
      final addressSends = <(Uint8List, String, Uint8List)>[];
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };
      service.sendSignalingToAddress =
          (recipient, address, payload) async {
        addressSends.add((recipient, address, payload));
        return true;
      };

      final sent = await service.fanOutAvailable(bobKey);

      expect(sent, equals(1));
      expect(addressSends, hasLength(1));
      expect(_pubkeyHex(addressSends.single.$1), equals(anchorHex));
      expect(addressSends.single.$2, equals(anchorAddress));
      final decoded =
          codec.decode(addressSends.single.$3) as AvailableMessage;
      expect(decoded.peerPubkey, equals(bobKey));
    });

    test('falls back to common well-connected friends when target RVs unknown',
        () async {
      service = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
          bobHex: _regularFriend(bobKey),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };

      final sent = await service.fanOutAvailable(bobKey);

      expect(sent, equals(1));
      expect(_pubkeyHex(sentMessages.single.$1), equals(friendHex));
    });

    test('combines target RVs with WC-friend fallback', () async {
      service = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
          bobHex: PeerState(
            publicKey: bobKey,
            nickname: 'Bob',
            connectionState: PeerConnectionState.connected,
            isFriend: true,
            knownRvServers: {
              anchorHex: anchorAddress,
              anchor2Hex: anchor2Address,
            },
          ),
        }),
      );
      final addressSends = <(Uint8List, String, Uint8List)>[];
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };
      service.sendSignalingToAddress =
          (recipient, address, payload) async {
        addressSends.add((recipient, address, payload));
        return true;
      };

      final sent = await service.fanOutAvailable(bobKey);

      expect(sent, equals(3));
      // 2 RVs go via address-aware send; 1 WC friend via pubkey-resolved send.
      expect(addressSends, hasLength(2));
      expect(sentMessages, hasLength(1));
      expect(
        addressSends.map((s) => _pubkeyHex(s.$1)).toSet(),
        equals({anchorHex, anchor2Hex}),
      );
      expect(_pubkeyHex(sentMessages.single.$1), equals(friendHex));
    });

    test('returns 0 when no target RVs and no WC friends', () async {
      service = SignalingService(
        store: _storeWithPeers({
          bobHex: _regularFriend(bobKey),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };

      final sent = await service.fanOutAvailable(bobKey);

      expect(sent, equals(0));
      expect(sentMessages, isEmpty);
    });
  });

  // ==========================================================================
  // Outgoing: requestDirectPunch (BLE-mediated direct PUNCH_INITIATE)
  // ==========================================================================

  group('requestDirectPunch', () {
    late SignalingService service;
    late List<(Uint8List, Uint8List)> sentMessages;

    setUp(() {
      sentMessages = [];
      service = SignalingService(
        store: _storeWithPeers({
          bobHex: _regularFriend(bobKey),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };
    });

    tearDown(() => service.dispose());

    test('sends PUNCH_INITIATE directly to the target friend', () async {
      final ok = await service.requestDirectPunch(
        bobKey,
        requesterPubkey: aliceKey,
        requesterIp: directPunchIp,
        requesterPort: 7000,
      );

      expect(ok, isTrue);
      expect(sentMessages, hasLength(1));
      expect(_pubkeyHex(sentMessages.single.$1), equals(bobHex));
      final decoded = codec.decode(sentMessages.single.$2) as PunchInitiateMessage;
      expect(decoded.peerPubkey, equals(aliceKey));
      expect(decoded.ip, equals(directPunchIp));
      expect(decoded.port, equals(7000));
    });

    test('returns false when target is not a friend', () async {
      service.dispose();
      service = SignalingService(
        store: _storeWithPeers({
          bobHex: _stranger(bobKey),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };

      final ok = await service.requestDirectPunch(
        bobKey,
        requesterPubkey: aliceKey,
        requesterIp: directPunchIp,
        requesterPort: 7000,
      );

      expect(ok, isFalse);
      expect(sentMessages, isEmpty);
    });
  });

  // ==========================================================================
  // Incoming: processAnnounceFromFriend
  // ==========================================================================

  group('processAnnounceFromFriend', () {
    late SignalingService service;
    late List<(Uint8List, Uint8List)> sentMessages;

    setUp(() {
      sentMessages = [];
      service = SignalingService(
        store: _storeWithPeers({
          bobHex: _regularFriend(bobKey),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };
    });

    tearDown(() => service.dispose());

    test('registers observed address in the local address table', () {
      service.processAnnounceFromFriend(
        bobKey,
        observedIp: '203.0.113.10',
        observedPort: 7000,
      );

      final entry = service.addressTable.lookup(bobHex);
      expect(entry, isNotNull);
      expect(entry!.ip, equals('203.0.113.10'));
      expect(entry.port, equals(7000));
    });

    test('reflects observed address back to sender via ADDR_REFLECT', () {
      service.processAnnounceFromFriend(
        bobKey,
        observedIp: reflectedIp,
        observedPort: 7000,
      );

      expect(sentMessages, hasLength(1));
      expect(_pubkeyHex(sentMessages.single.$1), equals(bobHex));
      final decoded = codec.decode(sentMessages.single.$2) as AddrReflectMessage;
      expect(decoded.ip, equals(reflectedIp));
      expect(decoded.port, equals(7000));
    });

    test('does not reflect when there is no observed address', () {
      service.processAnnounceFromFriend(
        bobKey,
        claimedAddress: '[2001:db8::1]:5000',
      );

      expect(sentMessages, isEmpty);
    });
  });

  // ==========================================================================
  // Incoming: trust filter and unsupported messages
  // ==========================================================================

  group('processSignaling trust filter', () {
    late SignalingService service;
    late List<(Uint8List, Uint8List)> sentMessages;
    Uint8List? lastReflectIp;

    setUp(() {
      sentMessages = [];
      lastReflectIp = null;
      service = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
          bobHex: _stranger(bobKey),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };
      service.onAddrReflected = (ip, port) {
        lastReflectIp = Uint8List.fromList(ip.codeUnits);
      };
    });

    tearDown(() => service.dispose());

    test('drops signaling from a non-friend, non-rendezvous sender', () {
      service.processSignaling(
        bobKey,
        codec.encode(AddrReflectMessage(ip: reflectedIp, port: 7000)),
      );
      expect(lastReflectIp, isNull);
    });

    test('accepts signaling from a friend', () {
      service.processSignaling(
        friendKey,
        codec.encode(AddrReflectMessage(ip: reflectedIp, port: 7000)),
      );
      expect(lastReflectIp, isNotNull);
    });
  });

  // ==========================================================================
  // Incoming callbacks: PunchInitiate, PunchReady, AddrReflect
  // ==========================================================================

  group('PunchInitiate callback', () {
    late SignalingService service;

    setUp(() {
      service = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
        }),
      );
      service.sendSignaling = (recipient, payload) async => true;
    });

    tearDown(() => service.dispose());

    test('fires onPunchInitiate with correct params', () {
      Uint8List? gotPeer;
      String? gotIp;
      int? gotPort;
      Uint8List? gotReadyRecipient;

      service.onPunchInitiate = (peer, ip, port, readyRecipient) {
        gotPeer = peer;
        gotIp = ip;
        gotPort = port;
        gotReadyRecipient = readyRecipient;
      };

      service.processSignaling(
        friendKey,
        codec.encode(PunchInitiateMessage(
          peerPubkey: bobKey,
          ip: directPunchIp,
          port: 7000,
        )),
      );

      expect(_pubkeyHex(gotPeer!), equals(bobHex));
      expect(gotIp, equals(directPunchIp));
      expect(gotPort, equals(7000));
      expect(_pubkeyHex(gotReadyRecipient!), equals(friendHex));
    });
  });

  group('PunchReady callback', () {
    late SignalingService service;

    setUp(() {
      service = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
        }),
      );
      service.sendSignaling = (recipient, payload) async => true;
    });

    tearDown(() => service.dispose());

    test('fires onPunchReady with the ready peer', () {
      Uint8List? gotPeer;
      service.onPunchReady = (peer) => gotPeer = peer;

      service.processSignaling(
        friendKey,
        codec.encode(PunchReadyMessage(peerPubkey: bobKey)),
      );

      expect(_pubkeyHex(gotPeer!), equals(bobHex));
    });
  });

  group('AddrReflect callback', () {
    late SignalingService service;

    setUp(() {
      service = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
        }),
      );
      service.sendSignaling = (recipient, payload) async => true;
    });

    tearDown(() => service.dispose());

    test('fires onAddrReflected with reflected address', () {
      String? gotIp;
      int? gotPort;
      service.onAddrReflected = (ip, port) {
        gotIp = ip;
        gotPort = port;
      };

      service.processSignaling(
        friendKey,
        codec.encode(AddrReflectMessage(ip: reflectedIp, port: 7000)),
      );

      expect(gotIp, equals(reflectedIp));
      expect(gotPort, equals(7000));
    });

    test('accepts reflection from the configured rendezvous server', () {
      final service2 = SignalingService(
        store: _storeWithPeers(
          {},
          settings: SettingsState(
            rendezvousServers: [
              RendezvousServerSettings(pubkeyHex: anchorHex, address: anchorAddress),
            ],
          ),
        ),
      );
      service2.sendSignaling = (recipient, payload) async => true;

      String? gotIp;
      service2.onAddrReflected = (ip, port) => gotIp = ip;

      service2.processSignaling(
        anchorKey,
        codec.encode(AddrReflectMessage(ip: reflectedIp, port: 7000)),
      );

      expect(gotIp, equals(reflectedIp));
      service2.dispose();
    });
  });

  // ==========================================================================
  // Incoming: client-side RECONNECT/AVAILABLE matcher (friends-based mediator)
  // ==========================================================================

  group('client-as-facilitator matcher', () {
    late SignalingService service;
    late List<(Uint8List, Uint8List)> sentMessages;

    setUp(() {
      sentMessages = [];
      service = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
          // Two friends — Alice and Bob — for whom this client is a mutual
          // mediator.
          aliceHex: _regularFriend(aliceKey),
          bobHex: _regularFriend(bobKey),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };
    });

    tearDown(() => service.dispose());

    test('matches RECONNECT(A→B) with AVAILABLE(B→A); both get PunchInitiate',
        () {
      service.processSignaling(
        aliceKey,
        codec.encode(ReconnectMessage(peerPubkey: bobKey)),
        observedIp: '198.51.100.10',
        observedPort: 7000,
      );
      expect(sentMessages, isEmpty,
          reason: 'no counterpart yet; matcher must park the request');

      service.processSignaling(
        bobKey,
        codec.encode(AvailableMessage(peerPubkey: aliceKey)),
        observedIp: '203.0.113.20',
        observedPort: 9001,
      );

      expect(sentMessages, hasLength(2));
      final toAlice = sentMessages.firstWhere((m) => m.$1 == aliceKey);
      final initiateToAlice =
          codec.decode(toAlice.$2) as PunchInitiateMessage;
      expect(initiateToAlice.peerPubkey, equals(bobKey));
      expect(initiateToAlice.ip, equals('203.0.113.20'));
      expect(initiateToAlice.port, equals(9001));

      final toBob = sentMessages.firstWhere((m) => m.$1 == bobKey);
      final initiateToBob = codec.decode(toBob.$2) as PunchInitiateMessage;
      expect(initiateToBob.peerPubkey, equals(aliceKey));
      expect(initiateToBob.ip, equals('198.51.100.10'));
      expect(initiateToBob.port, equals(7000));
    });

    test('drops RECONNECT/AVAILABLE without an observed source (BLE-arrived)',
        () {
      service.processSignaling(
        aliceKey,
        codec.encode(ReconnectMessage(peerPubkey: bobKey)),
        // observedIp/observedPort omitted — like a BLE delivery
      );
      expect(sentMessages, isEmpty);
    });
  });

  // ==========================================================================
  // Incoming: RV_LIST stores per-peer rendezvous server pubkeys
  // ==========================================================================

  group('RV_LIST handling', () {
    test("updates the friend's knownRvServers on receive", () {
      final store = _storeWithPeers({
        bobHex: _regularFriend(bobKey),
      });
      final service = SignalingService(store: store);
      service.sendSignaling = (recipient, payload) async => true;

      service.processSignaling(
        bobKey,
        codec.encode(RvListMessage(entries: [
          RvServerEntry(pubkey: anchorKey, address: anchorAddress),
          RvServerEntry(pubkey: anchor2Key, address: anchor2Address),
        ])),
      );

      final updated = store.state.peers.getPeerByPubkeyHex(bobHex);
      expect(updated, isNotNull);
      expect(
        updated!.knownRvServers,
        equals({anchorHex: anchorAddress, anchor2Hex: anchor2Address}),
      );

      service.dispose();
    });

    test(
        "subsequent fanOutAvailable targets the friend's advertised RVs at "
        'their advertised address', () async {
      final store = _storeWithPeers({
        bobHex: _regularFriend(bobKey),
      });
      final service = SignalingService(store: store);
      final addressSends = <(Uint8List, String, Uint8List)>[];
      service.sendSignaling = (recipient, payload) async => true;
      service.sendSignalingToAddress =
          (recipient, address, payload) async {
        addressSends.add((recipient, address, payload));
        return true;
      };

      // Bob tells us about his RV server.
      service.processSignaling(
        bobKey,
        codec.encode(RvListMessage(entries: [
          RvServerEntry(pubkey: anchorKey, address: anchorAddress),
        ])),
      );

      // Now we detect Bob went silent; AVAILABLE should target anchorKey
      // at anchorAddress.
      final sent = await service.fanOutAvailable(bobKey);

      expect(sent, equals(1));
      expect(addressSends, hasLength(1));
      expect(_pubkeyHex(addressSends.single.$1), equals(anchorHex));
      expect(addressSends.single.$2, equals(anchorAddress));

      service.dispose();
    });
  });

  // ==========================================================================
  // Address table TTL cleanup
  // ==========================================================================

  group('address table stale cleanup', () {
    test('removes entries older than TTL', () {
      final table = AddressTable();
      table.register(friendHex, '203.0.113.10', 7000);
      table.removeStale(Duration.zero);
      expect(table.lookup(friendHex), isNull);
    });

    test('keeps fresh entries', () {
      final table = AddressTable();
      table.register(friendHex, '203.0.113.10', 7000);
      table.removeStale(const Duration(seconds: 60));
      expect(table.lookup(friendHex), isNotNull);
    });
  });
}
