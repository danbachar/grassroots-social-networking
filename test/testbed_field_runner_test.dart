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
  Future<String?> discardAbortedExperiment(String id) async {
    archived.add(id);
    return 'exp_$id.jsonl';
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

  /// Full records, for assertions on structured payloads (the dial-probe
  /// `dialburst` contract is field-exact — the analyzer joins on it).
  final List<Map<String, dynamic>> records = [];

  @override
  Future<void> log(Map<String, dynamic> record) async {
    records.add(record);
    events.add('log:${record['type']}:${record['event']}');
  }
}

void main() {
  FieldPlan plan() => const FieldPlan(
        expId: 'cp-line-1',
        steps: [
          FieldStep(label: 'd=40', dwellSec: 10),
          FieldStep(label: 'd=20', dwellSec: 10),
        ],
      );



  test('nextMove names the next position and when to be there', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final runner = FieldRunner(recorder: recorder, myNickname: '1');

      // Two positions, three dwells each: only the first dwell at a position
      // is something to walk to, exactly as the line sweep is built.
      runner.start(FieldPlan(
        expId: 'move-1',
        manualJoin: true,
        placementSec: 60,
        alignSec: 60,
        resetBudgetSec: 5,
        walkBudgetSec: 120,
        steps: const [
          FieldStep(label: 'd=10 t1', dwellSec: 30),
          FieldStep(label: 'd=10 t2', dwellSec: 30, autoAdvance: true),
          FieldStep(label: 'd=10 t3', dwellSec: 30, autoAdvance: true),
          FieldStep(label: 'd=20 t1', dwellSec: 30),
          FieldStep(label: 'd=20 t2', dwellSec: 30, autoAdvance: true),
        ],
      ));
      async.flushMicrotasks();

      final move = runner.nextMove;
      expect(move, isNotNull);
      expect(move!.label, 'd=20 t1',
          reason: 'the repeats at d=10 are not somewhere to walk to');
      // The walk must be done before that step's resets open, not its dwell.
      expect(move.atMs, lessThan(runner.planEndMs!));

      runner.dispose();
    });
  });

  test('finish-early keeps the file and says so in the trace; abort deletes',
      () {
    fakeAsync((async) {
      // The two mid-run exits differ in exactly one way that matters — the
      // data — and the abort dialog used to claim files were kept while the
      // code deleted them.
      final kept = _FakeRecorder();
      final r1 = FieldRunner(recorder: kept, myNickname: '1');
      r1.start(FieldPlanPresets.manualized(
        const FieldPlan(
          expId: 'keep-1',
          steps: [FieldStep(label: 'd=10 t1', dwellSec: 30)],
        ),
        alignSec: 120,
        placementSec: 120,
      ));
      async.flushMicrotasks();
      r1.forceFinish();
      async.flushMicrotasks();
      expect(kept.archived, isEmpty, reason: 'finishing early deletes nothing');
      expect(kept.events, contains('marker:finished-early'),
          reason: 'an early finish must be distinguishable from a dead '
              'process — both otherwise end with no `end` marker');
      r1.dispose();

      final dropped = _FakeRecorder();
      final r2 = FieldRunner(recorder: dropped, myNickname: '1');
      r2.start(FieldPlanPresets.manualized(
        const FieldPlan(
          expId: 'drop-1',
          steps: [FieldStep(label: 'd=10 t1', dwellSec: 30)],
        ),
        alignSec: 120,
        placementSec: 120,
      ));
      async.flushMicrotasks();
      r2.abort();
      async.flushMicrotasks();
      expect(dropped.events, contains('marker:aborted'));
      expect(dropped.archived, contains('drop-1'),
          reason: 'abort discards the run it just marked');
      r2.dispose();
    });
  });

  group('operator stack-reset verification', () {
    FieldPlan resetPlan() => FieldPlan(
          expId: 'reset-ui-1',
          manualJoin: true,
          placementSec: 60,
          alignSec: 60,
          resetBudgetSec: 5,
          walkBudgetSec: 120,
          stackResetPerPosition: true,
          steps: const [
            FieldStep(label: 'd=10 t1', dwellSec: 30),
            FieldStep(label: 'd=20 t1', dwellSec: 30),
          ],
        );

    test('a full off-then-on cycle flips the prompt to done', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final radio = StreamController<bool>.broadcast(sync: true);
        final runner = FieldRunner(
          recorder: recorder,
          bleUsable: () => true,
          bleUsableChanges: radio.stream,
          myNickname: '1',
        );
        runner.start(resetPlan());
        async.flushMicrotasks();

        expect(runner.phase, FieldPhase.placement);
        expect(runner.stackResetDone, isFalse,
            reason: 'the radio has only been seen up; nothing was reset');

        radio.add(true);
        async.flushMicrotasks();
        expect(runner.stackResetDone, isFalse,
            reason: 'up without a preceding down is not a reset');

        radio.add(false);
        async.flushMicrotasks();
        expect(runner.stackResetDone, isFalse,
            reason: 'half a cycle: the radio is still down');

        radio.add(true);
        async.flushMicrotasks();
        expect(runner.stackResetDone, isTrue);

        runner.dispose();
        radio.close();
      });
    });

    test('each walk window owes its own reset', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final radio = StreamController<bool>.broadcast(sync: true);
        final runner = FieldRunner(
          recorder: recorder,
          bleUsable: () => true,
          bleUsableChanges: radio.stream,
          myNickname: '1',
        );
        runner.start(resetPlan());
        async.flushMicrotasks();

        radio.add(false);
        radio.add(true);
        async.flushMicrotasks();
        expect(runner.stackResetDone, isTrue,
            reason: 'reset during placement, verified');

        // Through placement and the d=10 dwell, into the walk to d=20.
        while (runner.phase != FieldPhase.positioning) {
          async.elapse(const Duration(seconds: 5));
          async.flushMicrotasks();
          if (!runner.isRunning) fail('run ended before the walk window');
        }
        expect(runner.stackResetDone, isFalse,
            reason: 'the new position has not been reset yet');

        radio.add(false);
        radio.add(true);
        async.flushMicrotasks();
        expect(runner.stackResetDone, isTrue);

        runner.dispose();
        radio.close();
      });
    });
  });

  group('the walk window names the place being walked to', () {
    FieldPlan sweep() => FieldPlan(
          expId: 'walk-1',
          manualJoin: true,
          placementSec: 60,
          alignSec: 60,
          // The line's shape: every step bounces, so every step is charged
          // the slot — a budget on a plan that never bounces buys nothing.
          resetLinks: true,
          resetBudgetSec: 5,
          walkBudgetSec: 60,
          steps: const [
            FieldStep(label: 'd=10 t1', dwellSec: 30),
            FieldStep(label: 'd=10 t2', dwellSec: 30, autoAdvance: true),
            FieldStep(label: 'd=20 t1', dwellSec: 30),
            FieldStep(label: 'd=20 t2', dwellSec: 30, autoAdvance: true),
            FieldStep(label: 'd=30 t1', dwellSec: 30),
          ],
        );

    /// Advance to the gap that precedes [label]. The wall-clock schedule is
    /// absolute, so the injected clock has to move with the virtual one.
    FieldRunner runTo(FakeAsync async, String label,
        {FieldPhase phase = FieldPhase.positioning}) {
      var clock = 1700000000000;
      final runner = FieldRunner(
          recorder: _FakeRecorder(), myNickname: '1', nowMs: () => clock);
      runner.start(sweep());
      async.flushMicrotasks();
      for (var i = 0; i < 400; i++) {
        clock += 1000;
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        if (runner.phase == phase && runner.currentStep?.label == label) {
          return runner;
        }
        if (!runner.isRunning) break;
      }
      fail('never reached $phase at $label');
    }

    test('the walk counts down to the position it is walking TO', () {
      fakeAsync((async) {
        // The step index advances before the gap opens, so searching past
        // the upcoming step named d=30 while the operator walked to d=20 —
        // and counted down to d=30's deadline, minutes too far out.
        final runner = runTo(async, 'd=20 t1');
        expect(runner.nextMove?.label, 'd=20 t1');
        runner.dispose();
      });
    });

    test('the countdown target is the run start, not a deadline to miss', () {
      fakeAsync((async) {
        // Nothing waits for the operator, so the number on the screen is
        // simply when the next measurement opens. The position deadline is
        // the earlier instant, when the scripted reset begins.
        final runner = runTo(async, 'd=20 t1');
        final move = runner.nextMove!;
        expect(move.startsAtMs, greaterThan(move.atMs));
        expect(move.startsAtMs - move.atMs, 5 * 1000,
            reason: 'the gap between them is the reset budget');
        runner.dispose();
      });
    });

    test('a gap between repeats at one position is not a walk', () {
      fakeAsync((async) {
        final runner = runTo(async, 'd=10 t2');
        expect(runner.nextMove, isNull,
            reason: 'MOVE here would send the operator away mid-position, '
                'and it carries the stack-reset card with it');
        runner.dispose();
      });
    });

    test('during a dwell the walk shown is the one after it', () {
      fakeAsync((async) {
        final runner =
            runTo(async, 'd=10 t1', phase: FieldPhase.dwelling);
        expect(runner.nextMove?.label, 'd=20 t1',
            reason: 'the dwell footnote says where the operator heads next');
        runner.dispose();
      });
    });
  });

  test('nextMove is null once there is nothing left to walk to', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final runner = FieldRunner(recorder: recorder, myNickname: '1');
      runner.start(FieldPlan(
        expId: 'move-2',
        manualJoin: true,
        placementSec: 60,
        alignSec: 60,
        steps: const [
          FieldStep(label: 'only', dwellSec: 30),
          FieldStep(label: 'only t2', dwellSec: 30, autoAdvance: true),
        ],
      ));
      async.flushMicrotasks();
      expect(runner.nextMove, isNull,
          reason: 'every later step auto-advances, so nobody has to move');
      runner.dispose();
    });
  });


  test('a role-free diluting plan refuses to launch without a numeric '
      'nickname', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final runner = FieldRunner(recorder: recorder, myNickname: 'Alice');
      runner.start(FieldPlanPresets.dilutingLineLoads());
      async.flushMicrotasks();
      expect(runner.isRunning, isFalse);
      expect(runner.abortReason, contains('not a join order'));
      expect(recorder.events, isEmpty,
          reason: 'nothing may be recorded for a run that never started');
      runner.dispose();
    });
  });

  test('a role-free diluting plan resolves membership from the nickname', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      final runner = FieldRunner(recorder: recorder, myNickname: '4');
      runner.start(FieldPlanPresets.dilutingLineLoads());
      async.flushMicrotasks();
      expect(runner.isRunning, isTrue);
      // The resolved plan is what the runner holds: phone #4 is off through
      // the N=2 and N=3 phases and on from N=4.
      final steps = runner.plan!.steps;
      expect(steps.every((s) => s.bleOn != null), isTrue);
      expect(steps.where((s) => s.bleOn == true).map((s) => s.cliqueN).toSet(),
          {4, 5, 6, 7});
      runner.dispose();
    });
  });




  test('every dropdown preset actually starts under FieldRunner', () {
    // The static field checks in testbed_field_plan_presets_test.dart can
    // all pass while the plan still cannot run: manualJoin is the one
    // requirement `start()` enforces on itself ('not a wall-clock plan'),
    // and a preset builder that forgets to set it aborts on the very first
    // launch with nothing recorded — every other field it configures
    // (placementSec, alignSec, the steps) goes untested right along with
    // it. Only calling start() itself catches that.
    for (final entry in FieldPlanPresets.presets.entries) {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          myNickname: '1',
          // A warmed mesh. The ring presets set minSessionsToLaunch: under the
          // ring gate a non-neighbour can never handshake, so every pair must
          // already hold a session before the topology is constrained, and the
          // operator brings the fleet there before launching. Reporting a full
          // session table is what "warmed up" looks like to the runner —
          // without it the ring presets correctly refuse to start.
          sessionTableCount: () => 64,
        );
        runner.start(entry.value);
        async.flushMicrotasks();
        expect(runner.isRunning, isTrue,
            reason: '${entry.key}: ${runner.abortReason}');
        runner.dispose();
      });
    }
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
        resetSessions: resetSessions,
        roster: [
          WorkloadRosterEntry(label: 'A', pubkeyHex: hexOf(0)),
          WorkloadRosterEntry(label: 'B', pubkeyHex: hexOf(100)),
        ],
        steps: const [
          FieldStep(label: 'd=40', dwellSec: 10, sendCount: 3, sendBytes: 32),
        ],
      );


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


  test('sessionUp never true: the step sends nothing (out of range)', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      var sends = 0;
      final runner = FieldRunner(
        recorder: recorder,
        myPubkeyHex: hexOf(0),
        sessionUp: (_) => false,
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
      expect(recorder.events.where((e) => e == 'marker:session-up'), isEmpty);
      runner.dispose();
    });
  });




  // REAL timers on purpose: the starvation this guards against is a
  // microtask chain outrunning the event loop, and fakeAsync cannot model it
  // (a zero-duration timer there re-fires forever at the same fake instant).





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


  test('resetLinks defaults off: callback never fires', () {
    fakeAsync((async) {
      final recorder = _FakeRecorder();
      var links = 0;
      final runner = FieldRunner(
        recorder: recorder,
        onResetLinks: (_, {whileDark, untilMs}) async => links++,
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



  test('FieldPlan with roster/sends/resetSessions round-trips', () {
    final p = sendPlan();
    final restored = FieldPlan.fromJson(p.toJson());
    expect(restored, p);
    expect(restored.steps.single.sendCount, 3);
    expect(restored.steps.single.sendBytes, 32);
    expect(restored.resetSessions, isTrue);
  });



  group('lattice steps (the only scheduling mode)', () {
    const lb = 1786500000000; // whole-second base: alignSec 1 anchors HERE
    final pkA = Uint8List.fromList(List.filled(32, 0xaa));
    final pkB = Uint8List.fromList(List.filled(32, 0xbb));

    FieldPlan lat({
      List<FieldStep>? steps,
      bool resetDtn = false,
      bool resetSessions = false,
      bool resetLinks = false,
    }) =>
        FieldPlan(
          expId: 'lat-t',
          resetSessions: resetSessions,
          resetLinks: resetLinks,
          resetDtnBuffer: resetDtn,
          manualJoin: true,
          placementSec: 0,
          alignSec: 1,
          steps: steps ??
              [FieldStep(label: 's1', dwellSec: 30, sendCount: 10)],
        );

    /// Drive start() through placement to the first dwell. The base sits on
    /// the alignment boundary and placement is zero, so the anchor IS the
    /// base and nothing here shifts the test's own timeline.
    void pump(FakeAsync async) {
      for (var i = 0; i < 4; i++) {
        async.flushMicrotasks();
        async.elapse(Duration.zero);
      }
    }

    test('ring step: gate armed BEFORE the sever, both after the marker', () {
      fakeAsync((async) {
        final order = <String>[];
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => lb + async.elapsed.inMilliseconds,
          sessionTableCount: () => 3,
          onSetRingGate: (roster, radius) async =>
              order.add('gate:$radius:${roster.length}'),
          onSeverLinks: () async => order.add('sever'),
        );
        runner.start(FieldPlan(
          expId: 'ring-t',
          manualJoin: true,
          placementSec: 0,
          alignSec: 1,
          severLinks: true,
          resetSessions: false,
          resetDtnBuffer: false,
          roster: const [
            WorkloadRosterEntry(label: 'a', pubkeyHex: 'aa'),
            WorkloadRosterEntry(label: 'b', pubkeyHex: 'bb'),
          ],
          steps: const [
            FieldStep(label: 'r=2 t1', dwellSec: 1, ringRadius: 2),
          ],
        ));
        pump(async);

        // Radius first: the prune runs while the gate is armed, so severing
        // second cannot leave a window where surviving links re-dial under the
        // outgoing radius.
        expect(order, ['gate:2:2', 'sever']);
        // And both happen AFTER the step marker, which opens the segment
        // before any reset so establishment lands inside it.
        final markerIdx = recorder.events.indexOf('marker:r=2 t1');
        final severIdx = recorder.events.indexOf('marker:links-severed');
        expect(markerIdx, isNonNegative);
        expect(severIdx, greaterThan(markerIdx));
        runner.dispose();
      });
    });

    test('ring step stamps the radius on its marker', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => lb + async.elapsed.inMilliseconds,
          sessionTableCount: () => 3,
          onSetRingGate: (_, __) async {},
        );
        runner.start(lat(steps: const [
          FieldStep(label: 'r=3 t1', dwellSec: 1, ringRadius: 3),
        ]));
        pump(async);
        // So the analyzer reads r off the marker rather than re-parsing the
        // label, the same way maxParallel/popN are carried.
        final extra = recorder.markerExtras
            .firstWhere((e) => e.$1 == 'r=3 t1')
            .$2;
        expect(extra['r'], 3);
        runner.dispose();
      });
    });

    test('per-pair pacing: one send per pair per SLOT, phase decorrelated',
        () {
      fakeAsync((async) {
        final sent = <(int, String)>[];
        final pkC = Uint8List.fromList(List.filled(32, 0xcc));
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => lb + async.elapsed.inMilliseconds,
          knownPeers: () => [pkA, pkB, pkC],
          sessionUp: (_) => true,
          send: (peer, payload, {messageId}) async {
            sent.add((async.elapsed.inMilliseconds,
                peer.first.toRadixString(16)));
            return messageId;
          },
          upload: () async => 'ok',
        );
        runner.start(lat(steps: const [
          FieldStep(
              label: 'r=1 t1',
              dwellSec: 30,
              sendCount: 6,
              perPairPacing: true),
        ]));
        pump(async);
        final startAt = async.elapsed.inMilliseconds;
        async.elapse(const Duration(seconds: 30));

        // sendCount is PER DESTINATION: three sessions x six each.
        expect(sent, hasLength(18));
        const slot = 30000 ~/ 6; // 5 s
        for (final hex in ['aa', 'bb', 'cc']) {
          final mine = sent.where((e) => e.$2 == hex).toList();
          expect(mine, hasLength(6), reason: '$hex gets its own full cadence');
          // Exactly one send per slot: the RATE is unchanged by the jitter.
          for (var k = 0; k < 6; k++) {
            final inSlot = mine.where((e) {
              final off = e.$1 - startAt;
              return off >= k * slot && off < (k + 1) * slot;
            });
            expect(inSlot, hasLength(1), reason: '$hex slot $k');
          }
        }
      });
    });

    test('send phases are not locked to the slot boundary', () {
      // The bug this guards: a strictly periodic timer at the announce
      // interval samples a latency distribution that is quantised in announce
      // rounds at ONE fixed phase, so a pair's median becomes a property of
      // where its timer landed rather than of the topology.
      final offsets = <int>{};
      for (var run = 0; run < 6; run++) {
        fakeAsync((async) {
          final sent = <int>[];
          final runner = FieldRunner(
            recorder: _FakeRecorder(),
            nowMs: () => lb + async.elapsed.inMilliseconds,
            knownPeers: () => [pkA],
            sessionUp: (_) => true,
            send: (peer, payload, {messageId}) async {
              sent.add(async.elapsed.inMilliseconds);
              return messageId;
            },
            upload: () async => 'ok',
          );
          runner.start(lat(steps: const [
            FieldStep(
                label: 'r=1 t1',
                dwellSec: 30,
                sendCount: 6,
                perPairPacing: true),
          ]));
          pump(async);
          final startAt = async.elapsed.inMilliseconds;
          async.elapse(const Duration(seconds: 30));
          for (final t in sent) {
            offsets.add((t - startAt) % 5000);
          }
          runner.dispose();
        });
      }
      // Periodic sends would land on a single within-slot offset every time.
      expect(offsets.length, greaterThan(3),
          reason: 'phases must vary within the slot, got $offsets');
    });

    test('a peer with no session gets no timer at all', () {
      fakeAsync((async) {
        final sent = <String>[];
        final pkC = Uint8List.fromList(List.filled(32, 0xcc));
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => lb + async.elapsed.inMilliseconds,
          knownPeers: () => [pkA, pkB, pkC],
          // bb has not handshaked.
          sessionUp: (pk) => pk.first != 0xbb,
          send: (peer, payload, {messageId}) async {
            sent.add(peer.first.toRadixString(16));
            return messageId;
          },
          upload: () async => 'ok',
        );
        runner.start(lat(steps: const [
          FieldStep(
              label: 'r=1 t1',
              dwellSec: 30,
              sendCount: 4,
              perPairPacing: true),
        ]));
        pump(async);
        async.elapse(const Duration(seconds: 30));

        // The offered load follows the sessions held, not the roster: the two
        // live pairs keep their exact cadence rather than pacing around a gap.
        expect(sent.where((h) => h == 'bb'), isEmpty);
        expect(sent.where((h) => h == 'aa'), hasLength(4));
        expect(sent.where((h) => h == 'cc'), hasLength(4));
        runner.dispose();
      });
    });

    test('without per-pair pacing a round still fires every target at once',
        () {
      fakeAsync((async) {
        var sends = 0;
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => lb + async.elapsed.inMilliseconds,
          knownPeers: () => [pkA, pkB],
          sessionUp: (_) => true,
          send: (peer, payload, {messageId}) async {
            sends++;
            return messageId;
          },
          upload: () async => 'ok',
        );
        runner.start(lat(steps: const [
          FieldStep(label: 's1', dwellSec: 30, sendCount: 3),
        ]));
        pump(async);
        async.elapse(const Duration(seconds: 30));
        // The unchanged per-destination model: 3 rounds x 2 targets. This is
        // the burst rotation exists to remove, and it must stay available.
        expect(sends, 6);
        runner.dispose();
      });
    });

    test('refuses to launch below minSessionsToLaunch, and says why', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => lb + async.elapsed.inMilliseconds,
          sessionTableCount: () => 2,
        );
        runner.start(FieldPlan(
          expId: 'ring-guard',
          manualJoin: true,
          placementSec: 0,
          alignSec: 1,
          minSessionsToLaunch: 3,
          steps: const [FieldStep(label: 'r=1 t1', dwellSec: 1, ringRadius: 1)],
        ));
        pump(async);

        // A half-warmed phone cannot create a packet for the peers it is
        // missing, so those ordered pairs would contribute nothing for hours.
        expect(runner.isRunning, isFalse);
        expect(runner.abortReason, contains('2 Noise sessions'));
        expect(recorder.events, isEmpty, reason: 'nothing recorded at all');
        runner.dispose();
      });
    });

    test('launches once the mesh is warm', () {
      fakeAsync((async) {
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => lb + async.elapsed.inMilliseconds,
          sessionTableCount: () => 3,
          onSetRingGate: (_, __) async {},
        );
        runner.start(FieldPlan(
          expId: 'ring-guard',
          manualJoin: true,
          placementSec: 0,
          alignSec: 1,
          minSessionsToLaunch: 3,
          steps: const [FieldStep(label: 'r=1 t1', dwellSec: 1, ringRadius: 1)],
        ));
        pump(async);
        expect(runner.isRunning, isTrue, reason: runner.abortReason ?? '');
        runner.dispose();
      });
    });

    test('a severing step earns the reset slot, so the sever is not in the '
        'dwell', () {
      // It is sized for the sever's own round trips, NOT to let links re-form:
      // the ring stage deliberately starts into zero links, which is the
      // mechanism under test.
      const plan = FieldPlan(
        expId: 'slot',
        manualJoin: true,
        severLinks: true,
        resetBudgetSec: 30,
        steps: [FieldStep(label: 'r=1 t1', dwellSec: 60, ringRadius: 1)],
      );
      expect(FieldRunner.resetSlotMs(plan, plan.steps.single), 30000);
      const noSever = FieldPlan(
        expId: 'slot',
        manualJoin: true,
        resetBudgetSec: 30,
        steps: [FieldStep(label: 's1', dwellSec: 60)],
      );
      expect(FieldRunner.resetSlotMs(noSever, noSever.steps.single), 0);
    });

    test('per-step resetLinks bounces the first step only, purge riding '
        'the dark window', () {
      fakeAsync((async) {
        var links = 0;
        var purges = 0;
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => lb + async.elapsed.inMilliseconds,
          onResetLinks: (_, {whileDark, untilMs}) async {
            links++;
            await whileDark?.call();
          },
          onResetSessions: () => purges++,
        );
        runner.start(lat(steps: [
          FieldStep(
              label: 's1',
              dwellSec: 1,
              resetSessions: true,
              resetLinks: true),
          FieldStep(label: 's2', dwellSec: 1, autoAdvance: true),
        ]));
        pump(async);
        expect(links, 1, reason: 'the first step carries the override');
        expect(purges, 1, reason: 'the purge rode the dark window');
        async.elapse(const Duration(seconds: 30));
        expect(links, 1, reason: 's2 inherits the plan-level false');
        expect(purges, 1, reason: 'one purge for the whole test');
        runner.dispose();
      });
    });

    test('one ticker paces the dwell: per-destination rounds, spread, '
        'never a burst', () {
      fakeAsync((async) {
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => lb + async.elapsed.inMilliseconds,
          knownPeers: () => [pkA, pkB],
          sessionUp: (_) => true,
          send: (peer, payload, {messageId}) async => messageId,
          upload: () async => 'ok',
        );
        runner.start(lat());
        pump(async);
        expect(runner.phase, FieldPhase.dwelling);
        expect(runner.sentCount, 2,
            reason: 'the first round opens the window, one per '
                'destination');
        async.elapse(const Duration(seconds: 1));
        expect(runner.sentCount, 2,
            reason: 'interval is 30s/10 = 3s — nothing else yet');
        async.elapse(const Duration(seconds: 2));
        expect(runner.sentCount, 4, reason: 'second round at 3s');
        async.elapse(const Duration(seconds: 25));
        expect(runner.sentCount, 20,
            reason: '10 rounds x 2 destinations, done by 27s');
        runner.dispose();
      });
    });

    test('a session landing mid-dwell joins the remaining rounds; the '
        'run-end marker carries the ledger', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        var bUp = false;
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => lb + async.elapsed.inMilliseconds,
          knownPeers: () => [pkA, pkB],
          sessionUp: (pk) => pk[0] == 0xaa || bUp,
          send: (peer, payload, {messageId}) async => messageId,
          upload: () async => 'ok',
        );
        runner.start(lat());
        pump(async);
        // Rounds at 0, 3 .. 12 s: five rounds, A only, B skipped.
        async.elapse(const Duration(seconds: 13));
        expect(runner.sentCount, 5);
        expect(runner.skippedSends, 5);
        bUp = true; // B's handshake completes mid-dwell
        // Rounds at 15, 18, 21, 24, 27 s.
        async.elapse(const Duration(seconds: 15));
        expect(runner.sentCount, 15,
            reason: 'five more rounds, now two destinations each');
        async.elapse(const Duration(seconds: 5));
        pump(async);
        final ledger =
            recorder.markerExtras.firstWhere((e) => e.$1 == 'run-end').$2;
        expect(ledger['sent'], 15);
        expect(ledger['skippedSends'], 5);
        runner.dispose();
      });
    });

    test('no session at dwell start: the SCHEDULER parks on the session '
        'edge — the send function is never called sessionless', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        var up = false;
        final sessions = StreamController<Uint8List>.broadcast(sync: true);
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => lb + async.elapsed.inMilliseconds,
          knownPeers: () => [pkA],
          sessionUp: (_) => up,
          sessionEvents: sessions.stream,
          send: (peer, payload, {messageId}) async => messageId,
          upload: () async => 'ok',
        );
        runner.start(lat());
        pump(async);
        async.elapse(const Duration(seconds: 5));
        expect(runner.sentCount, 0, reason: 'no session, no call, no skip');
        expect(runner.skippedSends, 0);
        up = true;
        sessions.add(pkA);
        async.flushMicrotasks();
        expect(recorder.events, contains('marker:session-up'));
        expect(runner.sentCount, 1, reason: 'first round rides the edge');
        async.elapse(const Duration(seconds: 25));
        expect(runner.sentCount, 9,
            reason: 'paced at the FULL dwell interval (2.8s), the 5s-late '
                'session costs the round that no longer fits — the ticker '
                'never compresses the schedule to catch up');
        runner.dispose();
        sessions.close();
      });
    });

    test('a clique growth opens late by the join gap; sends start at the '
        'marker, repeats gap-free', () {
      fakeAsync((async) {
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          myNickname: '1',
          nowMs: () => lb + async.elapsed.inMilliseconds,
          knownPeers: () => [pkA],
          sessionUp: (_) => true,
          send: (peer, payload, {messageId}) async => messageId,
          upload: () async => 'ok',
        );
        runner.start(FieldPlan(
          expId: 'lat-t',
          manualJoin: true,
          placementSec: 0,
          alignSec: 1,
          joinGapSec: 5,
          steps: const [
            FieldStep(label: 'N=2 L=moderate t1', dwellSec: 30,
                cliqueN: 2, sendCount: 10),
            FieldStep(label: 'N=2 L=moderate t2', dwellSec: 30,
                cliqueN: 2, sendCount: 10, autoAdvance: true),
            FieldStep(label: 'N=3 L=moderate t1', dwellSec: 30,
                cliqueN: 3, sendCount: 10, autoAdvance: true),
          ],
        ));
        pump(async);
        expect(runner.sentCount, 1,
            reason: 'no send hold: the first round fires at the marker');

        // t2, same N, at +60 s: repeats follow gap-free.
        async.elapse(const Duration(seconds: 61));
        pump(async);
        expect(runner.currentStep?.label, 'N=2 L=moderate t2');
        expect(runner.phase, FieldPhase.dwelling);

        // t2's drain ends at +120 s; the join gap holds EVERY device to
        // +125 with no dwell measuring anywhere — the operator's window.
        async.elapse(const Duration(seconds: 61));
        pump(async);
        final inGap = runner.sentCount;
        expect(runner.currentStep?.label, 'N=3 L=moderate t1');
        expect(runner.phase, isNot(FieldPhase.dwelling),
            reason: 'inside the join gap nothing measures');
        async.elapse(const Duration(seconds: 4));
        pump(async);
        expect(runner.phase, FieldPhase.dwelling,
            reason: 'the new N opens 5 s late by the lattice, on time');
        expect(runner.sentCount, greaterThan(inGap));
        runner.dispose();
      });
    });

    test('short dwells derive a shorter suspect grace — the smoke warns too',
        () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => lb + async.elapsed.inMilliseconds,
          bleUsable: () => false,
          onSetBle: (_) async {},
          sessionPeerCount: () => 0,
          upload: () async => 'ok',
        );
        runner.start(lat(steps: [
          FieldStep(label: 's1', dwellSec: 10, sendCount: 2, bleOn: true),
        ]));
        pump(async);
        async.elapse(const Duration(seconds: 9));
        expect(runner.radioSuspect, isTrue,
            reason: 'grace = dwell-2 = 8 s here; a 20 s grace inside a 10 s '
                'dwell never fired at all');
        expect(runner.radioSuspectReason, 'adapterOff');
        runner.dispose();
      });
    });

    test('sendTo addresses one peer by hex prefix; a miss sends nothing',
        () {
      fakeAsync((async) {
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => lb + async.elapsed.inMilliseconds,
          knownPeers: () => [pkA, pkB],
          sessionUp: (_) => true,
          send: (peer, payload, {messageId}) async => messageId,
          upload: () async => 'ok',
        );
        runner.start(lat(steps: [
          FieldStep(label: 'hit', dwellSec: 4, sendCount: 1, sendTo: 'aaaa'),
          FieldStep(
              label: 'miss',
              dwellSec: 4,
              sendCount: 1,
              sendTo: '9999',
              autoAdvance: true),
        ]));
        pump(async);
        expect(runner.sentCount, 1, reason: 'the aaaa prefix matches A alone');
        async.elapse(const Duration(seconds: 5));
        pump(async);
        async.elapse(const Duration(seconds: 4));
        expect(runner.sentCount, 1,
            reason: 'an unmatched prefix sends nothing, not everything');
        runner.dispose();
      });
    });

    test('custody clears bracket every run and the session purge rides '
        'the dark window', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final order = <String>[];
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => lb + async.elapsed.inMilliseconds,
          onResetDtnBuffer: () => order.add('dtn'),
          onResetSessions: () => order.add('sessions'),
          onResetLinks: (d, {whileDark, untilMs}) async {
            order.add('dark-open');
            await whileDark?.call();
            order.add('dark-close');
          },
          upload: () async => 'ok',
        );
        runner.start(lat(
          resetDtn: true,
          resetSessions: true,
          resetLinks: true,
          steps: [
            FieldStep(label: 't1', dwellSec: 3),
            FieldStep(label: 't2', dwellSec: 3, autoAdvance: true),
          ],
        ));
        pump(async);
        async.elapse(const Duration(seconds: 30));
        pump(async);
        expect(order.where((e) => e == 'dtn').length, 3,
            reason: 'a leading clear per run plus the trailing one');
        expect(
            order.sublist(0, 4), ['dtn', 'dark-open', 'sessions', 'dark-close'],
            reason: 'buffer first with the radio up; the purge inside the '
                'dark window');
        expect(recorder.events, contains('marker:custody-reset'));
        expect(recorder.events, contains('marker:sessions-reset'));
        expect(recorder.events, contains('marker:links-reset'));
        runner.dispose();
      });
    });

    test('the full walk: markers in order, settle, upload; a word nickname '
        'stamps no join order', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        var uploads = 0;
        final runner = FieldRunner(
          recorder: recorder,
          myNickname: 'Alice',
          nowMs: () => lb + async.elapsed.inMilliseconds,
          knownPeers: () => [pkA],
          sessionUp: (_) => true,
          send: (peer, payload, {messageId}) async => messageId,
          upload: () async {
            uploads++;
            return 'ok';
          },
        );
        runner.start(lat(steps: [
          FieldStep(label: 's1', dwellSec: 3, sendCount: 1),
          FieldStep(label: 's2', dwellSec: 3, autoAdvance: true),
        ]));
        pump(async);
        async.elapse(const Duration(seconds: 30));
        pump(async);
        final marks = recorder.events
            .where((e) => e.startsWith('marker:'))
            .map((e) => e.substring(7))
            .toList();
        expect(
            marks,
            containsAllInOrder(
                ['placement', 's1', 'run-end', 's2', 'run-end', 'end']));
        expect(runner.phase, FieldPhase.finished);
        expect(uploads, 1);
        final s1 = recorder.markerExtras.firstWhere((e) => e.$1 == 's1').$2;
        expect(s1.containsKey('order'), isFalse,
            reason: 'a plain plan has no join order to stamp');
        runner.dispose();
      });
    });

    test('abort mid-dwell: the ticker dies, the aborted marker lands, the '
        'file is discarded', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => lb + async.elapsed.inMilliseconds,
          knownPeers: () => [pkA],
          sessionUp: (_) => true,
          send: (peer, payload, {messageId}) async => messageId,
          upload: () async => 'ok',
        );
        runner.start(lat());
        pump(async);
        async.elapse(const Duration(seconds: 3));
        final sentAtAbort = runner.sentCount;
        unawaited(runner.abort());
        pump(async);
        expect(recorder.events, contains('marker:aborted'));
        expect(recorder.archived, isNotEmpty,
            reason: 'an abandoned file uploads alongside real runs otherwise');
        async.elapse(const Duration(seconds: 10));
        expect(runner.sentCount, sentAtAbort,
            reason: 'no round fires after the abort');
        runner.dispose();
      });
    });
  });

  group('manual-join wall-clock schedule', () {
    // Base sits 100s past a 10-minute boundary, so the anchor maths is
    // checkable by hand: tap+300s = B0+400s -> next boundary = B0+600s,
    // a 500s placement wait.
    const b0 = 1786500000000; // multiple of 600000
    const base = b0 + 100000;

    // The join-scaling plan shape the schedule was designed against: one
    // step per population n=3..4, the phone joined iff its order <= n,
    // wall-clock aligned to 10-minute boundaries after a 300 s placement.
    FieldPlan manualPlan({int order = 4}) => FieldPlan(
          expId: 'mesh-manual-t',
          resetSessions: false,
          resetLinks: false,
          resetDtnBuffer: false,
          manualJoin: true,
          placementSec: 300,
          alignSec: 600,
          scriptedRadio: true,
          steps: [
            for (var n = 3; n <= 4; n++)
              FieldStep(
                label: 'n=$n',
                dwellSec: 120,
                sendCount: order <= n ? 60 : 0,
                bleOn: order <= n,
                autoAdvance: n > 3,
              ),
          ],
        );

    test('a usable but sessionless radio raises the suspect flag, once', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        var sessions = 0;
        final sessionCtrl = StreamController<Uint8List>.broadcast(sync: true);
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => base + async.elapsed.inMilliseconds,
          bleUsable: () => true,
          onSetBle: (_) async {},
          sessionPeerCount: () => sessions,
          sessionEvents: sessionCtrl.stream,
          upload: () async => 'ok',
        );
        runner.start(manualPlan(order: 1));
        async.flushMicrotasks();
        // Into the first dwell (anchor at +500s for this base).
        async.elapse(const Duration(seconds: 501));
        async.flushMicrotasks();
        expect(runner.phase, FieldPhase.dwelling);
        expect(runner.radioSuspect, isFalse,
            reason: 'establishment gets a grace window');

        async.elapse(const Duration(seconds: 25));
        expect(runner.radioSuspect, isTrue,
            reason: 'usable, wanted on, sessionless past the grace: zombie');
        expect(runner.radioSuspectReason, 'sessionless');
        expect(recorder.events, contains('marker:radio-suspect'));

        // The SESSION EVENT clears the banner — the edge itself, no poll —
        // and the marker never re-stamps.
        sessions = 1;
        sessionCtrl.add(Uint8List(32));
        async.flushMicrotasks();
        expect(runner.radioSuspect, isFalse);
        expect(
            recorder.events.where((e) => e == 'marker:radio-suspect').length,
            1,
            reason: 'the marker is once per run; the screen carries the rest');
        runner.dispose();
        sessionCtrl.close();
      });
    });

    test('a radio that never reports usable is flagged too — the real '
        'field failure, system Bluetooth off, is not gated behind '
        "usable==true", () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final sessionCtrl = StreamController<Uint8List>.broadcast(sync: true);
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => base + async.elapsed.inMilliseconds,
          bleUsable: () => false, // the adapter never comes up
          onSetBle: (_) async {},
          sessionPeerCount: () => 0,
          sessionEvents: sessionCtrl.stream,
          upload: () async => 'ok',
        );
        runner.start(manualPlan(order: 1));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 526));
        expect(runner.phase, FieldPhase.dwelling);
        expect(runner.radioSuspect, isTrue,
            reason: 'wanted on, never usable: the old check required '
                'usable==true and missed this entirely');
        expect(runner.radioSuspectReason, 'adapterOff');
        final extra =
            recorder.markerExtras.firstWhere((e) => e.$1 == 'radio-suspect').$2;
        expect(extra['reason'], 'adapterOff');
        runner.dispose();
        sessionCtrl.close();
      });
    });

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
        // A scripted-radio plan with a dark window in the middle, the
        // traveller shape the prompt bug fired on.
        const scf = FieldPlan(
          expId: 'scripted-t',
          manualJoin: true,
          placementSec: 300,
          alignSec: 600,
          scriptedRadio: true,
          steps: [
            FieldStep(label: 'lit', dwellSec: 60, bleOn: true),
            FieldStep(label: 'dark', dwellSec: 60, bleOn: false,
                autoAdvance: true),
            FieldStep(label: 'lit2', dwellSec: 60, bleOn: true,
                autoAdvance: true),
          ],
        );
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

    test('steps open at absolute offsets; a scripted plan works its own radio',
        () {
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

        // dwell 120s -> derived drain 120s -> next block at +240s exactly.
        async.elapse(const Duration(seconds: 120));
        async.flushMicrotasks();
        expect(runner.phase, FieldPhase.positioning);
        async.elapse(const Duration(seconds: 120));
        async.flushMicrotasks();
        expect(runner.phase, FieldPhase.dwelling);
        expect(recorder.events, contains('marker:n=4'));

        expect(ble, equals([true, true, true]),
            reason: 'a scripted plan works the radio: placement drives the '
                'step-0 state the moment the plan starts, then each step\'s '
                'bleOn IS the population, so the runner sets it and no '
                'operator is asked');
        final pl = recorder.markerExtras
            .firstWhere((e) => e.$1 == 'placement')
            .$2;
        expect(pl['targetMs'], b0 + 600000);
        runner.dispose();
      });
    });

    test('a manual plan that does NOT script the radio leaves it alone', () {
      fakeAsync((async) {
        final ble = <bool>[];
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => base + async.elapsed.inMilliseconds,
          onSetBle: (on) async => ble.add(on),
          upload: () async => 'ok',
        );
        runner.start(FieldPlan(
          expId: 'operator-radio-t',
          manualJoin: true,
          alignSec: 600,
          placementSec: 60,
          steps: [
            FieldStep(label: 'up', dwellSec: 30, bleOn: true),
            FieldStep(label: 'down', dwellSec: 30, bleOn: false, autoAdvance: true),
          ],
        ));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 600));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 35));
        async.flushMicrotasks();

        expect(ble, isEmpty,
            reason: 'without scriptedRadio the toggle belongs to the operator, '
                'and bleOn is intent for the marker rather than a command');
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
        expect(bounces, equals([false]),
            reason: 'placement lowers a scripted joiner to its step-0 state — '
                'desk sessions must not survive into the opening cell — and '
                'after that the schedule holds it dark: bouncing would fight '
                'the plan');

        // n=3 opens at +500s, n=4 (this phone\'s join) at +740s.
        async.elapse(const Duration(seconds: 700));
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
        // n=3 at the anchor; n=4 at anchor + (dwell 120 + derived drain 120)s
        expect(runner.myJoinAtMs, b0 + 600000 + 240000);
        expect(runner.joinsLater, isTrue);
        runner.dispose();
      });
    });

    test('the join window opens a drain plus a join gap before the join', () {
      fakeAsync((async) {
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          myNickname: '3', // joins when the clique reaches N=3
          nowMs: () => base + async.elapsed.inMilliseconds,
          upload: () async => 'ok',
        );
        runner.start(FieldPlan(
          expId: 'joingap-t',
          resetSessions: false,
          resetLinks: false,
          resetDtnBuffer: false,
          manualJoin: true,
          placementSec: 300,
          alignSec: 600,
          scriptedRadio: true,
          joinGapSec: 5,
          steps: const [
            FieldStep(label: 'N=2 t1', dwellSec: 30, cliqueN: 2,
                bleOn: false),
            FieldStep(label: 'N=3 t1', dwellSec: 30, cliqueN: 3,
                bleOn: true, autoAdvance: true),
          ],
        ));
        async.flushMicrotasks();
        // The join step opens gap-late on the lattice, and the toggle
        // window opens the moment the previous dwell ends: its drain plus
        // the gap, the whole quiet stretch.
        final anchor = runner.startTargetMs!;
        expect(runner.myJoinAtMs, anchor + (30 + 30 + 5) * 1000);
        expect(runner.joinWindowOpensAtMs, anchor + 30 * 1000);
        runner.dispose();
      });
    });

    test('the waiting screen holds through the window it exists for', () {
      fakeAsync((async) {
        final runner = FieldRunner(
          recorder: _FakeRecorder(),
          nowMs: () => base + async.elapsed.inMilliseconds,
          upload: () async => 'ok',
        );
        runner.start(manualPlan(order: 4));
        async.flushMicrotasks();
        expect(runner.waitingToJoin, isTrue, reason: 'during placement');

        // n=3 opens at +500s; the join window (gap before n=4) at +620s,
        // and this phone joins at +740s.
        async.elapse(const Duration(seconds: 619));
        expect(runner.waitingToJoin, isTrue, reason: '1s before the window');
        expect(runner.joinWindowOpen, isFalse, reason: 'not yet time to act');

        // Inside the window the screen must stay on the instruction: this is
        // the stretch that exists so the operator can flip the toggle, and a
        // screen that drops the prompt exactly then costs the joining phone
        // its whole clique size.
        async.elapse(const Duration(seconds: 2));
        expect(runner.waitingToJoin, isTrue,
            reason: 'the window itself is when the prompt matters most');
        expect(runner.joinWindowOpen, isTrue, reason: 'act NOW');

        async.elapse(const Duration(seconds: 120)); // past the +740s join
        expect(runner.waitingToJoin, isFalse,
            reason: 'joined: the phone is in the mesh and measuring');
        expect(runner.joinWindowOpen, isFalse);
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
      expect(FieldPlan.fromJson(p.toJson()), p);
    });

    test('a new position opens on an alignment boundary; the repeats do not',
        () {
      // Two positions of two runs each. The first run at a position waits
      // for the operator to walk there, so it opens on a boundary; its repeat
      // has nothing to walk to and follows immediately.
      final plan = FieldPlanPresets.manualized(
        FieldPlan(
          expId: 'align-t',
          alignSec: 120,
          // Line semantics: links reset per run, so the derived drain is
          // zero and steps pack back to back like the real sweep.
          resetLinks: true,
          resetBudgetSec: 5,
          walkBudgetSec: 120,
          steps: [
            for (final d in [20, 10])
              for (var t = 1; t <= 2; t++)
                FieldStep(
                    label: 'd=$d t$t', dwellSec: 30, autoAdvance: t > 1),
          ],
        ),
        alignSec: 120,
        placementSec: 120,
      );
      final starts = FieldRunner.stepStarts(plan, 0);

      expect(starts[0] % 120000, 0, reason: 'd=20 t1 opens on a boundary');
      expect(starts[1] - starts[0], 35000,
          reason: 'a repeat follows at reset + dwell, no rounding');
      expect(starts[2] % 120000, 0, reason: 'd=10 t1 opens on a boundary');
      // The walk runs from the previous dwell ending to the next resets
      // opening, and is reserved rather than left over.
      expect(starts[2] - 5000 - (starts[1] + 30000),
          greaterThanOrEqualTo(120000),
          reason: 'the walk is at least its budget');
    });

    test('the reset slot is charged only ahead of steps that bounce', () {
      final p = FieldPlanPresets.dilutingLineLoads();
      const a = 1786500000000; // sits on the plan's 300 s alignment boundary
      final starts = FieldRunner.stepStarts(p, a);
      expect(starts.first, a,
          reason: 'the first slot comes out of placement, ahead of the '
              'anchor, so the lattice itself is unshifted');
      // Warm repeats within an N: dwell + derived drain, nothing else.
      expect(starts[1] - starts[0], (30 + 30) * 1000);
      expect(starts[2] - starts[1], (30 + 30) * 1000);
      // An N boundary adds the join gap: drain, then 5 s in which every
      // device waits and the operator enables the joiner's Bluetooth.
      expect(p.steps[10].label, 'N=3 L=moderate t1');
      expect(starts[10] - starts[9], (30 + 30 + 5) * 1000);
      // The slot has to cover the whole dark window, which now carries the
      // trace flush (10 s) plus transport re-init.
      expect(FieldRunner.resetSlotMs(p, p.steps.first), 15000);
      expect(FieldRunner.resetSlotMs(p, p.steps[1]), 0);
      expect(FieldRunner.resetSlotMs(p, p.steps[10]), 0);
    });

    test('the step marker opens BEFORE the radio and resets, so the dials '
        'they provoke land inside the measured segment', () {
      fakeAsync((async) {
        final recorder = _FakeRecorder();
        final runner = FieldRunner(
          recorder: recorder,
          nowMs: () => base + async.elapsed.inMilliseconds,
          onResetLinks: (dark, {whileDark, untilMs}) =>
              Future<void>.delayed(Duration(seconds: dark ?? 0)),
          upload: () async => 'ok',
        );
        runner.start(FieldPlanPresets.manualized(
          const FieldPlan(
            expId: 'budget-t',
            alignSec: 120,
            resetLinks: true,
            linkResetDarkSec: 3,
            resetBudgetSec: 5,
            steps: [FieldStep(label: 'd=10 t1', dwellSec: 30)],
          ),
          alignSec: 120,
          placementSec: 120,
        ));
        async.flushMicrotasks();
        final target = runner.startTargetMs!;

        // The resets open a whole budget ahead of the step's instant — and
        // the STEP MARKER opens ahead of THEM, so the radio bring-up, the
        // bounce and every dial they provoke fall inside the segment the
        // analyzer reads. A marker stamped after the resets put the whole
        // establishment outside its own measurement window.
        async.elapse(Duration(milliseconds: target - 5000 - base));
        async.flushMicrotasks();
        expect(recorder.events, contains('marker:d=10 t1'),
            reason: 'the window opens before anything touches the radio');
        expect(recorder.events, isNot(contains('marker:links-reset')),
            reason: 'the 3 s bounce has only just started');
        expect(runner.phase, isNot(FieldPhase.dwelling),
            reason: 'the window is open but the dwell has not started');

        // The 3 s bounce lands inside the 5 s reservation, with 2 s to spare.
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        expect(recorder.events, contains('marker:links-reset'));
        expect(runner.phase, isNot(FieldPhase.dwelling),
            reason: 'the reset is done, but the dwell holds for its instant');

        // The DWELL opens on the instant itself, so it is full length and
        // every phone starts sending together.
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(runner.phase, FieldPhase.dwelling);
        runner.dispose();
      });
    });
  });

}
