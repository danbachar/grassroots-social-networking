import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/store/settings_reducer.dart';
import 'package:grassroots_networking/src/store/settings_actions.dart';
import 'package:grassroots_networking/src/store/settings_state.dart';
import 'package:grassroots_networking/src/models/block.dart';
import 'package:grassroots_networking/src/testbed/bulk_flow_driver.dart';
import 'package:grassroots_networking/src/testbed/testbed_config.dart';
import 'package:grassroots_networking/src/trace/wire_ledger.dart';

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _pubkey(int base) =>
    Uint8List.fromList(List.generate(32, (i) => (base + i) & 0xff));

BulkFlowConfig _config({
  List<BulkFlow>? flows,
  int payloadBytes = 100,
  int durationMs = 1000,
  int inFlight = 2,
}) =>
    BulkFlowConfig(
      roster: [
        WorkloadRosterEntry(label: 'A', pubkeyHex: _hex(_pubkey(0))),
        WorkloadRosterEntry(label: 'B', pubkeyHex: _hex(_pubkey(100))),
        WorkloadRosterEntry(label: 'C', pubkeyHex: _hex(_pubkey(200))),
      ],
      flows: flows ??
          const [
            BulkFlow(srcLabel: 'A', dstLabel: 'B'),
            BulkFlow(srcLabel: 'B', dstLabel: 'A'),
          ],
      payloadBytes: payloadBytes,
      durationMs: durationMs,
      inFlight: inFlight,
    );

