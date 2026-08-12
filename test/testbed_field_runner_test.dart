import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/testbed/field_plan_presets.dart';
import 'package:grassroots_networking/src/testbed/field_runner.dart';
import 'package:grassroots_networking/src/testbed/testbed_config.dart';
import 'package:grassroots_networking/src/trace/experiment_recorder.dart';

/// In-memory recorder: overrides the disk-backed methods the runner calls so
/// fakeAsync stays in full control of the virtual clock (real file I/O never
/// resolves under fakeAsync). Records the sequence of experiment events.
class _FakeRecorder extends ExperimentRecorder {
  final List<String> events = [];
  final List<String> archived = [];
  bool _active = false;
  @override
  bool get active => _active;

  String? _expId;
  @override
  String? get experimentId => _expId;

  @override
  Future<void> startExperiment(String id) async {
    _active = true;
    _expId = id;
    events.add('start:$id');
  }

  @override
  Future<void> stopExperiment() async {
    _active = false;
    _expId = null;
    events.add('stop');
  }

  @override
  Future<String?> archiveAbortedExperiment(String id) async {
    archived.add(id);
    return 'exp_$id-aborted-1.jsonl';
  }

  /// Label and extras are recorded separately: `events` stays the plain
  /// label stream every other assertion reads, `markerExtras` keeps the
  /// per-step configuration stamped alongside it.
  final List<(String, Map<String, Object?>)> markerExtras = [];

  @override
  Future<void> logMarker(String label, {Map<String, Object?>? extra}) async {
    events.add('marker:$label');
    markerExtras.add((label, extra ?? const {}));
  }

