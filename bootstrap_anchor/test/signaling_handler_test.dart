import 'dart:io';
import 'dart:typed_data';

import 'package:bootstrap_anchor/src/address_table.dart';
import 'package:bootstrap_anchor/src/identity.dart';
import 'package:bootstrap_anchor/src/peer_table.dart';
import 'package:bootstrap_anchor/src/protocol.dart';
import 'package:bootstrap_anchor/src/signaling_codec.dart';
import 'package:bootstrap_anchor/src/signaling_handler.dart';
import 'package:test/test.dart';

Future<Protocol> _createProtocol() async {
  final identity = await AnchorIdentity.generate(nickname: 'anchor');
  return Protocol(identity: identity);
}

Uint8List _pubkey(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class _SentSignal {
  final Uint8List recipient;
  final SignalingMessage message;

  const _SentSignal(this.recipient, this.message);
}

void main() {
  group('AddressTable', () {
    test('stores separate IPv4 and IPv6 entries per pubkey', () {
      final table = AddressTable();
      final pubkeyHex = _hex(_pubkey(1));

      table.register(pubkeyHex, '2001:db8::20', 9000);
      table.register(pubkeyHex, '203.0.113.20', 9001);

      final ipv6Entry = table.lookup(
        pubkeyHex,
        family: InternetAddressType.IPv6,
      );
      final ipv4Entry = table.lookup(
        pubkeyHex,
        family: InternetAddressType.IPv4,
      );

      expect(ipv6Entry, isNotNull);
      expect(ipv6Entry!.ip, equals('2001:db8::20'));
      expect(ipv6Entry.port, equals(9000));
      expect(ipv4Entry, isNotNull);
      expect(ipv4Entry!.ip, equals('203.0.113.20'));
      expect(ipv4Entry.port, equals(9001));
      expect(table.length, equals(2));
    });

    test('removeStale preserves protected pubkeys', () {
      final table = AddressTable();
      final livePubkeyHex = _hex(_pubkey(1));
      final stalePubkeyHex = _hex(_pubkey(2));

      table.register(livePubkeyHex, '2001:db8::20', 9000);
      table.register(stalePubkeyHex, '2001:db8::21', 9001);

      table.removeStale(
        Duration.zero,
        protectedPubkeys: {livePubkeyHex},
      );

      expect(table.lookup(livePubkeyHex), isNotNull);
      expect(table.lookup(stalePubkeyHex), isNull);
      expect(table.length, equals(1));
    });
  });

  group('SignalingHandler', () {
    late AddressTable addressTable;
    late PeerTable peerTable;
    late SignalingCodec codec;
    late SignalingHandler handler;
    late List<_SentSignal> sentSignals;
    late Uint8List aPubkey;
    late Uint8List bPubkey;

    setUp(() async {
      addressTable = AddressTable();
      peerTable = PeerTable();
      codec = const SignalingCodec();
      aPubkey = _pubkey(1);
      bPubkey = _pubkey(2);
      handler = SignalingHandler(
        protocol: await _createProtocol(),
        peerTable: peerTable,
        addressTable: addressTable,
        codec: codec,
      );
      sentSignals = <_SentSignal>[];
      handler.sendSignaling = (recipientPubkey, payload) async {
        sentSignals.add(_SentSignal(recipientPubkey, codec.decode(payload)));
        return true;
      };

      peerTable.addVerified(_hex(aPubkey), nickname: 'A');
      peerTable.addVerified(_hex(bPubkey), nickname: 'B');
    });

    test('processAnnounce reflects the observed address back', () {
      final announce = AnnounceData(
        publicKey: aPubkey,
        nickname: 'A',
        protocolVersion: 1,
        udpAddress: '[2001:db8::99]:7000',
      );

      handler.processAnnounce(
        announce,
        observedIp: '2001:db8::10',
        observedPort: 7001,
      );

      expect(
        addressTable.lookup(_hex(aPubkey)),
        isNull,
        reason: 'processAnnounce must not touch the address table',
      );

      expect(sentSignals, hasLength(1));
      expect(sentSignals.single.recipient, equals(aPubkey));
      final reflect = sentSignals.single.message as AddrReflectMessage;
      expect(reflect.ip, equals('2001:db8::10'));
      expect(reflect.port, equals(7001));
    });

    test(
      'first request is parked until counterpart arrives, then both '
      'sides receive a PunchInitiate',
      () {
        // A (whose IP changed) sends RECONNECT first.
        handler.processSignaling(
          aPubkey,
          codec.encode(ReconnectMessage(peerPubkey: bPubkey)),
          observedIp: '198.51.100.10',
          observedPort: 7000,
        );
        expect(sentSignals, isEmpty,
            reason: 'no counterpart yet — server must park the request');
        expect(
          addressTable.lookup(_hex(aPubkey)),
          isNotNull,
          reason: 'sender address recorded from observed source',
        );

        // B (who detected A went silent) sends AVAILABLE — match!
        handler.processSignaling(
          bPubkey,
          codec.encode(AvailableMessage(peerPubkey: aPubkey)),
          observedIp: '203.0.113.20',
          observedPort: 9001,
        );

        expect(sentSignals, hasLength(2),
            reason: 'both sides must receive a PunchInitiate');

        final toA = sentSignals.firstWhere((s) => s.recipient == aPubkey);
        final initiateToA = toA.message as PunchInitiateMessage;
        expect(initiateToA.peerPubkey, equals(bPubkey));
        expect(initiateToA.ip, equals('203.0.113.20'));
        expect(initiateToA.port, equals(9001));

        final toB = sentSignals.firstWhere((s) => s.recipient == bPubkey);
        final initiateToB = toB.message as PunchInitiateMessage;
        expect(initiateToB.peerPubkey, equals(aPubkey));
        expect(initiateToB.ip, equals('198.51.100.10'));
        expect(initiateToB.port, equals(7000));
      },
    );

    test('matching is symmetric — AVAILABLE arriving first also works', () {
      handler.processSignaling(
        bPubkey,
        codec.encode(AvailableMessage(peerPubkey: aPubkey)),
        observedIp: '203.0.113.20',
        observedPort: 9001,
      );
      expect(sentSignals, isEmpty);

      handler.processSignaling(
        aPubkey,
        codec.encode(ReconnectMessage(peerPubkey: bPubkey)),
        observedIp: '198.51.100.10',
        observedPort: 7000,
      );

      expect(sentSignals, hasLength(2));
    });

    test('forwards PUNCH_READY to the counterpart after coordination', () {
      handler.processSignaling(
        aPubkey,
        codec.encode(ReconnectMessage(peerPubkey: bPubkey)),
        observedIp: '198.51.100.10',
        observedPort: 7000,
      );
      handler.processSignaling(
        bPubkey,
        codec.encode(AvailableMessage(peerPubkey: aPubkey)),
        observedIp: '203.0.113.20',
        observedPort: 9001,
      );
      sentSignals.clear();

      handler.processSignaling(
        aPubkey,
        codec.encode(PunchReadyMessage(peerPubkey: bPubkey)),
        observedIp: '198.51.100.10',
        observedPort: 7000,
      );

      expect(sentSignals, hasLength(1));
      expect(sentSignals.single.recipient, equals(bPubkey));
      expect(sentSignals.single.message, isA<PunchReadyMessage>());
    });

    test('drops requests with sender targeting itself', () {
      handler.processSignaling(
        aPubkey,
        codec.encode(ReconnectMessage(peerPubkey: aPubkey)),
        observedIp: '198.51.100.10',
        observedPort: 7000,
      );
      expect(sentSignals, isEmpty);
    });

    test('drops duplicate coordination attempts inside the cooldown window',
        () {
      handler.processSignaling(
        aPubkey,
        codec.encode(ReconnectMessage(peerPubkey: bPubkey)),
        observedIp: '198.51.100.10',
        observedPort: 7000,
      );
      handler.processSignaling(
        bPubkey,
        codec.encode(AvailableMessage(peerPubkey: aPubkey)),
        observedIp: '203.0.113.20',
        observedPort: 9001,
      );
      expect(sentSignals, hasLength(2));
      sentSignals.clear();

      // Retry immediately — still inside cooldown. Server should drop it.
      handler.processSignaling(
        aPubkey,
        codec.encode(ReconnectMessage(peerPubkey: bPubkey)),
        observedIp: '198.51.100.11',
        observedPort: 7001,
      );
      expect(sentSignals, isEmpty);
    });
  });
}
