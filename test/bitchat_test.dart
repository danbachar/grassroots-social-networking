import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bitchat_transport/bitchat_transport.dart';
import 'package:bitchat_transport/src/mesh/bloom_filter.dart';
import 'package:bitchat_transport/src/mesh/fragment_handler.dart';

void main() {
  group('BitchatPacket', () {
    late Uint8List testPubkey;
    late Uint8List testPayload;
    
    setUp(() {
      testPubkey = Uint8List.fromList(List.generate(32, (i) => i));
      testPayload = Uint8List.fromList([1, 2, 3, 4, 5]);
    });
    
    test('serializes and deserializes correctly', () {
      final packet = BitchatPacket(
        type: PacketType.message,
        ttl: 5,
        senderPubkey: testPubkey,
        payload: testPayload,
      );
      
      final serialized = packet.serialize();
      final deserialized = BitchatPacket.deserialize(serialized);
      
      expect(deserialized.type, equals(packet.type));
      expect(deserialized.ttl, equals(packet.ttl));
      expect(deserialized.packetId, equals(packet.packetId));
      expect(deserialized.senderPubkey, equals(packet.senderPubkey));
      expect(deserialized.payload, equals(packet.payload));
      expect(deserialized.isBroadcast, isTrue);
    });
    
    test('serializes with recipient pubkey', () {
      final recipientPubkey = Uint8List.fromList(List.generate(32, (i) => 32 + i));
      
      final packet = BitchatPacket(
        type: PacketType.message,
        ttl: 7,
        senderPubkey: testPubkey,
        recipientPubkey: recipientPubkey,
        payload: testPayload,
      );
      
      final serialized = packet.serialize();
      final deserialized = BitchatPacket.deserialize(serialized);
      
      expect(deserialized.isBroadcast, isFalse);
      expect(deserialized.recipientPubkey, equals(recipientPubkey));
    });
    
    test('decrements TTL correctly', () {
      final packet = BitchatPacket(
        type: PacketType.message,
        ttl: 5,
        senderPubkey: testPubkey,
        payload: testPayload,
      );
      
      final decremented = packet.decrementTtl();
      expect(decremented.ttl, equals(4));
      expect(decremented.packetId, equals(packet.packetId));
    });
    
    test('throws on TTL below zero', () {
      final packet = BitchatPacket(
        type: PacketType.message,
        ttl: 0,
        senderPubkey: testPubkey,
        payload: testPayload,
      );
      
      expect(() => packet.decrementTtl(), throwsStateError);
    });
    
    test('throws on invalid pubkey length', () {
      expect(
        () => BitchatPacket(
          type: PacketType.message,
          senderPubkey: Uint8List(16), // Wrong length
          payload: testPayload,
        ),
        throwsArgumentError,
      );
    });
  });
  
  group('BloomFilter', () {
    test('returns false for items not added', () {
      final filter = BloomFilter();
      expect(filter.mightContain('test-item'), isFalse);
    });
    
    test('returns true for added items', () {
      final filter = BloomFilter();
      filter.add('test-item');
      expect(filter.mightContain('test-item'), isTrue);
    });
    
    test('checkAndAdd returns correct values', () {
      final filter = BloomFilter();
      
      // First time - not present
      expect(filter.checkAndAdd('item1'), isFalse);
      
      // Second time - already present
      expect(filter.checkAndAdd('item1'), isTrue);
      
      // Different item - not present
      expect(filter.checkAndAdd('item2'), isFalse);
    });
    
    test('clears correctly', () {
      final filter = BloomFilter();
      filter.add('test-item');
      expect(filter.mightContain('test-item'), isTrue);
      
      filter.clear();
      expect(filter.mightContain('test-item'), isFalse);
    });
    
    test('handles many items without excessive false positives', () {
      final filter = BloomFilter();
      
      // Add 1000 items
      for (var i = 0; i < 1000; i++) {
        filter.add('item-$i');
      }
      
      // All added items should be found
      for (var i = 0; i < 1000; i++) {
        expect(filter.mightContain('item-$i'), isTrue);
      }
      
      // Check false positive rate on items NOT added
      var falsePositives = 0;
      for (var i = 1000; i < 2000; i++) {
        if (filter.mightContain('item-$i')) {
          falsePositives++;
        }
      }
      
      // False positive rate should be low (< 5%)
      expect(falsePositives, lessThan(50));
    });
  });
  
  group('FragmentHandler', () {
    late FragmentHandler handler;
    late Uint8List testPubkey;
    
    setUp(() {
      handler = FragmentHandler();
      testPubkey = Uint8List.fromList(List.generate(32, (i) => i));
    });
    
    tearDown(() {
      handler.dispose();
    });
    
    test('does not fragment small payloads', () {
      final smallPayload = Uint8List(100);
      expect(handler.needsFragmentation(smallPayload), isFalse);
    });
    
    test('fragments large payloads', () {
      final largePayload = Uint8List(1000);
      expect(handler.needsFragmentation(largePayload), isTrue);
    });
    
    test('fragments and reassembles correctly', () {
      final payload = Uint8List.fromList(List.generate(1500, (i) => i % 256));
      
      final fragmented = handler.fragment(
        payload: payload,
        senderPubkey: testPubkey,
      );
      
      expect(fragmented.fragments.length, greaterThan(1));
      expect(fragmented.fragments.first.type, equals(PacketType.fragmentStart));
      expect(fragmented.fragments.last.type, equals(PacketType.fragmentEnd));
      
      // Process all fragments
      Uint8List? result;
      for (final fragment in fragmented.fragments) {
        result = handler.processFragment(fragment);
      }
      
      // Last fragment should trigger reassembly
      expect(result, isNotNull);
      expect(result, equals(payload));
    });
    
    test('returns null for incomplete fragments', () {
      final payload = Uint8List.fromList(List.generate(1500, (i) => i % 256));
      
      final fragmented = handler.fragment(
        payload: payload,
        senderPubkey: testPubkey,
      );
      
      // Process only first fragment
      final result = handler.processFragment(fragmented.fragments.first);
      expect(result, isNull);
    });
  });
  
  group('BitchatIdentity', () {
    test('derives BLE service UUID from public key', () {
      final pubkey = Uint8List.fromList(List.generate(32, (i) => i));
      final privkey = Uint8List.fromList(List.generate(64, (i) => i));
      
      final identity = BitchatIdentity(
        publicKey: pubkey,
        privateKey: privkey,
      );
      
      // UUID should be derived from last 16 bytes of pubkey
      final uuid = identity.bleServiceUuid;
      expect(uuid.length, equals(36)); // UUID format with dashes
      expect(uuid, contains('-'));
    });
    
    test('throws on invalid key lengths', () {
      expect(
        () => BitchatIdentity(
          publicKey: Uint8List(16), // Wrong length
          privateKey: Uint8List(64),
        ),
        throwsArgumentError,
      );
      
      expect(
        () => BitchatIdentity(
          publicKey: Uint8List(32),
          privateKey: Uint8List(32), // Wrong length
        ),
        throwsArgumentError,
      );
    });
  });
  
  group('Peer', () {
    test('creates peer with correct state', () {
      final pubkey = Uint8List.fromList(List.generate(32, (i) => i));
      
      final peer = Peer(publicKey: pubkey, transport: PeerTransport.bleDirect);
      
      expect(peer.connectionState, equals(PeerConnectionState.discovered));
      expect(peer.isReachable, isFalse);
    });
    
    test('updates from ANNOUNCE correctly', () {
      final pubkey = Uint8List.fromList(List.generate(32, (i) => i));
      
      final peer = Peer(publicKey: pubkey, transport: PeerTransport.bleDirect);
      peer.updateFromAnnounce(
        nickname: 'Alice',
        protocolVersion: 1,
        receivedAt: DateTime.now(),
      );
      
      expect(peer.nickname, equals('Alice'));
      expect(peer.displayName, equals('Alice'));
      expect(peer.connectionState, equals(PeerConnectionState.connected));
      expect(peer.isReachable, isTrue);
    });
    
    test('generates correct display name', () {
      final pubkey = Uint8List.fromList(List.generate(32, (i) => i));
      
      final peer = Peer(publicKey: pubkey, transport: PeerTransport.bleDirect);
      
      // Without nickname, should use fingerprint
      expect(peer.displayName, equals(peer.shortFingerprint));
      
      // With nickname
      peer.nickname = 'Bob';
      expect(peer.displayName, equals('Bob'));
    });
  });
}
