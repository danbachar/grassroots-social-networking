import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/store/settings_state.dart';
import 'package:grassroots_networking/src/testbed/testbed_config.dart';
import 'package:grassroots_networking/src/testbed/workload_driver.dart';

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _pubkey(int base) =>
    Uint8List.fromList(List.generate(32, (i) => (base + i) & 0xff));

WorkloadConfig _config({int seed = 42, double rate = 120}) => WorkloadConfig(
      seed: seed,
      startAtEpochMs: 1000000000000,
      endAtEpochMs: 1000000000000 + 60 * 60 * 1000, // +1h
      ratePerPairPerHour: rate,
      roster: [
        WorkloadRosterEntry(label: 'A', pubkeyHex: _hex(_pubkey(0))),
        WorkloadRosterEntry(label: 'B', pubkeyHex: _hex(_pubkey(100))),
        WorkloadRosterEntry(label: 'C', pubkeyHex: _hex(_pubkey(200))),
      ],
      payloadMix: const [
        WorkloadPayload(bytes: 184, weight: 0.8),
        WorkloadPayload(bytes: 1200, weight: 0.2),
      ],
    );

void main() {
  group('Mulberry32 / fnv1a32', () {
    test('mulberry32 is deterministic for a seed', () {
      final a = Mulberry32(12345);
      final b = Mulberry32(12345);
      for (var i = 0; i < 100; i++) {
        expect(a.nextDouble(), b.nextDouble());
      }
    });

    test('mulberry32 differs across seeds', () {
      final a = Mulberry32(1);
      final b = Mulberry32(2);
      expect(a.nextDouble(), isNot(equals(b.nextDouble())));
    });

    test('fnv1a32 is stable and case-sensitive', () {
      expect(fnv1a32('42|A|B'), fnv1a32('42|A|B'));
      expect(fnv1a32('42|A|B'), isNot(equals(fnv1a32('42|A|C'))));
      // Known FNV-1a 32-bit value for the empty string is the offset basis.
      expect(fnv1a32(''), 0x811c9dc5);
    });
  });

  group('WorkloadDriver.computeSchedule', () {
    test('is fully deterministic (times, ids, sizes)', () {
      final me = _hex(_pubkey(0));
      final s1 = WorkloadDriver.computeSchedule(config: _config(), myPubkeyHex: me);
      final s2 = WorkloadDriver.computeSchedule(config: _config(), myPubkeyHex: me);
      expect(s1.length, s2.length);
      expect(s1, isNotEmpty);
      for (var i = 0; i < s1.length; i++) {
        expect(s1[i].scheduledMs, s2[i].scheduledMs);
        expect(s1[i].messageId, s2[i].messageId);
        expect(s1[i].payloadBytes, s2[i].payloadBytes);
        expect(s1[i].dstLabel, s2[i].dstLabel);
      }
    });

    test('only produces sends where this device is the source', () {
      final me = _hex(_pubkey(0)); // label A
      final sched =
          WorkloadDriver.computeSchedule(config: _config(), myPubkeyHex: me);
      // A never sends to itself; destinations are only B and C.
      expect(sched.map((e) => e.dstLabel).toSet(), {'B', 'C'});
    });

    test('a device not in the roster produces nothing', () {
      final sched = WorkloadDriver.computeSchedule(
          config: _config(), myPubkeyHex: _hex(_pubkey(250)));
      expect(sched, isEmpty);
    });

    test('events are sorted by time and within the window', () {
      final me = _hex(_pubkey(0));
      final config = _config();
      final sched =
          WorkloadDriver.computeSchedule(config: config, myPubkeyHex: me);
      for (var i = 1; i < sched.length; i++) {
        expect(sched[i].scheduledMs, greaterThanOrEqualTo(sched[i - 1].scheduledMs));
      }
      for (final e in sched) {
        expect(e.scheduledMs, greaterThan(config.startAtEpochMs));
        expect(e.scheduledMs, lessThanOrEqualTo(config.endAtEpochMs));
      }
    });

    test('messageIds are the offline-reproducible UUIDv5 set', () {
      final me = _hex(_pubkey(0));
      final sched =
          WorkloadDriver.computeSchedule(config: _config(), myPubkeyHex: me);
      // Per (src,dst) the seq starts at 0 and increments; ids are unique.
      expect(sched.map((e) => e.messageId).toSet().length, sched.length);
      for (final e in sched) {
        expect(e.messageId, matches(RegExp(r'^[0-9a-f-]{36}$')));
      }
    });

    test('higher rate yields more scheduled sends', () {
      final me = _hex(_pubkey(0));
      final low = WorkloadDriver.computeSchedule(
          config: _config(rate: 10), myPubkeyHex: me);
      final high = WorkloadDriver.computeSchedule(
          config: _config(rate: 1000), myPubkeyHex: me);
      expect(high.length, greaterThan(low.length));
    });
  });

  group('NeighborAllowlist', () {
    test('allowsPubkey / allowsPubkeyHex match full keys only', () {
      final allowed = _pubkey(0);
      final other = _pubkey(1);
      final list = NeighborAllowlist(enabled: true, allow: [_hex(allowed)]);
      expect(list.allowsPubkey(allowed), isTrue);
      expect(list.allowsPubkey(other), isFalse);
      expect(list.allowsPubkeyHex(_hex(allowed).toUpperCase()), isTrue);
    });

    test('allowsServiceUuid derives the peer UUID from the allowed key', () {
      final allowed = _pubkey(0);
      final uuid = GrassrootsIdentity.deriveServiceUuidForSlot(allowed, 0);
      final list = NeighborAllowlist(enabled: true, allow: [_hex(allowed)]);
      expect(list.allowsServiceUuid(uuid), isTrue);
      // A UUID derived from a different key is not allowed.
      final otherUuid =
          GrassrootsIdentity.deriveServiceUuidForSlot(_pubkey(9), 0);
      expect(list.allowsServiceUuid(otherUuid), isFalse);
    });

    test('disabled default allows nothing but is inert (enabled=false)', () {
      const list = NeighborAllowlist.disabled;
      expect(list.enabled, isFalse);
      expect(list.allow, isEmpty);
    });

    test('round-trips through JSON', () {
      final list = NeighborAllowlist(
          enabled: true, allow: [_hex(_pubkey(0)), _hex(_pubkey(5))]);
      expect(NeighborAllowlist.fromJson(list.toJson()), list);
    });
  });

  group('Config JSON round-trips', () {
    test('WorkloadConfig round-trips', () {
      final c = _config();
      expect(WorkloadConfig.fromJson(c.toJson()), c);
    });

    test('SettingsState carries both testbed fields through JSON', () {
      final settings = const SettingsState().copyWith(
        neighborAllowlist:
            NeighborAllowlist(enabled: true, allow: ['aa', 'bb']),
        workloadConfig: _config(),
      );
      final restored = SettingsState.fromJson(settings.toJson());
      expect(restored.neighborAllowlist, settings.neighborAllowlist);
      expect(restored.workloadConfig, settings.workloadConfig);
    });

    test('SettingsState defaults leave testbed fields null (production)', () {
      const settings = SettingsState();
      expect(settings.neighborAllowlist, isNull);
      expect(settings.workloadConfig, isNull);
      final restored = SettingsState.fromJson(settings.toJson());
      expect(restored.neighborAllowlist, isNull);
      expect(restored.workloadConfig, isNull);
    });
  });
}
