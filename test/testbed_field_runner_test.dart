import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/testbed/field_runner.dart';
import 'package:grassroots_networking/src/testbed/testbed_config.dart';
import 'package:grassroots_networking/src/trace/experiment_recorder.dart';
import 'package:uuid/uuid.dart';

/// In-memory recorder: overrides the disk-backed methods the runner calls so
/// fakeAsync stays in full control of the virtual clock (real file I/O never
/// resolves under fakeAsync). Records the sequence of experiment events.
class _FakeRecorder extends ExperimentRecorder {
  final List<String> events = [];
  bool _active = false;
  @override
  bool get active => _active;

  @override
  Future<void> startExperiment(String id) async {
    _active = true;
    events.add('start:$id');
  }

  @override
  Future<void> stopExperiment() async {
    _active = false;
    events.add('stop');
  }

  @override
  Future<void> logMarker(String label) async => events.add('marker:$label');
}

void main() {
  FieldPlan plan() => const FieldPlan(
        expId: 'cp-line-1',
        settleSec: 5,
        steps: [
          FieldStep(label: 'd=40', dwellSec: 10),
          FieldStep(label: 'd=20', dwellSec: 10, bulk: true),
        ],
      );

  test('walks the whole plan: markers, dwell, bulk, settle, upload', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final bulkEvents = <String>[];
      var uploaded = false;
      final runner = FieldRunner(
        recorder: recorder,
        onStartBulk: () => bulkEvents.add('start'),
        onStopBulk: () => bulkEvents.add('stop'),
        upload: () async {
          uploaded = true;
          return 'ok';
        },
      );

      runner.start(plan());
      async.flushMicrotasks();
      expect(runner.phase, FieldPhase.positioning);
      expect(runner.currentStep!.label, 'd=40');
      expect(bulkEvents, isEmpty, reason: 'step 1 is not a bulk step');

      // Step 1: in position → dwell 10s → advances to step 2 positioning.
      runner.inPosition();
      async.flushMicrotasks();
      expect(runner.phase, FieldPhase.dwelling);
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(runner.phase, FieldPhase.positioning);
      expect(runner.currentStep!.label, 'd=20');

      // Step 2 (bulk): in position starts bulk; dwell end stops it, then settle.
      runner.inPosition();
      async.flushMicrotasks();
      expect(bulkEvents, ['start']);
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(bulkEvents, ['start', 'stop']);
      expect(runner.phase, FieldPhase.settling);

      // Settle 5s → stop + upload → finished.
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(runner.phase, FieldPhase.finished);
      expect(uploaded, isTrue);
      expect(recorder.active, isFalse);

      expect(recorder.events, [
        'start:cp-line-1',
        'marker:d=40',
        'marker:d=20',
        'marker:end',
        'stop',
      ]);
      runner.dispose();
    });
  });

  test('abort stamps an aborted marker and stops recording mid-dwell', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final runner = FieldRunner(recorder: recorder);
      runner.start(plan());
      async.flushMicrotasks();
      runner.inPosition(); // step 1 dwell
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 3)); // partway through the dwell

      runner.abort();
      async.flushMicrotasks();
      expect(runner.phase, FieldPhase.finished);
      expect(recorder.active, isFalse);
      expect(recorder.events, contains('marker:aborted'));
      expect(recorder.events.last, 'stop');
      runner.dispose();
    });
  });

  test('bulk flows stop on a mid-dwell abort of a bulk step', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final bulkEvents = <String>[];
      final runner = FieldRunner(
        recorder: recorder,
        onStartBulk: () => bulkEvents.add('start'),
        onStopBulk: () => bulkEvents.add('stop'),
      );
      runner.start(const FieldPlan(
          expId: 'e',
          settleSec: 5,
          steps: [FieldStep(label: 'b', dwellSec: 60, bulk: true)]));
      async.flushMicrotasks();
      runner.inPosition();
      async.flushMicrotasks();
      expect(bulkEvents, ['start']);
      async.elapse(const Duration(seconds: 5));
      runner.abort();
      async.flushMicrotasks();
      expect(bulkEvents, ['start', 'stop']);
      runner.dispose();
    });
  });

  test('no upload configured yields a share hint, not a crash', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final runner = FieldRunner(recorder: recorder); // upload: null
      runner.start(const FieldPlan(
          expId: 'cp-line-1',
          settleSec: 1,
          steps: [FieldStep(label: 'd=1', dwellSec: 1)]));
      async.flushMicrotasks();
      runner.inPosition();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2)); // dwell + settle
      async.flushMicrotasks();
      expect(runner.phase, FieldPhase.finished);
      expect(runner.uploadResult, contains('share'));
      runner.dispose();
    });
  });

  test('start is a no-op on an empty plan', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final runner = FieldRunner(recorder: recorder);
      runner.start(const FieldPlan(expId: 'e', steps: []));
      async.flushMicrotasks();
      expect(runner.isRunning, isFalse);
      expect(recorder.events, isEmpty);
      runner.dispose();
    });
  });

  test('FieldPlan round-trips through JSON', () {
    final p = plan();
    expect(FieldPlan.fromJson(p.toJson()), p);
  });

  // ===== Per-step sends + session reset =====

  String hexOf(int base) =>
      List.generate(32, (i) => ((base + i) & 0xff).toRadixString(16).padLeft(2, '0'))
          .join();

  FieldPlan sendPlan({bool resetSessions = true}) => FieldPlan(
        expId: 'cp',
        settleSec: 2,
        resetSessions: resetSessions,
        roster: [
          WorkloadRosterEntry(label: 'A', pubkeyHex: hexOf(0)),
          WorkloadRosterEntry(label: 'B', pubkeyHex: hexOf(100)),
        ],
        steps: const [
          FieldStep(label: 'd=40', dwellSec: 10, sendCount: 3, sendBytes: 32),
        ],
      );

  test('sends are spread through the dwell with deterministic ids', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final sent = <(String, String)>[]; // (messageId, dstHexPrefix)
      var resets = 0;
      final runner = FieldRunner(
        recorder: recorder,
        myPubkeyHex: hexOf(0),
        onResetSessions: () => resets++,
        send: (recipient, payload, {String? messageId}) async {
          expect(payload.length, 32);
          sent.add((messageId!, recipient[0].toRadixString(16).padLeft(2, '0')));
          return messageId;
        },
      );
      runner.start(sendPlan());
      async.flushMicrotasks();
      runner.inPosition();
      async.flushMicrotasks();

      expect(resets, 1, reason: 'sessions dropped at step start');
      expect(recorder.events,
          containsAllInOrder(['marker:sessions-reset', 'marker:d=40']));

      async.elapse(const Duration(seconds: 10));
      expect(sent, hasLength(3));
      expect(runner.sentCount, 3);
      const uuid = Uuid();
      for (var seq = 0; seq < 3; seq++) {
        expect(sent[seq].$1,
            uuid.v5(workloadUuidNamespace, 'field|cp|A|B|0|$seq'));
        expect(sent[seq].$2, '64'); // dst = roster B (base 100 = 0x64)
      }
      async.elapse(const Duration(seconds: 5)); // settle
      runner.dispose();
    });
  });

  test('resetSessions=false skips the reset and its marker', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      var resets = 0;
      final runner = FieldRunner(
        recorder: recorder,
        myPubkeyHex: hexOf(0),
        onResetSessions: () => resets++,
        send: (r, p, {String? messageId}) async => messageId,
      );
      runner.start(sendPlan(resetSessions: false));
      async.flushMicrotasks();
      runner.inPosition();
      async.flushMicrotasks();
      expect(resets, 0);
      expect(recorder.events.where((e) => e == 'marker:sessions-reset'),
          isEmpty);
      async.elapse(const Duration(seconds: 20));
      runner.dispose();
    });
  });

  test('abort cancels pending sends', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final sent = <String>[];
      final runner = FieldRunner(
        recorder: recorder,
        myPubkeyHex: hexOf(0),
        send: (r, p, {String? messageId}) async {
          sent.add(messageId!);
          return messageId;
        },
      );
      runner.start(sendPlan());
      async.flushMicrotasks();
      runner.inPosition();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2)); // only the 1s send fired
      expect(sent, hasLength(1));
      runner.abort();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 20));
      expect(sent, hasLength(1), reason: 'no sends after abort');
      runner.dispose();
    });
  });

  test('a device not in the roster sends nothing (static receiver)', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      var sends = 0;
      final runner = FieldRunner(
        recorder: recorder,
        myPubkeyHex: hexOf(200), // not in roster
        send: (r, p, {String? messageId}) async {
          sends++;
          return messageId;
        },
      );
      runner.start(sendPlan());
      async.flushMicrotasks();
      runner.inPosition();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 20));
      expect(sends, 0);
      runner.dispose();
    });
  });

  test('linkSettled gates sends: nothing until settled, then spread', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final sent = <String>[];
      var settled = false;
      final runner = FieldRunner(
        recorder: recorder,
        myPubkeyHex: hexOf(0),
        linkSettled: (_) => settled,
        send: (r, p, {String? messageId}) async {
          sent.add(messageId!);
          return messageId;
        },
      );
      runner.start(sendPlan()); // dwell 10s, 3 sends
      async.flushMicrotasks();
      runner.inPosition();
      async.flushMicrotasks();

      // Link not settled: no sends, no matter how long into the dwell.
      async.elapse(const Duration(seconds: 4));
      expect(sent, isEmpty, reason: 'must not race a re-forming link');

      settled = true; // pair converges mid-dwell
      async.elapse(const Duration(seconds: 6)); // rest of the dwell
      expect(sent, hasLength(3),
          reason: 'all sends spread across the remaining dwell');
      expect(recorder.events, contains('marker:link-settled'));
      async.elapse(const Duration(seconds: 5));
      runner.dispose();
    });
  });

  test('linkSettled never true: the step sends nothing (out of range)', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      var sends = 0;
      final runner = FieldRunner(
        recorder: recorder,
        myPubkeyHex: hexOf(0),
        linkSettled: (_) => false,
        send: (r, p, {String? messageId}) async {
          sends++;
          return messageId;
        },
      );
      runner.start(sendPlan());
      async.flushMicrotasks();
      runner.inPosition();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 20)); // dwell + settle
      expect(sends, 0);
      expect(recorder.events.where((e) => e == 'marker:link-settled'), isEmpty);
      runner.dispose();
    });
  });

  test('rosterless plan targets every known peer with hex-prefix labels', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final sent = <String>[];
      final peer = Uint8List.fromList(
          List.generate(32, (i) => (100 + i) & 0xff));
      final runner = FieldRunner(
        recorder: recorder,
        myPubkeyHex: hexOf(0),
        knownPeers: () => [peer],
        send: (recipient, payload, {String? messageId}) async {
          expect(recipient, peer);
          sent.add(messageId!);
          return messageId;
        },
      );
      runner.start(const FieldPlan(
        expId: 'cp',
        settleSec: 2,
        steps: const [
          FieldStep(label: 'd=3', dwellSec: 10, sendCount: 2, sendBytes: 32),
        ],
      ));
      async.flushMicrotasks();
      runner.inPosition();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 10));

      expect(sent, hasLength(2));
      const uuid = Uuid();
      final src = hexOf(0).substring(0, 8);
      final dst = hexOf(100).substring(0, 8);
      for (var seq = 0; seq < 2; seq++) {
        expect(sent[seq],
            uuid.v5(workloadUuidNamespace, 'field|cp|$src|$dst|0|$seq'));
      }
      async.elapse(const Duration(seconds: 5));
      runner.dispose();
    });
  });

  test('rosterless plan with no known peers sends nothing', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      var sends = 0;
      final runner = FieldRunner(
        recorder: recorder,
        myPubkeyHex: hexOf(0),
        knownPeers: () => const [],
        send: (r, p, {String? messageId}) async {
          sends++;
          return messageId;
        },
      );
      runner.start(const FieldPlan(
        expId: 'cp',
        settleSec: 2,
        steps: const [FieldStep(label: 'd=3', dwellSec: 5, sendCount: 2)],
      ));
      async.flushMicrotasks();
      runner.inPosition();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 10));
      expect(sends, 0);
      runner.dispose();
    });
  });

  test('resetLinks tears down links before sessions at each step', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final order = <String>[];
      final runner = FieldRunner(
        recorder: recorder,
        myPubkeyHex: hexOf(0),
        onResetLinks: () async => order.add('links'),
        onResetSessions: () => order.add('sessions'),
      );
      runner.start(const FieldPlan(
        expId: 'e',
        settleSec: 1,
        resetLinks: true,
        steps: const [
          FieldStep(label: 's1', dwellSec: 2),
          FieldStep(label: 's2', dwellSec: 2),
        ],
      ));
      async.flushMicrotasks();
      runner.inPosition();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      runner.inPosition();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));

      expect(order, ['links', 'sessions', 'links', 'sessions'],
          reason: 'links torn down before sessions, once per step');
      final markers =
          recorder.events.where((e) => e.startsWith('marker:')).toList();
      expect(
          markers,
          containsAllInOrder([
            'marker:links-reset',
            'marker:sessions-reset',
            'marker:s1',
            'marker:links-reset',
            'marker:sessions-reset',
            'marker:s2',
          ]));
      runner.dispose();
    });
  });

  test('resetLinks defaults off: callback never fires', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      var links = 0;
      final runner = FieldRunner(
        recorder: recorder,
        onResetLinks: () async => links++,
      );
      runner.start(plan());
      async.flushMicrotasks();
      runner.inPosition();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      expect(links, 0);
      runner.dispose();
    });
  });

  test('a per-step autoAdvance step fires on its own; a plain step waits', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final runner = FieldRunner(recorder: recorder);
      runner.start(const FieldPlan(
        expId: 'auto',
        settleSec: 1,
        autoAdvanceGapSec: 3,
        steps: [
          FieldStep(label: 's1', dwellSec: 5), // new position → waits for tap
          FieldStep(label: 's2', dwellSec: 5, autoAdvance: true), // same → auto
        ],
      ));
      async.flushMicrotasks();
      // Step 1 does NOT auto-advance — it waits.
      expect(runner.phase, FieldPhase.positioning);
      async.elapse(const Duration(seconds: 10));
      expect(runner.phase, FieldPhase.positioning, reason: 'still waiting');
      runner.inPosition(); // tap
      async.flushMicrotasks();
      expect(runner.phase, FieldPhase.dwelling);
      async.elapse(const Duration(seconds: 5)); // dwell → step 2 positioning
      // Step 2 auto-advances after the gap, no tap.
      expect(runner.phase, FieldPhase.positioning);
      async.elapse(const Duration(seconds: 3)); // gap → step 2 begins
      expect(runner.phase, FieldPhase.dwelling);
      expect(runner.currentStep!.label, 's2');
      async.elapse(const Duration(seconds: 5)); // dwell → settle
      async.elapse(const Duration(seconds: 1)); // settle → finished
      expect(runner.phase, FieldPhase.finished);
      expect(recorder.events,
          ['start:auto', 'marker:s1', 'marker:s2', 'marker:end', 'stop']);
      runner.dispose();
    });
  });

  test('a manual tap pre-empts an auto-advance gap', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final runner = FieldRunner(recorder: recorder);
      runner.start(const FieldPlan(
        expId: 'auto',
        settleSec: 1,
        autoAdvanceGapSec: 30, // long gap
        steps: [FieldStep(label: 's1', dwellSec: 5, autoAdvance: true)],
      ));
      async.flushMicrotasks();
      runner.inPosition(); // skip the 30s gap
      async.flushMicrotasks();
      expect(runner.phase, FieldPhase.dwelling);
      async.elapse(const Duration(seconds: 6)); // dwell + settle
      expect(runner.phase, FieldPhase.finished);
      runner.dispose();
    });
  });

  test('FieldPlan with roster/sends/resetSessions round-trips', () {
    final p = sendPlan();
    final restored = FieldPlan.fromJson(p.toJson());
    expect(restored, p);
    expect(restored.steps.single.sendCount, 3);
    expect(restored.steps.single.sendBytes, 32);
    expect(restored.resetSessions, isTrue);
  });
}
