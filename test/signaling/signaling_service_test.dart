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

/// Build a store with specific peers pre-loaded.
Store<AppState> _storeWithPeers(Map<String, PeerState> peers) {
  return Store<AppState>(
    appReducer,
    initialState: AppState(
      peers: PeersState(peers: peers),
    ),
  );
}

/// Create a PeerState that qualifies as a well-connected friend.
PeerState _wellConnectedFriend(Uint8List pubkey, {String? udpAddress}) {
  return PeerState(
    publicKey: pubkey,
    nickname: 'Friend-${_pubkeyHex(pubkey).substring(0, 4)}',
    connectionState: PeerConnectionState.connected,
    isFriend: true,
    isWellConnected: true,
    udpAddress: udpAddress ?? '[2001:db8::1]:4001',
  );
}

/// Create a PeerState that is a regular friend (behind NAT).
PeerState _regularFriend(Uint8List pubkey, {String? udpAddress}) {
  return PeerState(
    publicKey: pubkey,
    nickname: 'Peer-${_pubkeyHex(pubkey).substring(0, 4)}',
    connectionState: PeerConnectionState.connected,
    isFriend: true,
    isWellConnected: false,
    udpAddress: udpAddress,
  );
}

/// Create a PeerState that is NOT a friend.
PeerState _stranger(Uint8List pubkey) {
  return PeerState(
    publicKey: pubkey,
    nickname: 'Stranger',
    connectionState: PeerConnectionState.connected,
    isFriend: false,
  );
}