void main() {
  group('BulkFlowDriver', () {
    test('fires exactly inFlight sends per source flow on start', () {
      final sent = <String>[];
      final driver = BulkFlowDriver(
        send: (recipient, payload, {String? messageId}) async {
          sent.add(messageId!);
          return messageId;
        },
        log: (_) {},
      );
      driver.start(config: _config(), myPubkeyHex: _hex(_pubkey(0)));
      expect(driver.isRunning, isTrue);
      // Only A>B has this device as source; B>A does not.
      expect(sent, [
        BulkFlowDriver.messageIdFor('A', 'B', 0),
        BulkFlowDriver.messageIdFor('A', 'B', 1),
      ]);
      driver.stop();
    });

    test('an ACK refills the window; unknown/duplicate ACKs do not', () {
      final sent = <String>[];
      final driver = BulkFlowDriver(
        send: (recipient, payload, {String? messageId}) async {
          sent.add(messageId!);
          return messageId;
        },
        log: (_) {},
      );
      driver.start(config: _config(), myPubkeyHex: _hex(_pubkey(0)));
      final first = sent.first;

      driver.onAck(first);
      expect(sent.length, 3);
      expect(sent.last, BulkFlowDriver.messageIdFor('A', 'B', 2));

      driver.onAck(first); // duplicate — already consumed
      driver.onAck('not-a-real-id');
      expect(sent.length, 3);

      // Every fired id is unique: the driver never re-sends.
      expect(sent.toSet().length, sent.length);
      driver.stop();
    });

    test('window closes after durationMs; late ACKs stop refilling', () {
      fakeAsync((async) {
        final sent = <String>[];
        final driver = BulkFlowDriver(
          send: (recipient, payload, {String? messageId}) async {
            sent.add(messageId!);
            return messageId;
          },
          log: (_) {},
        );
        driver.start(
            config: _config(durationMs: 500), myPubkeyHex: _hex(_pubkey(0)));
        expect(sent.length, 2);

        async.elapse(const Duration(milliseconds: 600));
        expect(driver.isRunning, isFalse);

        driver.onAck(sent.first);
        expect(sent.length, 2, reason: 'no sends after the window closes');
      });
    });

    test('status reports per-flow sent/acked/ackedBytes', () {
      final sent = <String>[];
      final driver = BulkFlowDriver(
        send: (recipient, payload, {String? messageId}) async {
          sent.add(messageId!);
          return messageId;
        },
        log: (_) {},
      );
      driver.start(
          config: _config(payloadBytes: 250), myPubkeyHex: _hex(_pubkey(0)));
      driver.onAck(sent.first);
      final status = driver.status.single;
      expect(status.flowLabel, 'A>B');
      expect(status.sent, 3);
      expect(status.acked, 1);
      expect(status.ackedBytes, 250);
      driver.stop();
    });

    test('device not in roster or with no source flows stays inert', () {
      var sends = 0;
      final driver = BulkFlowDriver(
        send: (recipient, payload, {String? messageId}) async {
          sends++;
          return messageId;
        },
        log: (_) {},
      );
      driver.start(config: _config(), myPubkeyHex: _hex(_pubkey(50)));
      expect(driver.isRunning, isFalse);

      driver.start(
        config: _config(flows: const [BulkFlow(srcLabel: 'B', dstLabel: 'C')]),
        myPubkeyHex: _hex(_pubkey(0)),
      );
      expect(driver.isRunning, isFalse);
      expect(sends, 0);
    });

    test('payload bytes match config and the seq-derived pattern', () {
      late Uint8List captured;
      final driver = BulkFlowDriver(
        send: (recipient, payload, {String? messageId}) async {
          captured = payload;
          return messageId;
        },
        log: (_) {},
      );
      driver.start(
        config: _config(payloadBytes: 64, inFlight: 1),
        myPubkeyHex: _hex(_pubkey(0)),
      );
      expect(captured.length, 64);
      // Byte 0 is the reserved testbed marker so synthetic traffic is never
      // classified as a real block class in the wire-byte breakdown.
      expect(captured[0], testbedPayloadMarker);
      expect(captured[5], 5); // seq-derived pattern elsewhere
      driver.stop();
    });

    test('BulkFlowConfig round-trips through JSON', () {
      final config = _config();
      final restored = BulkFlowConfig.fromJson(config.toJson());
      expect(restored, config);
    });
  });

  group('SetBulkFlowConfigAction', () {
    test('sets and clears the settings field', () {
      final config = _config();
      var state =
          settingsReducer(SettingsState.initial, SetBulkFlowConfigAction(config));
      expect(state.bulkFlowConfig, config);
      state = settingsReducer(state, SetBulkFlowConfigAction(null));
      expect(state.bulkFlowConfig, isNull);
    });

    test('bulkFlowConfig survives the settings JSON round-trip', () {
      final state =
          SettingsState.initial.copyWith(bulkFlowConfig: _config());
      final restored = SettingsState.fromJson(state.toJson());
      expect(restored.bulkFlowConfig, state.bulkFlowConfig);
    });
  });

  group('WireLedger', () {
    Uint8List packet(int type, int length) {
      final p = Uint8List(length);
      p[0] = type;
      return p;
    }

    test('classifies by outer type byte and accumulates deltas', () {
      final ledger = WireLedger();
      ledger.onTx(packet(0x01, 200)); // announce
      ledger.onTx(packet(0x01, 200));
      ledger.onTx(packet(0x02, 96)); // handshake
      ledger.onRx(packet(0x03, 500)); // secure
      ledger.onRx(packet(0x7f, 10)); // unknown

      final record = ledger.drainRecord(transport: 'ble')!;
      expect(record['type'], 'wire');
      expect(record['transport'], 'ble');
      expect(record['txBytes'], {'announce': 400, 'handshake': 96});
      expect(record['txPackets'], {'announce': 2, 'handshake': 1});
      expect(record['rxBytes'], {'secure': 500, 'other': 10});
      expect(record['rxPackets'], {'secure': 1, 'other': 1});
    });

    test('tx secure is split by inner content; rx stays aggregate', () {
      final ledger = WireLedger()
        ..secureContentFor = (id) => id.startsWith('aaaaaaaa') ? 'data:say'
            : id.startsWith('bbbbbbbb') ? 'ack' : '';
      // packetId occupies bytes 38..54 of the envelope.
      Uint8List sealed(String idHex, int length) {
        final p = Uint8List(length);
        p[0] = 0x03; // secure
        for (var i = 0; i < 16; i++) {
          p[38 + i] = int.parse(idHex.substring(i * 2, i * 2 + 2), radix: 16);
        }
        return p;
      }

      final dataId = 'aaaaaaaa' + '0' * 24;
      final ackId = 'bbbbbbbb' + '0' * 24;
      ledger.onTx(sealed(dataId, 300));
      ledger.onTx(sealed(ackId, 100));
      ledger.onRx(sealed(dataId, 300)); // rx is never split

      final record = ledger.drainRecord(transport: 'ble')!;
      expect(record['txBytes'], {'secure:data:say': 300, 'secure:ack': 100});
      expect(record['rxBytes'], {'secure': 300},
          reason: 'a peer on the air cannot tell sealed content apart');
    });

    test('drain resets: second drain with no traffic returns null', () {
      final ledger = WireLedger();
      ledger.onTx(packet(0x04, 50));
      expect(ledger.drainRecord(transport: 'ble'), isNotNull);
      expect(ledger.drainRecord(transport: 'ble'), isNull);
    });

    test('empty packets are ignored', () {
      final ledger = WireLedger();
      ledger.onRx(Uint8List(0));
      expect(ledger.drainRecord(transport: 'ble'), isNull);
    });
  });
}