  @override
  Future<void> log(Map<String, dynamic> record) async =>
      events.add('log:${record['type']}:${record['event']}');
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
      // Ids are v4, like production: unique, and never repeated across runs.
      // They used to be derived from the step and seq, which made two runs of
      // one plan mint identical ids — the receiver's bloom then dropped the
      // second run's messages as duplicates.
      expect(sent.map((e) => e.$1).toSet(), hasLength(3));
      for (var seq = 0; seq < 3; seq++) {
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

  test('saturate: no ACK gating — one lane is clocked by the send alone', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final sent = <String>[];
      final runner = FieldRunner(
        recorder: recorder,
        myPubkeyHex: hexOf(0),
        knownPeers: () => [Uint8List.fromList(List.generate(32, (i) => 100 + i))],
        // A send that takes 10ms of transport time — the loop's only clock.
        send: (r, p, {String? messageId}) async {
          sent.add(messageId!);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return messageId;
        },
      );
      runner.start(const FieldPlan(
        expId: 'tp',
        settleSec: 1,
        resetSessions: false,
        steps: [
          FieldStep(label: 'saturate', dwellSec: 10, saturate: true),
        ],
      ));
      async.flushMicrotasks();
      runner.inPosition();
      async.elapse(const Duration(seconds: 1));

      // Not one-shot and not window-sized: it keeps going without any ACK.
      expect(sent.length, greaterThan(20),
          reason: 'a 10ms send over 1s should fire ~90 messages, ACK or not');
      expect(runner.ackedCount, 0, reason: 'nothing was ACKed, yet it sent');
      expect(sent.toSet().length, sent.length, reason: 'never re-sends an id');
      final atOneSec = sent.length;

      // It keeps pushing for the WHOLE dwell: a 10s dwell at 10ms per send is
      // ~1000 messages, none of them ACK-gated.
      async.elapse(const Duration(seconds: 11)); // past dwell (10s) + settle
      expect(sent.length, greaterThan(atOneSec));
      expect(sent.length, greaterThan(900));
      final atEnd = sent.length;

      // …and then stops with the step rather than running on.
      async.elapse(const Duration(seconds: 5));
      expect(sent.length, atEnd,
          reason: 'the push loop must end with the step');
      runner.dispose();
    });
  });

  // REAL timers on purpose: the starvation this guards against is a
  // microtask chain outrunning the event loop, and fakeAsync cannot model it
  // (a zero-duration timer there re-fires forever at the same fake instant).
  test('saturate unlimited: a send with no targets cannot starve the loop',
      () async {
    final recorder = _FakeRecorder();
    var sends = 0;
    final runner = FieldRunner(
      recorder: recorder,
      myPubkeyHex: hexOf(0),
      knownPeers: () => const [], // nobody to send to: _fireSaturating no-ops
      send: (r, p, {String? messageId}) async {
        sends++;
        return messageId;
      },
    );
    await runner.start(const FieldPlan(
      expId: 'tp',
      settleSec: 1,
      resetSessions: false,
      steps: [
        FieldStep(label: 'saturate', dwellSec: 1, saturate: true),
      ],
    ));
    await runner.inPosition();
    expect(runner.phase, FieldPhase.dwelling);
    // Without the event-loop yield in _pushUnlimited the dwell timer would
    // never get a turn and this would still be dwelling (or hung) at 2s.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(sends, 0);
    expect(runner.phase, isNot(FieldPhase.dwelling),
        reason: 'the dwell timer fired, so the push loop yielded to it');
    runner.dispose();
  });

  test('saturate: N lanes push concurrently and an ACK never fires a send',
      () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final sent = <String>[];
      final runner = FieldRunner(
        recorder: recorder,
        myPubkeyHex: hexOf(0),
        knownPeers: () => [Uint8List.fromList(List.generate(32, (i) => 100 + i))],
        // 10ms of transport time per send: each lane advances at 100/s.
        send: (r, p, {String? messageId}) async {
          sent.add(messageId!);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return messageId;
        },
      );
      runner.start(const FieldPlan(
        expId: 'tp',
        settleSec: 1,
        resetSessions: false,
        steps: [
          FieldStep(
              label: 'saturate', dwellSec: 10, saturate: true, sendLanes: 3),
        ],
      ));
      async.flushMicrotasks();
      runner.inPosition();
      async.flushMicrotasks();

      // All lanes open at once — that IS the offered load.
      expect(sent, hasLength(3));
      expect(recorder.events, contains('marker:saturate-start'));

      // Three lanes at 10ms each carry ~3x what one lane would: the whole
      // point of the knob. (One lane over 1s was ~90 in the test above.)
      async.elapse(const Duration(seconds: 1));
      expect(sent.length, greaterThan(200));
      final before = sent.length;

      // An ACK only counts. It must not clock a send, or the rate would be
      // capped at lanes/RTT instead of by the link.
      runner.onAck(sent[0]);
      runner.onAck(sent[1]);
      expect(runner.ackedCount, 2);
      expect(sent.length, before, reason: 'an ACK fired no send');

      // Unknown/duplicate ACKs are ignored.
      runner.onAck('nope');
      runner.onAck(sent[0]);
      expect(runner.ackedCount, 2);

      // Dwell end stops every lane.
      async.elapse(const Duration(seconds: 11));
      final atEnd = sent.length;
      async.elapse(const Duration(seconds: 5));
      expect(sent.length, atEnd, reason: 'all lanes ended with the step');
      runner.dispose();
    });
  });

  test('a scheduled send goes to every peer: the rate is per destination', () {
    // 10 sends over the dwell with six peers up is 60 messages, with one peer
    // it is 10. The count is what each destination receives, and it must not
    // be quietly divided by how many peers happen to be identified.
    int sentWith(int peerCount) {
      var n = 0;
      fakeAsync((async) {
        final peers = [
          for (var i = 0; i < peerCount; i++)
            Uint8List.fromList(List.generate(32, (j) => (i * 7 + j) & 0xff)),
        ];
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          myPubkeyHex: hexOf(0),
          knownPeers: () => peers,
          send: (r, p, {String? messageId}) async {
            n++;
            return messageId;
          },
        );
        runner.start(const FieldPlan(
          expId: 'rate',
          settleSec: 1,
          resetSessions: false,
          steps: [FieldStep(label: 'r', dwellSec: 10, sendCount: 10)],
        ));
        async.flushMicrotasks();
        runner.inPosition();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 12));
        runner.dispose();
        async.flushTimers();
      });
      return n;
    }

    expect(sentWith(1), 10);
    expect(sentWith(6), 60, reason: '10 per destination, six destinations');
  });

  test('sendTo addresses one peer by prefix; a miss sends nothing', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final peerA = Uint8List.fromList(List.generate(32, (i) => 100 + i % 50));
      final peerB = Uint8List.fromList(List.generate(32, (i) => 200 + i % 50));
      final sentTo = <String>[];
      FieldRunner build(String sendTo) => FieldRunner(
            recorder: recorder,
            myPubkeyHex: hexOf(0),
            knownPeers: () => [peerA, peerB],
            send: (r, p, {String? messageId}) async {
              sentTo.add(r.map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .join()
                  .substring(0, 8));
              return messageId;
            },
          );

      // Address peerB alone.
      final wantHex =
          peerB.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final runner = build(wantHex.substring(0, 8));
      runner.start(FieldPlan(
        expId: 'hop',
        settleSec: 1,
        resetSessions: false,
        steps: [
          FieldStep(
              label: 'hop',
              dwellSec: 10,
              sendCount: 2,
              sendTo: wantHex.substring(0, 8)),
        ],
      ));
      async.flushMicrotasks();
      runner.inPosition();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 10));
      expect(sentTo, hasLength(2));
      expect(sentTo.toSet(), {wantHex.substring(0, 8)},
          reason: 'only the addressed peer, never a silent broadcast');
      async.elapse(const Duration(seconds: 3));
      runner.dispose();

      // An unmatched prefix sends nothing at all.
      sentTo.clear();
      final miss = build('deadbeef');
      miss.start(const FieldPlan(
        expId: 'hop',
        settleSec: 1,
        resetSessions: false,
        steps: [
          FieldStep(
              label: 'hop', dwellSec: 5, sendCount: 3, sendTo: 'deadbeef'),
        ],
      ));
      async.flushMicrotasks();
      miss.inPosition();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 10));
      expect(sentTo, isEmpty);
      miss.dispose();
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
      expect(sent.toSet(), hasLength(2), reason: 'v4 ids never repeat');
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

  test('raw mode pushes blobs for the dwell; a dead leg cannot spin', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final sent = <(String, int)>[];
      var legUp = true;
      final runner = FieldRunner(
        recorder: recorder,
        myPubkeyHex: hexOf(0),
        knownPeers: () => [Uint8List.fromList(List.generate(32, (i) => 100 + i))],
        sendRaw: (peer, {required leg, required seq, sizeDelta = 0}) async {
          if (!legUp) return null;
          sent.add((leg, seq));
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return 182;
        },
      );
      runner.start(const FieldPlan(
        expId: 'raw',
        settleSec: 1,
        resetSessions: false,
        resetDtnBuffer: false,
        steps: [
          FieldStep(label: 'leg=notify', dwellSec: 5, rawLeg: 'notify'),
        ],
      ));
      async.flushMicrotasks();
      runner.inPosition();
      async.elapse(const Duration(seconds: 2));
      expect(sent.length, greaterThan(100),
          reason: '5ms per blob -> ~200 blobs in the first second alone');
      expect(sent.every((e) => e.$1 == 'notify'), isTrue);
      expect(recorder.events, contains('marker:raw-start'));

      // Leg drops mid-dwell: the loop must idle (200ms backoff), not spin.
      legUp = false;
      final atDrop = sent.length;
      async.elapse(const Duration(seconds: 2));
      expect(sent.length, atDrop);
      expect(runner.phase, FieldPhase.dwelling,
          reason: 'the dwell countdown kept running through the dead leg');

      // Dwell ends and stops the loop; the flow record carries the counts.
      async.elapse(const Duration(seconds: 10));
      expect(runner.phase, isNot(FieldPhase.dwelling));
      runner.dispose();
    });
  });

  test('bleOn steps toggle the transport in schedule order', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final toggles = <bool>[];
      final runner = FieldRunner(
        recorder: recorder,
        onSetBle: (on) async => toggles.add(on),
      );
      runner.start(const FieldPlan(
        expId: 'pw',
        settleSec: 1,
        resetSessions: false,
        resetDtnBuffer: false,
        steps: [
          FieldStep(label: 'base', dwellSec: 1, bleOn: false),
          FieldStep(label: 'solo', dwellSec: 1, bleOn: true, autoAdvance: true),
          FieldStep(label: 'off2', dwellSec: 1, bleOn: false, autoAdvance: true),
          FieldStep(label: 'plain', dwellSec: 1, autoAdvance: true),
        ],
      ));
      async.flushMicrotasks();
      runner.inPosition();
      async.elapse(const Duration(seconds: 60));
      expect(toggles, [false, true, false],
          reason: 'a step without bleOn leaves the transport alone');
      runner.dispose();
    });
  });

  test('resetDtnBuffer empties the store at each step start', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      var clears = 0;
      final runner = FieldRunner(
        recorder: recorder,
        onResetDtnBuffer: () => clears++,
      );
      runner.start(const FieldPlan(
        expId: 'cc',
        settleSec: 1,
        resetSessions: false,
        steps: [
          FieldStep(label: 's1', dwellSec: 1),
          FieldStep(label: 's2', dwellSec: 1, autoAdvance: true),
        ],
      ));
      async.flushMicrotasks();
      runner.inPosition();
      async.elapse(const Duration(seconds: 30));
      expect(clears, 2, reason: 'once per step');
      expect(recorder.events.where((e) => e == 'marker:custody-reset'),
          hasLength(2));
      runner.dispose();
    });
  });

  test('resetDtnBuffer false never fires the hook', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      var clears = 0;
      final runner = FieldRunner(
        recorder: recorder,
        onResetDtnBuffer: () => clears++,
      );
      runner.start(const FieldPlan(
        expId: 'cc',
        settleSec: 1,
        resetSessions: false,
        resetDtnBuffer: false,
        steps: [FieldStep(label: 's1', dwellSec: 1)],
      ));
      async.flushMicrotasks();
      runner.inPosition();
      async.elapse(const Duration(seconds: 20));
      expect(clears, 0);
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

  group('dead-radio watchdog', () {
    /// A plan whose one step asks for the radio and dwells long enough for
    /// the watchdog to fire inside it.
    FieldPlan blePlan({int dwellSec = 120}) => FieldPlan(
          expId: 'pw-base-1',
          settleSec: 5,
          steps: [FieldStep(label: 'linked', dwellSec: dwellSec, bleOn: true)],
        );

    test('a radio that is up but ALONE is not an abort', () {
      // The power ladder's solo steps bring one phone's radio up while the
      // peer's is deliberately off. No peer means no GATT path, and the wire
      // ledger only counts at the GATT choke points — so a perfectly healthy
      // lone radio moves zero bytes. Requiring bytes here would abort every
      // solo segment of a good run.
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          onSetBle: (_) async {},
          bleWireBytes: () => 0,
          bleUsable: () => true,
          knownPeers: () => const <Uint8List>[], // alone on purpose
          bleWatchdogSec: 30,
          upload: () async => 'ok',
        );

        runner.start(blePlan());
        async.flushMicrotasks();
        runner.inPosition();
        async.elapse(const Duration(seconds: 45));
        async.flushMicrotasks();

        expect(runner.abortReason, isNull);
        expect(runner.isRunning, isTrue);
      });
    });

    test('aborts when the transport is not usable, peer or not', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          onSetBle: (_) async {},
          bleWireBytes: () => 0,
          bleUsable: () => false, // bring-up silently failed
          knownPeers: () => const <Uint8List>[],
          bleWatchdogSec: 30,
          upload: () async => 'ok',
        );

        runner.start(blePlan());
        async.flushMicrotasks();
        runner.inPosition();
        async.elapse(const Duration(seconds: 45));
        async.flushMicrotasks();

        expect(runner.abortReason, contains('not usable'));
        expect(runner.isRunning, isFalse);
        expect(recorder.events, contains('log:runner:bleDead'));
      });
    });

    test('aborts when a peer is in range but nothing moves', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        var alerts = 0;
        final runner = FieldRunner(
          recorder: recorder,
          onSetBle: (_) async {},
          bleWireBytes: () => 0, // silent despite a peer being right there
          bleUsable: () => true,
          knownPeers: () => [Uint8List(32)],
          bleWatchdogSec: 30,
          onWindowElapsed: () => alerts++,
          upload: () async => 'ok',
        );

        runner.start(blePlan());
        async.flushMicrotasks();
        runner.inPosition();
        async.flushMicrotasks();
        expect(runner.phase, FieldPhase.dwelling);
        expect(runner.abortReason, isNull, reason: 'watchdog has not fired yet');

        async.elapse(const Duration(seconds: 29));
        async.flushMicrotasks();
        expect(runner.abortReason, isNull, reason: 'still inside the window');

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        expect(runner.abortReason, contains('BLE dead'));
        expect(runner.abortReason, contains('linked'));
        expect(runner.abortReason, contains('0 bytes moved'));
        expect(runner.isRunning, isFalse);
        expect(runner.phase, FieldPhase.finished);
        expect(recorder.events, contains('log:runner:bleDead'));
        expect(recorder.events, contains('marker:aborted'));
        expect(recorder.events, contains('stop'));
        expect(alerts, greaterThan(0),
            reason: 'the abort must be audible/haptic, not screen-only');
      });
    });

    test('stays quiet when the radio is alive', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        var bytes = 0;
        final runner = FieldRunner(
          recorder: recorder,
          onSetBle: (_) async {},
          bleWireBytes: () => bytes,
          bleUsable: () => true,
          knownPeers: () => [Uint8List(32)],
          bleWatchdogSec: 30,
          upload: () async => 'ok',
        );

        runner.start(blePlan());
        async.flushMicrotasks();
        runner.inPosition();
        async.flushMicrotasks();

        // One ANNOUNCE goes out inside the window.
        async.elapse(const Duration(seconds: 10));
        bytes = 342;
        async.elapse(const Duration(seconds: 25));
        async.flushMicrotasks();

        expect(runner.abortReason, isNull);
        expect(runner.isRunning, isTrue);
        expect(runner.phase, FieldPhase.dwelling);
      });
    });

    test('a bleOn:false step is never watched', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          onSetBle: (_) async {},
          bleWireBytes: () => 0,
          bleUsable: () => false,
          knownPeers: () => [Uint8List(32)],
          bleWatchdogSec: 30,
          upload: () async => 'ok',
        );

        runner.start(const FieldPlan(
          expId: 'pw-base-1',
          settleSec: 5,
          steps: [FieldStep(label: 'base', dwellSec: 120, bleOn: false)],
        ));
        async.flushMicrotasks();
        runner.inPosition();
        async.elapse(const Duration(seconds: 40));
        async.flushMicrotasks();

        expect(runner.abortReason, isNull,
            reason: 'zero bytes is the POINT of a radio-down segment');
        expect(runner.isRunning, isTrue);
      });
    });

    test('a step shorter than the watchdog is not watched', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          onSetBle: (_) async {},
          bleWireBytes: () => 0,
          bleUsable: () => false,
          knownPeers: () => [Uint8List(32)],
          bleWatchdogSec: 30,
          upload: () async => 'ok',
        );

        // 20s dwell: the step is over before the watchdog would fire, so
        // arming it would abort during the NEXT step instead.
        runner.start(blePlan(dwellSec: 20));
        async.flushMicrotasks();
        runner.inPosition();
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        expect(runner.abortReason, isNull);
      });
    });
  });

  group('remote start', () {
    FieldPlan plan({String id = 'mesh-scale-1', int? order}) => FieldPlan(
          expId: id,
          settleSec: 5,
          deviceOrder: order,
          steps: const [FieldStep(label: 'n=3', dwellSec: 60, bleOn: false)],
        );

    test('arming brings the radio UP so the signal can be heard', () {
      // A late joiner's first step turns BLE off, but it must be ON to hear
      // the start at all — a previous run that ended dark would otherwise
      // leave the phone permanently deaf, sitting armed while the rest ran.
      fakeAsync((async) {
        final ble = <bool>[];
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          onSetBle: (on) async => ble.add(on),
        );
        runner.armForRemoteStart(plan());
        async.flushMicrotasks();

        expect(ble, [true]);
        expect(runner.armedPlan?.expId, 'mesh-scale-1');
        expect(runner.isRunning, isFalse, reason: 'armed is not running');
      });
    });

    test('a matching signal starts the run and passes the first step', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final ble = <bool>[];
        final runner = FieldRunner(
          recorder: recorder,
          onSetBle: (on) async => ble.add(on),
          upload: () async => 'ok',
        );
        runner.armForRemoteStart(plan());
        async.flushMicrotasks();

        unawaited(runner.remoteStart('mesh-scale-1'));
        async.flushMicrotasks();

        expect(runner.isRunning, isTrue);
        expect(runner.phase, FieldPhase.dwelling,
            reason: 'no tap is coming — the signal IS the tap');
        expect(runner.remotelyStarted, isTrue);
        expect(runner.armedPlan, isNull, reason: 'consumed');
        // Armed brought the radio up; the first step then took it down,
        // which is how a late joiner listens, hears, and goes dark.
        expect(ble, [true, false]);
        expect(recorder.events, contains('marker:n=3'));
      });
    });

    test('the step marker stamps this phone\'s join order and intent', () {
      // Without these, a phone configured for the wrong slot looks exactly
      // like one configured right that failed to join: both just have no
      // links. `order` says which slot it was told to fill, `joined` says
      // whether it believed it belonged in the mesh for this step.
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          onSetBle: (on) async {},
          upload: () async => 'ok',
        );
        runner.armForRemoteStart(plan(order: 4));
        async.flushMicrotasks();
        unawaited(runner.remoteStart('mesh-scale-1'));
        async.flushMicrotasks();

        final extra =
            recorder.markerExtras.firstWhere((e) => e.$1 == 'n=3').$2;
        expect(extra['order'], 4);
        expect(extra['joined'], isFalse);
      });
    });

    test('a plan with no join order stamps no order field', () {
      // Distance/power plans have no notion of order; the marker must not
      // invent one.
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          onSetBle: (on) async {},
          upload: () async => 'ok',
        );
        runner.armForRemoteStart(plan());
        async.flushMicrotasks();
        unawaited(runner.remoteStart('mesh-scale-1'));
        async.flushMicrotasks();

        final extra =
            recorder.markerExtras.firstWhere((e) => e.$1 == 'n=3').$2;
        expect(extra.containsKey('order'), isFalse);
        expect(extra['joined'], isFalse);
      });
    });

    test('a signal for a DIFFERENT experiment is ignored', () {
      fakeAsync((async) {
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          onSetBle: (_) async {},
        );
        runner.armForRemoteStart(plan(id: 'mesh-scale-1'));
        async.flushMicrotasks();

        unawaited(runner.remoteStart('some-other-run'));
        async.flushMicrotasks();

        expect(runner.isRunning, isFalse);
        expect(runner.armedPlan, isNotNull,
            reason: 'still waiting for its own signal');
      });
    });

    test('an unarmed runner ignores the signal entirely', () {
      fakeAsync((async) {
        final runner = FieldRunner(recorder: _FakeRecorder());
        unawaited(runner.remoteStart('mesh-scale-1'));
        async.flushMicrotasks();
        expect(runner.isRunning, isFalse);
      });
    });

    test('disarm releases it', () {
      fakeAsync((async) {
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          onSetBle: (_) async {},
        );
        runner.armForRemoteStart(plan());
        async.flushMicrotasks();
        runner.disarm();
        expect(runner.armedPlan, isNull);

        unawaited(runner.remoteStart('mesh-scale-1'));
        async.flushMicrotasks();
        expect(runner.isRunning, isFalse);
      });
    });
  });

  group('force finish', () {
    test('ends the run without waiting, and keeps the files', () {
      // A phone showing SETTLING 00:00 mid-upload is indistinguishable from
      // a wedged one; on a field day the whole group waits on it.
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          // An upload that never returns — exactly the case being escaped.
          upload: () => Completer<String>().future,
        );
        runner.start(const FieldPlan(
          expId: 'x',
          settleSec: 2,
          steps: [FieldStep(label: 's', dwellSec: 1)],
        ));
        async.flushMicrotasks();
        runner.inPosition();
        async.elapse(const Duration(seconds: 5)); // through dwell + settle
        async.flushMicrotasks();

        expect(runner.finishing, isTrue, reason: 'stuck in the upload');
        expect(runner.phase, isNot(FieldPhase.finished));

        unawaited(runner.forceFinish());
        async.flushMicrotasks();

        expect(runner.phase, FieldPhase.finished);
        expect(runner.isRunning, isFalse);
        expect(runner.finishing, isFalse);
        // The recording was stopped, so the buffer reached disk — only the
        // WAIT was abandoned, never the data.
        expect(recorder.events, contains('stop'));
        expect(runner.uploadResult, contains('files kept on device'));
      });
    });

    test('is a no-op once the run has already finished', () {
      fakeAsync((async) {
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          upload: () async => 'ok',
        );
        runner.start(const FieldPlan(
          expId: 'x',
          settleSec: 1,
          steps: [FieldStep(label: 's', dwellSec: 1)],
        ));
        async.flushMicrotasks();
        runner.inPosition();
        async.elapse(const Duration(seconds: 4));
        async.flushMicrotasks();
        expect(runner.phase, FieldPhase.finished);
        expect(runner.uploadResult, 'ok');

        unawaited(runner.forceFinish());
        async.flushMicrotasks();
        expect(runner.uploadResult, 'ok', reason: 'not overwritten');
      });
    });
  });

  group('placement location fix', () {
    FieldPlan geoPlan() => const FieldPlan(
          expId: 'mesh-scale-1',
          settleSec: 1,
          deviceOrder: 2,
          steps: [
            FieldStep(label: 'distribute', dwellSec: 10, bleOn: false),
            FieldStep(label: 'n=3 t1', dwellSec: 10, bleOn: true,
                autoAdvance: true),
            FieldStep(label: 'n=3 t2', dwellSec: 10, bleOn: true,
                autoAdvance: true),
          ],
        );

    test('one fix at placement, not on the walk-out and not per step', () {
      // The walk-out step is when the phone is still being carried, and an
      // auto-advanced step means it has not moved. A fix on either would be
      // a wrong position or a needless radio wake.
      fakeAsync((async) {
        var calls = 0;
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          onSetBle: (on) async {},
          upload: () async => 'ok',
          onSampleLocation: () async {
            calls++;
            return {'lat': 48.265, 'lon': 11.671, 'accM': 4.0};
          },
        );
        runner.start(geoPlan());
        async.flushMicrotasks();

        runner.inPosition();          // operator taps to begin the walk-out
        async.flushMicrotasks();
        expect(calls, 0, reason: 'the phone is still being carried');

        // dwell 10s then a 5s auto-advance gap: n=3 t1 opens at t=15s.
        async.elapse(const Duration(seconds: 16));
        async.flushMicrotasks();
        expect(calls, 1, reason: 'first measured step: it is now placed');
        expect(runner.locationFixes, 1);

        async.elapse(const Duration(seconds: 15));  // auto-advance into n=3 t2
        async.flushMicrotasks();
        expect(calls, 1, reason: 'a timer firing is not a placement');

        expect(
            recorder.events.where((e) => e.startsWith('log:location')).length, 1);
        // The screen must be able to say a fix landed, and how good it is.
        expect(runner.locationStatus, contains('position fixed'));
        expect(runner.locationStatus, contains('4 m'));
      });
    });

    test('a failed fix says so on screen instead of looking normal', () {
      // Eight phones silently recording no position is the failure this is
      // meant to make visible while there is still time to fix it.
      fakeAsync((async) {
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          onSetBle: (on) async {},
          upload: () async => 'ok',
          onSampleLocation: () async => null,
        );
        expect(runner.hasLocation, isTrue);
        expect(runner.locationStatus, contains('when this phone is placed'));

        runner.start(geoPlan());
        async.flushMicrotasks();
        runner.inPosition();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 16));
        async.flushMicrotasks();

        expect(runner.locationStatus, contains('NO FIX'));
      });
    });

    test('a null fix never blocks the run', () {
      // No permission, services off, no sky view -- the step must still run.
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          onSetBle: (on) async {},
          upload: () async => 'ok',
          onSampleLocation: () async => null,
        );
        runner.start(geoPlan());
        async.flushMicrotasks();
        runner.inPosition();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 16));
        async.flushMicrotasks();

        expect(runner.isRunning, isTrue);
        expect(recorder.events, contains('marker:n=3 t1'));
        expect(recorder.events.where((e) => e.startsWith('log:location')), isEmpty);
      });
    });
  });

  group('manual-join wall-clock schedule', () {
    // Base sits 100s past a 10-minute boundary, so the anchor maths is
    // checkable by hand: tap+300s = B0+400s -> next boundary = B0+600s,
    // a 500s placement wait.
    const b0 = 1786500000000; // multiple of 600000
    const base = b0 + 100000;

    FieldPlan manualPlan({int order = 4}) => FieldPlanPresets.meshScale(
          expId: 'mesh-manual-t',
          role: order,
          maxDevices: 4,
          dwellSec: 120,
          repeat: 1,
        );

    test('anchor is the next 10-minute boundary >= tap + placement', () {
      fakeAsync((async) {
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => base + async.elapsed.inMilliseconds,
          bleUsable: () => false,
          upload: () async => 'ok',
        );
        runner.start(manualPlan());
        async.flushMicrotasks();

        expect(runner.phase, FieldPhase.placement);
        expect(runner.startTargetMs, b0 + 600000);
        expect(runner.startTargetMs! % 600000, 0,
            reason: 'every phone must round to the SAME instant');
        expect(runner.startTargetMs! - base,
            greaterThanOrEqualTo(runner.plan!.placementSec * 1000));
        runner.dispose();
      });
    });

    test('an aborted run is set aside so the next arm cannot append to it', () {
      // startExperiment APPENDS to an existing file of the same id. Without
      // the rename, an abort followed by a re-arm interleaves the dead run
      // with the real one in a single upload — which is exactly what reached
      // the server on 2026-08-08 and had to be cut out in analysis.
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => base + async.elapsed.inMilliseconds,
          upload: () async => 'ok',
        );
        runner.start(manualPlan(order: 1));
        async.flushMicrotasks();
        unawaited(runner.abort());
        async.flushMicrotasks();

        expect(recorder.events, contains('marker:aborted'));
        expect(recorder.archived, ['mesh-manual-t'],
            reason: 'the abandoned file must be moved aside, by its own id');
        runner.dispose();
      });
    });

    test('two runs under one experiment id get DIFFERENT run ids', () {
      // Testbed ids are deterministic so a trace can be re-derived offline.
      // Without a per-run term that determinism made two runs mint identical
      // ids for every message, and any join on messageId silently merged them.
      // The run id is the seed term that separates them; assert it differs.
      // (Production is unaffected — real messages get a random v4 id.)
      int runIdFor(int base) {
        late int id;
        fakeAsync((async) {
          final recorder = _FakeRecorder();
          final runner = FieldRunner(
            recorder: recorder,
            nowMs: () => base + async.elapsed.inMilliseconds,
            upload: () async => 'ok',
          );
          runner.start(manualPlan(order: 1));
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 500001));
          async.flushMicrotasks();
          id = recorder.markerExtras
              .firstWhere((e) => e.$1 == 'n=3').$2['run']! as int;
          runner.dispose();
        });
        return id;
      }

      final first = runIdFor(base);
      final second = runIdFor(base + const Duration(hours: 1).inMilliseconds);
      expect(first, isNot(second),
          reason: 'a later run must not re-mint the earlier run\'s ids');
    });

    test('a scripted-radio plan never prompts the operator for the radio', () {
      // Seen on hardware 2026-08-10: a hands-free desk plan told the operator
      // "TURN BLUETOOTH OFF" during a dark window the runner was already
      // opening. There is nothing for them to do, and the system Bluetooth
      // adapter stays on regardless — only the app's transport goes down.
      fakeAsync((async) {
        // The radio reads UP throughout, so a dark step genuinely disagrees
        // with the observed state — which is exactly when the prompt fired.
        final scf = FieldPlanPresets.storeCarryForward(role: 1);
        expect(scf.scriptedRadio, isTrue);
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => base + async.elapsed.inMilliseconds,
          bleUsable: () => true,
          onSetBle: (on) async {},
          upload: () async => 'ok',
        );
        runner.start(scf);
        async.flushMicrotasks();
        // Walk the whole plan: warm, dark and return of every arm.
        for (var i = 0; i < 40; i++) {
          async.elapse(const Duration(seconds: 30));
          async.flushMicrotasks();
          expect(runner.radioAction, isNull,
              reason: 'the runner owns the radio here, not the operator '
                  '(step ${runner.currentStep?.label})');
        }
        runner.dispose();
      });
    });

    test('the step marker records the run id, so ids stay derivable', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => base + async.elapsed.inMilliseconds,
          upload: () async => 'ok',
        );
        runner.start(manualPlan(order: 1));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 500001));
        async.flushMicrotasks();

        final extra =
            recorder.markerExtras.firstWhere((e) => e.$1 == 'n=3').$2;
        expect(extra['run'], b0 + 600000,
            reason: 'the run id is the shared anchor, so every phone agrees');
        runner.dispose();
      });
    });

    test('step markers carry BOTH session counts', () {
      // `sessions` is Redux-filtered and dips when a quiet peer is delisted
      // while its session lives; `sessionTable` is the table itself. Field
      // analysis needs both to tell a lost session from a delisted peer.
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => base + async.elapsed.inMilliseconds,
          sessionPeerCount: () => 2,
          sessionTableCount: () => 5,
          upload: () async => 'ok',
        );
        runner.start(manualPlan(order: 1));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 500001));
        async.flushMicrotasks();

        final extra =
            recorder.markerExtras.firstWhere((e) => e.$1 == 'n=3').$2;
        expect(extra['sessions'], 2);
        expect(extra['sessionTable'], 5);
        runner.dispose();
      });
    });

    test('the placement marker carries the nickname beside the order', () {
      // The order is typed per run and the nickname is set once on the
      // phone: recording both is what makes a mistyped order detectable
      // instead of silently remapping a device onto another node's geometry.
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => base + async.elapsed.inMilliseconds,
          myNickname: '2',
          upload: () async => 'ok',
        );
        runner.start(manualPlan(order: 2));
        async.flushMicrotasks();

        final extra =
            recorder.markerExtras.firstWhere((e) => e.$1 == 'placement').$2;
        expect(extra['nick'], '2');
        expect(extra['order'], 2);
        runner.dispose();
      });
    });

    test('no nickname stamps no nick field', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => base + async.elapsed.inMilliseconds,
          upload: () async => 'ok',
        );
        runner.start(manualPlan(order: 1));
        async.flushMicrotasks();

        final extra =
            recorder.markerExtras.firstWhere((e) => e.$1 == 'placement').$2;
        expect(extra.containsKey('nick'), isFalse);
        runner.dispose();
      });
    });

    test('steps open at absolute offsets; the radio is never touched', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final ble = <bool>[];
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => base + async.elapsed.inMilliseconds,
          onSetBle: (on) async => ble.add(on),
          upload: () async => 'ok',
        );
        // bleUsable null: no observer, so ble[] records only step-driven calls.
        runner.start(manualPlan(order: 1));
        async.flushMicrotasks();

        async.elapse(const Duration(milliseconds: 499999));
        expect(runner.phase, FieldPhase.placement, reason: '1s early');
        async.elapse(const Duration(milliseconds: 1001));
        async.flushMicrotasks();
        expect(runner.phase, FieldPhase.dwelling);
        expect(recorder.events, contains('marker:n=3'));

        // dwell 120s -> gap 30s -> next block at +150s exactly.
        async.elapse(const Duration(seconds: 120));
        async.flushMicrotasks();
        expect(runner.phase, FieldPhase.positioning);
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(runner.phase, FieldPhase.dwelling);
        expect(recorder.events, contains('marker:n=4'));

        expect(ble, isEmpty,
            reason: 'manual mode: system BT belongs to the operator');
        final pl = recorder.markerExtras
            .firstWhere((e) => e.$1 == 'placement')
            .$2;
        expect(pl['targetMs'], b0 + 600000);
        runner.dispose();
      });
    });

    test('no GPS fix is ever taken in manual mode', () {
      fakeAsync((async) {
        var fixes = 0;
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => base + async.elapsed.inMilliseconds,
          onSampleLocation: () async {
            fixes++;
            return {'lat': 1.0, 'lon': 2.0, 'accM': 3.0};
          },
          upload: () async => 'ok',
        );
        runner.start(manualPlan(order: 1));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 800));
        async.flushMicrotasks();
        expect(fixes, 0, reason: 'the layout is measured by hand');
        runner.dispose();
      });
    });

    test('radio observer: schedule-aware bounce, transitions stamped', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        var usable = false;
        final changes = StreamController<bool>.broadcast(sync: true);
        final bounces = <bool>[];
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => base + async.elapsed.inMilliseconds,
          bleUsable: () => usable,
          bleUsableChanges: changes.stream,
          onSetBle: (on) async => bounces.add(on),
          upload: () async => 'ok',
        );
        runner.start(manualPlan()); // order 4: dark until n=4
        async.flushMicrotasks();

        // The initial state is stamped, so the run opens with explicit
        // radio ground truth instead of an implied one.
        expect(recorder.events, contains('marker:bt-off'));

        async.elapse(const Duration(seconds: 60));
        expect(bounces, isEmpty,
            reason: 'dark by schedule: bouncing would fight the operator');

        // n=3 opens at +500s, n=4 (this phone\'s join) at +650s.
        async.elapse(const Duration(seconds: 600));
        async.flushMicrotasks();
        expect(bounces, isNotEmpty,
            reason: 'wanted ON and down: re-init so a settings toggle is '
                'picked up without a tap');

        // Operator flips Bluetooth on: the stamp is EVENT-driven — it lands
        // with ZERO elapsed time, because a stamp that waits for a poll tick
        // is up to 2s late and that lag once turned a formed session into a
        // "peer that never formed" in analysis.
        usable = true;
        changes.add(true);
        async.flushMicrotasks();
        expect(recorder.events.where((e) => e == 'marker:bt-on').length, 1,
            reason: 'stamped at the transition itself, no poll latency');
        expect(runner.radioUp, isTrue);
        expect(runner.radioSeenUp, isTrue);

        // A mid-run outage is a transition too — stamped immediately.
        usable = false;
        changes.add(false);
        async.flushMicrotasks();
        expect(recorder.events.where((e) => e == 'marker:bt-off').length, 2);
        usable = true;
        changes.add(true);
        async.flushMicrotasks();
        expect(recorder.events.where((e) => e == 'marker:bt-on').length, 2);

        // A duplicate emission is not a transition: no double stamp.
        changes.add(true);
        async.flushMicrotasks();
        expect(recorder.events.where((e) => e == 'marker:bt-on').length, 2);
        runner.dispose();
        changes.close();
      });
    });


    test('sessions count is stamped into every step marker', () {
      // The formation assertion: each rep carries "was the topology up when
      // this window opened" as a field, not an inference.
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        var sessions = 0;
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => base + async.elapsed.inMilliseconds,
          sessionPeerCount: () => sessions,
          upload: () async => 'ok',
        );
        runner.start(manualPlan(order: 1));
        async.flushMicrotasks();
        sessions = 3;
        async.elapse(const Duration(seconds: 501));
        async.flushMicrotasks();
        final n3 = recorder.markerExtras.firstWhere((e) => e.$1 == 'n=3').$2;
        expect(n3['sessions'], 3);
        expect(n3['joined'], isTrue);
        runner.dispose();
      });
    });

    test('myJoinAtMs is the absolute start of the first joined step', () {
      fakeAsync((async) {
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => base + async.elapsed.inMilliseconds,
          upload: () async => 'ok',
        );
        runner.start(manualPlan(order: 4)); // joins at n=4, block 2
        async.flushMicrotasks();
        // n=3 at the anchor; n=4 at anchor + (120+30)s
        expect(runner.myJoinAtMs, b0 + 600000 + 150000);
        expect(runner.joinsLater, isTrue);
        runner.dispose();
      });
    });

    test('waitingToJoin runs to the TURN ON window, and only for joiners', () {
      fakeAsync((async) {
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => base + async.elapsed.inMilliseconds,
          upload: () async => 'ok',
        );
        runner.start(manualPlan(order: 4));
        async.flushMicrotasks();
        expect(runner.waitingToJoin, isTrue, reason: 'during placement');

        // n=3 opens at +500s; the join window (gap before n=4) at +620s.
        async.elapse(const Duration(seconds: 619));
        expect(runner.waitingToJoin, isTrue, reason: '1s before the window');
        async.elapse(const Duration(seconds: 2));
        expect(runner.waitingToJoin, isFalse,
            reason: 'the window itself shows TURN ON, not a countdown');
        runner.dispose();
      });
    });

    test('a founding phone never sees the waiting screen', () {
      fakeAsync((async) {
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => base + async.elapsed.inMilliseconds,
          upload: () async => 'ok',
        );
        runner.start(manualPlan(order: 1));
        async.flushMicrotasks();
        expect(runner.waitingToJoin, isFalse);
        async.elapse(const Duration(seconds: 600));
        expect(runner.waitingToJoin, isFalse);
        runner.dispose();
      });
    });

    test('manual plan round-trips through JSON', () {
      final p = manualPlan();
      expect(p.manualJoin, isTrue);
      expect(p.sampleGps, isFalse);
      expect(FieldPlan.fromJson(p.toJson()), p);
    });
  });
}