void main() {
  // Three peers for testing: Alice (agent), Bob (agent), Friend (well-connected)
  final aliceKey = _testPubkey(1);
  final bobKey = _testPubkey(2);
  final friendKey = _testPubkey(3);
  final friend2Key = _testPubkey(4);
  final aliceHex = _pubkeyHex(aliceKey);
  final bobHex = _pubkeyHex(bobKey);
  final friendHex = _pubkeyHex(friendKey);
  final friend2Hex = _pubkeyHex(friend2Key);
  const aliceAdvertisedAddress = '[2001:db8:1::1]:5000';
  const bobAdvertisedAddress = '[2001:db8:2::1]:5000';
  const queriedBobIp = '2400::10';
  const queriedAliceIp = '2400::11';
  const reflectedIp = '2400::12';
  const directPunchIp = '2400::13';
  const codec = SignalingCodec();

  // =========================================================================
  // Agent role: querying and requesting
  // =========================================================================

  group('queryPeerAddress', () {
    late SignalingService service;
    late List<(Uint8List, Uint8List)> sentMessages;

    setUp(() {
      sentMessages = [];
      service = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };
    });

    tearDown(() => service.dispose());

    test('sends ADDR_QUERY to all well-connected friends', () async {
      final future =
          service.queryPeerAddress(bobKey, timeout: const Duration(seconds: 1));

      // Should have sent one ADDR_QUERY to the friend
      expect(sentMessages.length, 1);
      expect(sentMessages[0].$1, friendKey);

      final decoded = codec.decode(sentMessages[0].$2);
      expect(decoded, isA<AddrQueryMessage>());
      expect((decoded as AddrQueryMessage).targetPubkey, bobKey);

      // Let it time out
      final result = await future;
      expect(result, isNull);
    });

    test('returns address when friend responds with found', () async {
      final future =
          service.queryPeerAddress(bobKey, timeout: const Duration(seconds: 5));

      // Simulate friend's ADDR_RESPONSE (found)
      final response = AddrResponseMessage(
        targetPubkey: bobKey,
        ip: queriedBobIp,
        port: 9000,
      );
      // Friend is in the store as a friend, so processSignaling won't drop it
      service.processSignaling(friendKey, codec.encode(response));

      final result = await future;
      expect(result, isNotNull);
      expect(result!.ip, queriedBobIp);
      expect(result.port, 9000);
    });

    test('times out when friend responds with not-found', () async {
      final result = await service.queryPeerAddress(
        bobKey,
        timeout: const Duration(milliseconds: 100),
      );

      // Simulate friend's "not found" response
      final response = AddrResponseMessage(targetPubkey: bobKey);
      service.processSignaling(friendKey, codec.encode(response));

      // Not-found doesn't complete the query — it waits for other friends.
      // Since there's only one friend, this times out.
      expect(result, isNull);
    });

    test('returns null when no well-connected friends exist', () async {
      final emptyService = SignalingService(
        store: _storeWithPeers({}),
      );

      final result = await emptyService.queryPeerAddress(bobKey);
      expect(result, isNull);

      emptyService.dispose();
    });

    test('deduplicates concurrent queries for the same peer', () async {
      final future1 =
          service.queryPeerAddress(bobKey, timeout: const Duration(seconds: 5));
      final future2 =
          service.queryPeerAddress(bobKey, timeout: const Duration(seconds: 5));

      // Should send only one ADDR_QUERY (second call reuses the pending query)
      expect(sentMessages.length, 1);

      // Respond
      final response = AddrResponseMessage(
        targetPubkey: bobKey,
        ip: queriedAliceIp,
        port: 5000,
      );
      service.processSignaling(friendKey, codec.encode(response));

      final r1 = await future1;
      final r2 = await future2;
      expect(r1!.ip, queriedAliceIp);
      expect(r2!.ip, queriedAliceIp);
    });

    test('collects only facilitators that actually know the peer address',
        () async {
      final candidateMessages = <(Uint8List, Uint8List)>[];
      final candidateService = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
          friend2Hex: _wellConnectedFriend(
            friend2Key,
            udpAddress: '[2001:db8:3::1]:4001',
          ),
        }),
      );
      candidateService.sendSignaling = (recipient, payload) async {
        candidateMessages.add((recipient, payload));
        return true;
      };

      final future = candidateService.queryPeerAddressCandidates(
        bobKey,
        timeout: const Duration(seconds: 1),
      );

      expect(candidateMessages.length, 2);

      candidateService.processSignaling(
        friendKey,
        codec.encode(AddrResponseMessage(targetPubkey: bobKey)),
      );
      candidateService.processSignaling(
        friend2Key,
        codec.encode(AddrResponseMessage(
          targetPubkey: bobKey,
          ip: queriedBobIp,
          port: 8080,
        )),
      );

      final candidates = await future;
      expect(candidates.length, 1);
      expect(candidates.single.responderPubkey, friend2Key);
      expect(candidates.single.entry.ip, queriedBobIp);
      expect(candidates.single.entry.port, 8080);

      candidateService.dispose();
    });
  });

  group('requestHolePunch', () {
    late SignalingService service;
    late List<(Uint8List, Uint8List)> sentMessages;
    late Store<AppState> store;

    setUp(() {
      sentMessages = [];
      store = _storeWithPeers({
        friendHex: _wellConnectedFriend(friendKey),
      });
      service = SignalingService(store: store);
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };
    });

    tearDown(() => service.dispose());

    test('sends PUNCH_REQUEST to a well-connected friend', () async {
      await service.requestHolePunch(bobKey);

      expect(sentMessages.length, 1);
      expect(sentMessages[0].$1, friendKey);

      final decoded = codec.decode(sentMessages[0].$2);
      expect(decoded, isA<PunchRequestMessage>());
      expect((decoded as PunchRequestMessage).targetPubkey, bobKey);
    });

    test('dispatches HolePunchStartedAction', () async {
      await service.requestHolePunch(bobKey);

      expect(store.state.signaling.holePunchAttempts[bobHex],
          HolePunchStatus.requested);
    });

    test('does nothing when no well-connected friends exist', () async {
      final emptyService = SignalingService(
        store: _storeWithPeers({}),
      );
      emptyService.sendSignaling = (_, __) async => true;

      await emptyService.requestHolePunch(bobKey);

      // No messages sent, no action dispatched
      expect(emptyService.store.state.signaling.holePunchAttempts, isEmpty);

      emptyService.dispose();
    });
  });

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
      final sent = await service.requestDirectPunch(
        bobKey,
        requesterPubkey: aliceKey,
        requesterIp: directPunchIp,
        requesterPort: 9000,
      );

      expect(sent, isTrue);
      expect(sentMessages.length, 1);
      expect(sentMessages[0].$1, bobKey);

      final decoded = codec.decode(sentMessages[0].$2);
      expect(decoded, isA<PunchInitiateMessage>());
      expect((decoded as PunchInitiateMessage).peerPubkey, aliceKey);
      expect(decoded.ip, directPunchIp);
      expect(decoded.port, 9000);
    });

    test('returns false when target is not a friend', () async {
      final emptyService = SignalingService(
        store: _storeWithPeers({}),
      );
      emptyService.sendSignaling = (_, __) async => true;

      final sent = await emptyService.requestDirectPunch(
        bobKey,
        requesterPubkey: aliceKey,
        requesterIp: directPunchIp,
        requesterPort: 9000,
      );

      expect(sent, isFalse);
      emptyService.dispose();
    });
  });

  // =========================================================================
  // Well-connected friend role: serving queries and coordinating punches
  // =========================================================================

  group('processAnnounceFromFriend', () {
    late SignalingService service;
    late List<(Uint8List, Uint8List)> sentMessages;

    setUp(() {
      sentMessages = [];
      service = SignalingService(
        store: _storeWithPeers({
          aliceHex:
              _regularFriend(aliceKey, udpAddress: aliceAdvertisedAddress),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };
    });

    tearDown(() => service.dispose());

    test('registers friend address in address table', () {
      service.processAnnounceFromFriend(
        aliceKey,
        observedIp: reflectedIp,
        observedPort: 12345,
      );

      final entry = service.addressTable.lookup(aliceHex);
      expect(entry, isNotNull);
      expect(entry!.ip, reflectedIp);
      expect(entry.port, 12345);
    });

    test('prefers observed address over claimed address', () {
      service.processAnnounceFromFriend(
        aliceKey,
        claimedAddress: aliceAdvertisedAddress,
        observedIp: reflectedIp,
        observedPort: 9999,
      );

      final entry = service.addressTable.lookup(aliceHex);
      expect(entry!.ip, reflectedIp);
      expect(entry.port, 9999);
    });

    test('uses claimed address when no observed address', () {
      service.processAnnounceFromFriend(
        aliceKey,
        claimedAddress: aliceAdvertisedAddress,
      );

      final entry = service.addressTable.lookup(aliceHex);
      expect(entry!.ip, '2001:db8:1::1');
      expect(entry.port, 5000);
    });

    test('reflects observed address back to sender via ADDR_REFLECT', () {
      service.processAnnounceFromFriend(
        aliceKey,
        claimedAddress: aliceAdvertisedAddress,
        observedIp: reflectedIp,
        observedPort: 9999,
      );

      expect(sentMessages.length, 1);
      expect(sentMessages[0].$1, aliceKey);

      final decoded = codec.decode(sentMessages[0].$2);
      expect(decoded, isA<AddrReflectMessage>());
      final reflect = decoded as AddrReflectMessage;
      expect(reflect.ip, reflectedIp);
      expect(reflect.port, 9999);
    });

    test('does not reflect when no observed address', () {
      service.processAnnounceFromFriend(
        aliceKey,
        claimedAddress: aliceAdvertisedAddress,
      );

      // No ADDR_REFLECT sent
      expect(sentMessages, isEmpty);
    });

    test('ignores announce with no address at all', () {
      service.processAnnounceFromFriend(aliceKey);

      expect(service.addressTable.lookup(aliceHex), isNull);
      expect(sentMessages, isEmpty);
    });
  });

  group('ADDR_QUERY handling (friend side)', () {
    late SignalingService service;
    late List<(Uint8List, Uint8List)> sentMessages;

    setUp(() {
      sentMessages = [];
      service = SignalingService(
        store: _storeWithPeers({
          aliceHex:
              _regularFriend(aliceKey, udpAddress: aliceAdvertisedAddress),
          bobHex: _regularFriend(bobKey),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };
    });

    tearDown(() => service.dispose());

    test('responds with address when target is in address table', () {
      // Pre-populate address table (as if Bob sent ANNOUNCE)
      service.addressTable.register(bobHex, queriedBobIp, 8000);

      // Alice asks about Bob
      final query = AddrQueryMessage(targetPubkey: bobKey);
      service.processSignaling(aliceKey, codec.encode(query));

      expect(sentMessages.length, 1);
      expect(sentMessages[0].$1, aliceKey);

      final decoded = codec.decode(sentMessages[0].$2);
      expect(decoded, isA<AddrResponseMessage>());
      final response = decoded as AddrResponseMessage;
      expect(response.found, true);
      expect(response.ip, queriedBobIp);
      expect(response.port, 8000);
    });

    test('responds with not-found when target is not in address table', () {
      // Alice asks about Bob, but Bob hasn't registered
      final query = AddrQueryMessage(targetPubkey: bobKey);
      service.processSignaling(aliceKey, codec.encode(query));

      expect(sentMessages.length, 1);
      final decoded = codec.decode(sentMessages[0].$2);
      expect(decoded, isA<AddrResponseMessage>());
      expect((decoded as AddrResponseMessage).found, false);
    });

    test('falls back to friend udpAddress from peer state when table misses',
        () {
      final fallbackService = SignalingService(
        store: _storeWithPeers({
          aliceHex:
              _regularFriend(aliceKey, udpAddress: aliceAdvertisedAddress),
          bobHex: _regularFriend(bobKey, udpAddress: bobAdvertisedAddress),
        }),
      );
      fallbackService.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };

      // Bob is a trusted friend with a known udpAddress in Redux, but no
      // volatile signaling-table entry (e.g. after restart or cache drift).
      final query = AddrQueryMessage(targetPubkey: bobKey);
      fallbackService.processSignaling(aliceKey, codec.encode(query));

      expect(sentMessages.length, 1);
      final decoded = codec.decode(sentMessages[0].$2);
      expect(decoded, isA<AddrResponseMessage>());

      final response = decoded as AddrResponseMessage;
      expect(response.found, true);
      expect(response.ip, '2001:db8:2::1');
      expect(response.port, 5000);

      fallbackService.dispose();
    });

    test('drops signaling from non-friends', () {
      final strangerKey = _testPubkey(99);
      final strangerHex = _pubkeyHex(strangerKey);

      // Add stranger to store (not a friend)
      final store = _storeWithPeers({
        strangerHex: _stranger(strangerKey),
        aliceHex: _regularFriend(aliceKey),
      });
      final svc = SignalingService(store: store);
      svc.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };

      final query = AddrQueryMessage(targetPubkey: aliceKey);
      svc.processSignaling(strangerKey, codec.encode(query));

      // No response sent
      expect(sentMessages, isEmpty);

      svc.dispose();
    });
  });

  group('PUNCH_REQUEST handling (friend side)', () {
    late SignalingService service;
    late List<(Uint8List, Uint8List)> sentMessages;

    setUp(() {
      sentMessages = [];
      service = SignalingService(
        store: _storeWithPeers({
          aliceHex:
              _regularFriend(aliceKey, udpAddress: aliceAdvertisedAddress),
          bobHex: _regularFriend(bobKey, udpAddress: bobAdvertisedAddress),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };

      // Register both in address table
      service.addressTable.register(aliceHex, queriedAliceIp, 9001);
      service.addressTable.register(bobHex, queriedBobIp, 9002);
    });

    tearDown(() => service.dispose());

    test('sends PUNCH_INITIATE to both requester and target', () {
      final request = PunchRequestMessage(targetPubkey: bobKey);
      service.processSignaling(aliceKey, codec.encode(request));

      // Should send two PUNCH_INITIATE messages
      expect(sentMessages.length, 2);

      // One to Alice (requester) with Bob's address
      final toAlice =
          sentMessages.firstWhere((m) => _pubkeyHex(m.$1) == aliceHex);
      final aliceMsg = codec.decode(toAlice.$2) as PunchInitiateMessage;
      expect(aliceMsg.peerPubkey, bobKey);
      expect(aliceMsg.ip, queriedBobIp);
      expect(aliceMsg.port, 9002);

      // One to Bob (target) with Alice's address
      final toBob = sentMessages.firstWhere((m) => _pubkeyHex(m.$1) == bobHex);
      final bobMsg = codec.decode(toBob.$2) as PunchInitiateMessage;
      expect(bobMsg.peerPubkey, aliceKey);
      expect(bobMsg.ip, queriedAliceIp);
      expect(bobMsg.port, 9001);
    });

    test('ignores request when target is not a friend', () {
      final strangerKey = _testPubkey(77);

      final request = PunchRequestMessage(targetPubkey: strangerKey);
      service.processSignaling(aliceKey, codec.encode(request));

      expect(sentMessages, isEmpty);
    });

    test('ignores request when requester has no reachable address', () {
      final service = SignalingService(
        store: _storeWithPeers({
          aliceHex: _regularFriend(aliceKey),
          bobHex: _regularFriend(bobKey, udpAddress: bobAdvertisedAddress),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };
      service.addressTable.register(bobHex, queriedBobIp, 9002);

      service.processSignaling(
        aliceKey,
        codec.encode(PunchRequestMessage(targetPubkey: bobKey)),
      );

      expect(sentMessages, isEmpty);

      service.dispose();
    });

    test('ignores request when target has no reachable address', () {
      final service = SignalingService(
        store: _storeWithPeers({
          aliceHex:
              _regularFriend(aliceKey, udpAddress: aliceAdvertisedAddress),
          bobHex: _regularFriend(bobKey),
        }),
      );
      service.sendSignaling = (recipient, payload) async {
        sentMessages.add((recipient, payload));
        return true;
      };
      service.addressTable.register(aliceHex, queriedAliceIp, 9001);

      service.processSignaling(
        aliceKey,
        codec.encode(PunchRequestMessage(targetPubkey: bobKey)),
      );

      expect(sentMessages, isEmpty);

      service.dispose();
    });

    test('falls back to peer-state addresses when table entries are missing',
        () {
      service.addressTable.remove(aliceHex); // unregister Alice
      service.addressTable.remove(bobHex); // unregister Bob

      final request = PunchRequestMessage(targetPubkey: bobKey);
      service.processSignaling(aliceKey, codec.encode(request));

      expect(sentMessages.length, 2);
    });
  });

  // =========================================================================
  // Agent role: receiving callbacks
  // =========================================================================

  group('PUNCH_INITIATE callback', () {
    late SignalingService service;

    setUp(() {
      service = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
        }),
      );
      service.sendSignaling = (_, __) async => true;
    });

    tearDown(() => service.dispose());

    test('fires onPunchInitiate with correct params', () {
      Uint8List? receivedPubkey;
      String? receivedIp;
      int? receivedPort;
      Uint8List? readyRecipient;

      service.onPunchInitiate = (pubkey, ip, port, readyPeer) {
        receivedPubkey = pubkey;
        receivedIp = ip;
        receivedPort = port;
        readyRecipient = readyPeer;
      };

      final initiate = PunchInitiateMessage(
        peerPubkey: bobKey,
        ip: directPunchIp,
        port: 9000,
      );
      service.processSignaling(friendKey, codec.encode(initiate));

      expect(receivedPubkey, bobKey);
      expect(receivedIp, directPunchIp);
      expect(receivedPort, 9000);
      expect(readyRecipient, friendKey);
    });
  });

  group('ADDR_REFLECT callback', () {
    late SignalingService service;

    setUp(() {
      service = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
        }),
      );
      service.sendSignaling = (_, __) async => true;
    });

    tearDown(() => service.dispose());

    test('fires onAddrReflected with reflected address', () {
      String? reflectedAddress;
      int? reflectedPort;

      service.onAddrReflected = (ip, port) {
        reflectedAddress = ip;
        reflectedPort = port;
      };

      final reflect = AddrReflectMessage(ip: reflectedIp, port: 12345);
      service.processSignaling(friendKey, codec.encode(reflect));

      expect(reflectedAddress, reflectedIp);
      expect(reflectedPort, 12345);
    });
  });

  // =========================================================================
  // End-to-end: two agents + one well-connected friend
  // =========================================================================

  group('end-to-end: address query via friend', () {
    late SignalingService aliceService;
    late SignalingService friendService;

    setUp(() {
      // Alice's view: she knows the friend
      aliceService = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
        }),
      );

      // Friend's view: knows both Alice and Bob as friends
      friendService = SignalingService(
        store: _storeWithPeers({
          aliceHex:
              _regularFriend(aliceKey, udpAddress: aliceAdvertisedAddress),
          bobHex: _regularFriend(bobKey, udpAddress: bobAdvertisedAddress),
        }),
      );

      // Bob has registered his address with the friend
      friendService.addressTable.register(bobHex, queriedBobIp, 8080);

      // Wire: Alice → Friend (signaling goes to friend's processSignaling)
      aliceService.sendSignaling = (recipient, payload) async {
        if (_pubkeyHex(recipient) == friendHex) {
          friendService.processSignaling(aliceKey, payload);
          return true;
        }
        return false;
      };

      // Wire: Friend → Alice (responses go to Alice's processSignaling)
      friendService.sendSignaling = (recipient, payload) async {
        if (_pubkeyHex(recipient) == aliceHex) {
          aliceService.processSignaling(friendKey, payload);
          return true;
        }
        return false;
      };
    });

    tearDown(() {
      aliceService.dispose();
      friendService.dispose();
    });

    test('Alice discovers Bob address through friend', () async {
      final result = await aliceService.queryPeerAddress(bobKey);

      expect(result, isNotNull);
      expect(result!.ip, queriedBobIp);
      expect(result.port, 8080);
    });

    test('Alice gets null when Bob has no reachable address with friend',
        () async {
      friendService.addressTable.remove(bobHex);
      friendService = SignalingService(
        store: _storeWithPeers({
          aliceHex:
              _regularFriend(aliceKey, udpAddress: aliceAdvertisedAddress),
          bobHex: _regularFriend(bobKey),
        }),
      );
      friendService.sendSignaling = (recipient, payload) async {
        if (_pubkeyHex(recipient) == aliceHex) {
          aliceService.processSignaling(friendKey, payload);
          return true;
        }
        return false;
      };

      final result = await aliceService.queryPeerAddress(
        bobKey,
        timeout: const Duration(milliseconds: 200),
      );

      // Friend responds "not found", Alice waits for timeout (no other friends)
      expect(result, isNull);
    });
  });

  group('end-to-end: hole-punch coordination via friend', () {
    late SignalingService aliceService;
    late SignalingService bobService;
    late SignalingService friendService;
    late Store<AppState> aliceStore;

    // Track PUNCH_INITIATE callbacks
    List<(Uint8List, String, int)> alicePunchInitiates = [];
    List<(Uint8List, String, int)> bobPunchInitiates = [];

    setUp(() {
      alicePunchInitiates = [];
      bobPunchInitiates = [];

      aliceStore = _storeWithPeers({
        friendHex: _wellConnectedFriend(friendKey),
      });
      aliceService = SignalingService(store: aliceStore);
      aliceService.onPunchInitiate = (pubkey, ip, port, _) {
        alicePunchInitiates.add((pubkey, ip, port));
      };

      bobService = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
        }),
      );
      bobService.onPunchInitiate = (pubkey, ip, port, _) {
        bobPunchInitiates.add((pubkey, ip, port));
      };

      friendService = SignalingService(
        store: _storeWithPeers({
          aliceHex:
              _regularFriend(aliceKey, udpAddress: aliceAdvertisedAddress),
          bobHex: _regularFriend(bobKey, udpAddress: bobAdvertisedAddress),
        }),
      );

      // Both have registered addresses with the friend
      friendService.addressTable.register(aliceHex, queriedAliceIp, 9001);
      friendService.addressTable.register(bobHex, queriedBobIp, 9002);

      // Wire Alice ↔ Friend
      aliceService.sendSignaling = (recipient, payload) async {
        if (_pubkeyHex(recipient) == friendHex) {
          friendService.processSignaling(aliceKey, payload);
          return true;
        }
        return false;
      };

      // Wire Friend → Alice and Friend → Bob
      friendService.sendSignaling = (recipient, payload) async {
        final hex = _pubkeyHex(recipient);
        if (hex == aliceHex) {
          aliceService.processSignaling(friendKey, payload);
          return true;
        }
        if (hex == bobHex) {
          bobService.processSignaling(friendKey, payload);
          return true;
        }
        return false;
      };

      bobService.sendSignaling = (_, __) async => true;
    });

    tearDown(() {
      aliceService.dispose();
      bobService.dispose();
      friendService.dispose();
    });

    test('Alice requests punch, both sides receive PUNCH_INITIATE', () async {
      await aliceService.requestHolePunch(bobKey);

      // Alice should receive PUNCH_INITIATE with Bob's address
      expect(alicePunchInitiates.length, 1);
      expect(alicePunchInitiates[0].$1, bobKey);
      expect(alicePunchInitiates[0].$2, queriedBobIp);
      expect(alicePunchInitiates[0].$3, 9002);

      // Bob should receive PUNCH_INITIATE with Alice's address
      expect(bobPunchInitiates.length, 1);
      expect(bobPunchInitiates[0].$1, aliceKey);
      expect(bobPunchInitiates[0].$2, queriedAliceIp);
      expect(bobPunchInitiates[0].$3, 9001);
    });

    test('dispatches HolePunchStartedAction on request', () async {
      await aliceService.requestHolePunch(bobKey);

      expect(aliceStore.state.signaling.holePunchAttempts[bobHex],
          HolePunchStatus.requested);
    });

    test('punch request is dropped when target has no reachable address',
        () async {
      friendService = SignalingService(
        store: _storeWithPeers({
          aliceHex:
              _regularFriend(aliceKey, udpAddress: aliceAdvertisedAddress),
          bobHex: _regularFriend(bobKey),
        }),
      );
      friendService.addressTable.register(aliceHex, queriedAliceIp, 9001);
      friendService.sendSignaling = (recipient, payload) async {
        final hex = _pubkeyHex(recipient);
        if (hex == aliceHex) {
          aliceService.processSignaling(friendKey, payload);
          return true;
        }
        if (hex == bobHex) {
          bobService.processSignaling(friendKey, payload);
          return true;
        }
        return false;
      };

      await aliceService.requestHolePunch(bobKey);

      // Alice still dispatched HolePunchStartedAction (request was sent)
      expect(aliceStore.state.signaling.holePunchAttempts[bobHex],
          HolePunchStatus.requested);

      // But friend dropped the request — no PUNCH_INITIATE received
      expect(alicePunchInitiates, isEmpty);
      expect(bobPunchInitiates, isEmpty);
    });

    test(
        'falls back to friend udpAddress from peer state for punch coordination',
        () async {
      friendService.addressTable.remove(aliceHex);
      friendService.addressTable.remove(bobHex);

      await aliceService.requestHolePunch(bobKey);

      expect(alicePunchInitiates.length, 1);
      expect(alicePunchInitiates[0].$1, bobKey);
      expect(alicePunchInitiates[0].$2, '2001:db8:2::1');
      expect(alicePunchInitiates[0].$3, 5000);

      expect(bobPunchInitiates.length, 1);
      expect(bobPunchInitiates[0].$1, aliceKey);
      expect(bobPunchInitiates[0].$2, '2001:db8:1::1');
      expect(bobPunchInitiates[0].$3, 5000);
    });
  });

  group('end-to-end: PUNCH_READY forwarding via friend', () {
    late SignalingService aliceService;
    late SignalingService bobService;
    late SignalingService friendService;

    Uint8List? aliceReadyFrom;
    Uint8List? bobReadyFrom;

    setUp(() async {
      aliceReadyFrom = null;
      bobReadyFrom = null;

      aliceService = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
        }),
      );
      bobService = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
        }),
      );
      friendService = SignalingService(
        store: _storeWithPeers({
          aliceHex:
              _regularFriend(aliceKey, udpAddress: aliceAdvertisedAddress),
          bobHex: _regularFriend(bobKey, udpAddress: bobAdvertisedAddress),
        }),
      );

      aliceService.onPunchReady = (peerPubkey) {
        aliceReadyFrom = peerPubkey;
      };
      bobService.onPunchReady = (peerPubkey) {
        bobReadyFrom = peerPubkey;
      };

      friendService.addressTable.register(aliceHex, queriedAliceIp, 9001);
      friendService.addressTable.register(bobHex, queriedBobIp, 9002);

      aliceService.sendSignaling = (recipient, payload) async {
        if (_pubkeyHex(recipient) == friendHex) {
          friendService.processSignaling(aliceKey, payload);
          return true;
        }
        return false;
      };
      bobService.sendSignaling = (recipient, payload) async {
        if (_pubkeyHex(recipient) == friendHex) {
          friendService.processSignaling(bobKey, payload);
          return true;
        }
        return false;
      };
      friendService.sendSignaling = (recipient, payload) async {
        final hex = _pubkeyHex(recipient);
        if (hex == aliceHex) {
          aliceService.processSignaling(friendKey, payload);
          return true;
        }
        if (hex == bobHex) {
          bobService.processSignaling(friendKey, payload);
          return true;
        }
        return false;
      };

      await aliceService.requestHolePunch(bobKey);
    });

    tearDown(() {
      aliceService.dispose();
      bobService.dispose();
      friendService.dispose();
    });

    test('facilitator forwards readiness to the counterpart peer', () async {
      final sent = await bobService.sendPunchReady(friendKey, bobKey);

      expect(sent, isTrue);
      expect(aliceReadyFrom, bobKey);
      expect(bobReadyFrom, isNull);
    });
  });

  group('end-to-end: direct punch request to target friend', () {
    late SignalingService aliceService;
    late SignalingService bobService;

    List<(Uint8List, String, int)> bobPunchInitiates = [];

    setUp(() {
      bobPunchInitiates = [];

      aliceService = SignalingService(
        store: _storeWithPeers({
          bobHex: _regularFriend(bobKey),
        }),
      );

      bobService = SignalingService(
        store: _storeWithPeers({
          aliceHex: _regularFriend(aliceKey),
        }),
      );
      bobService.onPunchInitiate = (pubkey, ip, port, _) {
        bobPunchInitiates.add((pubkey, ip, port));
      };

      aliceService.sendSignaling = (recipient, payload) async {
        if (_pubkeyHex(recipient) == bobHex) {
          bobService.processSignaling(aliceKey, payload);
          return true;
        }
        return false;
      };
      bobService.sendSignaling = (_, __) async => true;
    });

    tearDown(() {
      aliceService.dispose();
      bobService.dispose();
    });

    test('target receives PUNCH_INITIATE directly from the requester',
        () async {
      final sent = await aliceService.requestDirectPunch(
        bobKey,
        requesterPubkey: aliceKey,
        requesterIp: directPunchIp,
        requesterPort: 9000,
      );

      expect(sent, isTrue);
      expect(bobPunchInitiates.length, 1);
      expect(bobPunchInitiates[0].$1, aliceKey);
      expect(bobPunchInitiates[0].$2, directPunchIp);
      expect(bobPunchInitiates[0].$3, 9000);
    });
  });

  // =========================================================================
  // Lifecycle and edge cases
  // =========================================================================

  group('dispose', () {
    test('completes pending queries with null', () async {
      final service = SignalingService(
        store: _storeWithPeers({
          friendHex: _wellConnectedFriend(friendKey),
        }),
      );
      service.sendSignaling = (_, __) async => true;

      final future = service.queryPeerAddress(
        bobKey,
        timeout: const Duration(seconds: 30),
      );

      service.dispose();

      final result = await future;
      expect(result, isNull);
    });
  });

  group('address table stale cleanup', () {
    test('removes entries older than TTL', () {
      final table = AddressTable();
      table.register('peer1', '1.1.1.1', 100);

      // Simulate time passing
      table.removeStale(Duration.zero);

      expect(table.lookup('peer1'), isNull);
    });

    test('keeps fresh entries', () {
      final table = AddressTable();
      table.register('peer1', '1.1.1.1', 100);

      table.removeStale(const Duration(minutes: 5));

      expect(table.lookup('peer1'), isNotNull);
    });
  });
}
