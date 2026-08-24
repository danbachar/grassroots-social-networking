import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/protocol/fragment_handler.dart';
import 'package:grassroots_networking/src/testbed/field_plan_presets.dart';
import 'package:grassroots_networking/src/testbed/field_runner.dart';
import 'package:grassroots_networking/src/testbed/testbed_config.dart';

void main() {










  group('dilutingLineLoads (the clique at the line sweep\'s loads)', () {
    test('the arms are the line sweep\'s, per destination, and nothing else',
        () {
      final p = FieldPlanPresets.dilutingLineLoads();
      final counts = p.steps.map((s) => s.sendCount).toSet();
      expect(counts, {2, 100, 500},
          reason: 'probe, moderate and overload — the pair experiment is '
              'this sweep\'s N=2 baseline only if the loads match');
      expect(p.steps.every((s) => s.sendBytes == 138), isTrue,
          reason: 'the line sweep\'s payload');
    });

    test('no warm-up steps: every step is a measuring trial', () {
      final p = FieldPlanPresets.dilutingLineLoads();
      expect(p.steps.where((s) => s.sendCount == 0), isEmpty);
      expect(p.steps, hasLength(6 * 3 * 10),
          reason: 'N=2..7 x three arms x ten trials, nothing else');
    });

    test('role-free: the schedule is derived, and the mesh stays warm', () {
      final p = FieldPlanPresets.dilutingLineLoads();
      expect(p.steps.every((s) => s.cliqueN != null), isTrue);
      expect(p.resetSessions, isFalse);
      expect(p.resetLinks, isFalse);
      // Every trial clears custody, exactly as on the line: ten independent
      // draws per cell, no trial draining a predecessor's backlog.
      expect(p.resetDtnBuffer, isTrue);
      expect(p.steps.every((s) => s.resetDtnBuffer == null), isTrue,
          reason: 'the plan flag carries it; no per-step overrides');
      // The join rides the first trial of its clique size.
      final firstOfN = <int, String>{};
      for (final s in p.steps) {
        firstOfN.putIfAbsent(s.cliqueN!, () => s.label);
      }
      expect(firstOfN[3], 'N=3 L=probe t1');
    });

    test('the quiet drain survives, because the overload arm needs it', () {
      final p = FieldPlanPresets.dilutingLineLoads();
      expect(p.autoAdvanceGapSec, 30);
    });

    test('round-trips through the JSON the phones launch from', () {
      final p = FieldPlanPresets.dilutingLineLoads();
      final back = FieldPlan.fromJson(p.toJson());
      expect(back.steps.length, p.steps.length);
      expect(back.steps.last.label, 'N=7 L=overload t10');
      expect(back.steps.first.sendCount, 2);
    });
  });



  group('lineSweep (two phones, 10 m out to 120 m)', () {
    test('one pass outward: no distance is visited twice', () {
      final p = FieldPlanPresets.lineSweep();
      final order = <double>[];
      for (final s in p.steps) {
        final d = double.parse(
            RegExp(r'd=(\d+(?:\.\d+)?)').firstMatch(s.label)!.group(1)!);
        if (order.isEmpty || order.last != d) order.add(d);
      }
      expect(order, equals(List.of(order)..sort()),
          reason: 'strictly outward; the return leg is not part of this test');
      expect(order.toSet(), hasLength(order.length),
          reason: 'a distance revisited later would be a return by stealth');
      expect(order.first, 10);
      expect(order.last, 120);
      expect(order, hasLength(12), reason: 'every 10 m from 10 up to 120');
      expect(FieldPlanPresets.lineSweep().steps, hasLength(120),
          reason: '12 distances x 10 trials');
    });

    test('every step is a cold trial with the buffer cleared', () {
      final p = FieldPlanPresets.lineSweep();
      expect(p.resetLinks, isTrue);
      expect(p.resetSessions, isTrue);
      expect(p.resetDtnBuffer, isTrue);
    });

    test('sends are minimal: enough to stamp usable, not a load test', () {
      final p = FieldPlanPresets.lineSweep();
      for (final s in p.steps) {
        expect(s.sendCount, lessThanOrEqualTo(2));
        expect(s.sendCount, greaterThan(0),
            reason: 'a step that sends nothing can never stamp usable');
      }
    });

    test('only the first trial at a distance waits for the operator', () {
      final p = FieldPlanPresets.lineSweep(distances: [50, 20], trials: 3);
      final flags = p.steps.map((s) => s.autoAdvance).toList();
      expect(flags, [false, true, true, false, true, true]);
    });

    test('the distance survives the JSON round-trip in the label', () {
      final p = FieldPlanPresets.lineSweep(distances: [30], trials: 1);
      final back = FieldPlan.fromJson(p.toJson());
      expect(back.steps.single.label, 'd=30 t1');
    });
  });

  group('lineSweepUpTo (reach and repeats chosen per outing)', () {
    test('reach sets the positions, repeats set the dwells at each', () {
      final plan = FieldPlanPresets.lineSweepUpTo(maxDistance: 40, trials: 2);
      expect(plan.steps.map((s) => s.label).toList(),
          ['d=10 t1', 'd=10 t2', 'd=20 t1', 'd=20 t2',
           'd=30 t1', 'd=30 t2', 'd=40 t1', 'd=40 t2']);
    });

    test('a sweep can start at 1 m — as close as the pickers go', () {
      // Every position the pickers produce is one a log-distance fit can
      // take, so nothing downstream needs a special case for the closest
      // one.
      final plan = FieldPlanPresets.lineSweepUpTo(
          startDistance: 1, maxDistance: 21, stepMetres: 10, trials: 1);
      expect(plan.steps.map((s) => s.label), ['d=1 t1', 'd=11 t1', 'd=21 t1']);

      // The label is what the analyser reads the distance out of, so it has
      // to survive the JSON the phones actually launch from.
      final back = FieldPlan.fromJson(plan.toJson());
      expect(back.steps.first.label, 'd=1 t1');
    });

    test('the sweep starts where the site allows, not always at 10 m', () {
      final plan = FieldPlanPresets.lineSweepUpTo(
          startDistance: 40, maxDistance: 60, trials: 1);
      expect(plan.steps.map((s) => s.label), ['d=40 t1', 'd=50 t1', 'd=60 t1']);
    });

    test('a single position is a whole plan, with nothing to walk to', () {
      // Testing the pipeline on a desk: launch, resets, establishment, sends
      // and upload all exercised, but no second position means no walk.
      final plan = FieldPlanPresets.lineSweepUpTo(
          startDistance: 1, maxDistance: 1, stepMetres: 5, trials: 3);
      expect(plan.steps.map((s) => s.label),
          ['d=1 t1', 'd=1 t2', 'd=1 t3']);
      expect(plan.steps.where((s) => !s.autoAdvance), hasLength(1),
          reason: 'only the first dwell is a position; nothing follows it');
    });

    test('any step spacing the ground calls for, not a fixed set', () {
      for (final step in [1, 3, 7, 250]) {
        final plan = FieldPlanPresets.lineSweepUpTo(
            startDistance: 1, maxDistance: 1 + step, stepMetres: step,
            trials: 1);
        expect(plan.steps.map((s) => s.label),
            ['d=1 t1', 'd=${1 + step} t1'],
            reason: 'step of $step m');
      }
    });

    test('the step size sets how finely the range is sampled', () {
      final coarse = FieldPlanPresets.lineSweepUpTo(
          maxDistance: 100, stepMetres: 50, trials: 1);
      expect(coarse.steps.map((s) => s.label), ['d=10 t1', 'd=60 t1']);

      final fine = FieldPlanPresets.lineSweepUpTo(
          startDistance: 10, maxDistance: 25, stepMetres: 5, trials: 1);
      expect(fine.steps.map((s) => s.label),
          ['d=10 t1', 'd=15 t1', 'd=20 t1', 'd=25 t1']);
    });

    test('a reach short of the start still yields the one position', () {
      // A sweep of a single distance is a legitimate ask; a plan with no
      // steps is not, and would launch into nothing.
      final plan = FieldPlanPresets.lineSweepUpTo(
          startDistance: 80, maxDistance: 20, trials: 2);
      expect(plan.steps.map((s) => s.label), ['d=80 t1', 'd=80 t2']);
    });

    test('a step that cannot advance does not hang the builder', () {
      final plan = FieldPlanPresets.lineSweepUpTo(
          startDistance: 10, maxDistance: 30, stepMetres: 0, trials: 1);
      expect(plan.steps.map((s) => s.label),
          ['d=10 t1', 'd=11 t1', 'd=12 t1'].followedBy(
              [for (var d = 13; d <= 30; d++) 'd=$d t1']));
    });

    test('only the first dwell at a position is somewhere to walk to', () {
      final plan = FieldPlanPresets.lineSweepUpTo(maxDistance: 30, trials: 3);
      final walkTo = plan.steps.where((s) => !s.autoAdvance).map((s) => s.label);
      expect(walkTo, ['d=10 t1', 'd=20 t1', 'd=30 t1']);
    });

    test('a longer reach or more repeats only ever costs more time', () {
      int mins(FieldPlan p) {
        final starts = FieldRunner.stepStarts(p, 0);
        return starts.last + (p.steps.last.dwellSec + p.settleSec) * 1000;
      }
      final base = FieldPlanPresets.lineSweepUpTo(maxDistance: 60, trials: 3);
      expect(mins(FieldPlanPresets.lineSweepUpTo(maxDistance: 120, trials: 3)),
          greaterThan(mins(base)));
      expect(mins(FieldPlanPresets.lineSweepUpTo(maxDistance: 60, trials: 6)),
          greaterThan(mins(base)));
    });

    test('the thesis line design: 100 one-way sends and a stack reset per '
        'position', () {
      final plan = FieldPlanPresets.lineSweepUpTo(
          maxDistance: 20, trials: 2, receiverPrefix: '499F5C75');
      expect(plan.stackResetPerPosition, isTrue,
          reason: 'the operator cycles the whole stack at every position');
      expect(plan.steps.first.sendCount, 100,
          reason: '100 a trial — 1000 a distance at x10, the July load');
      expect(plan.steps.first.sendTo, '499f5c75',
          reason: 'one-way: only phones whose target matches the prefix '
              'send; the receiver matches no target and sends nothing');

      // The flag survives the JSON the phones actually launch from.
      final back = FieldPlan.fromJson(plan.toJson());
      expect(back.stackResetPerPosition, isTrue);
      expect(back.steps.first.sendTo, '499f5c75');

      // Blank prefix keeps both phones sending.
      final both = FieldPlanPresets.lineSweepUpTo(maxDistance: 20, trials: 1);
      expect(both.steps.first.sendTo, 'all');
    });

    test('the dwell and the load are chosen per outing', () {
      final p = FieldPlanPresets.lineSweepUpTo(
          maxDistance: 20, trials: 2, dwellSec: 90, sendCount: 250);
      expect(p.steps.every((s) => s.dwellSec == 90), isTrue);
      expect(p.steps.every((s) => s.sendCount == 250), isTrue);

      // Untouched, the pickers still produce the thesis slate.
      final d = FieldPlanPresets.lineSweepUpTo(maxDistance: 20, trials: 2);
      expect(d.steps.first.dwellSec, 30);
      expect(d.steps.first.sendCount, 100);

      // A dwell too short to hold a reset, or a load of nothing, would make
      // a trial that cannot measure what it claims to.
      final floored =
          FieldPlanPresets.lineSweepUpTo(maxDistance: 10, dwellSec: 0, sendCount: 0);
      expect(floored.steps.first.dwellSec, 5);
      expect(floored.steps.first.sendCount, 1);

      // Both survive the JSON the phones actually launch from.
      final back = FieldPlan.fromJson(p.toJson());
      expect(back.steps.first.dwellSec, 90);
      expect(back.steps.first.sendCount, 250);
    });

    test('the dropdown entry carries the defaults', () {
      final preset =
          FieldPlanPresets.presets[FieldPlanPresets.lineSweepPresetName]!;
      expect(preset.steps.last.label, 'd=120 t10');
      expect(preset.manualJoin, isTrue,
          reason: 'the sweep runs on the clock, with no taps');
    });

    test('the untouched pickers ARE the thesis run', () {
      // Selecting the preset and launching, with no field edited, must
      // produce the full thesis slate: the run that shipped with repeats
      // defaulting to 3 measured a third of the design without any screen
      // saying so.
      final plan = FieldPlanPresets.lineSweepUpTo();
      expect(plan.steps, hasLength(120), reason: '12 distances x 10 trials');
      expect(plan.steps.every((s) => s.sendCount == 100), isTrue,
          reason: '100 a trial, 1000 a distance, in each direction');
      expect(plan.steps.every((s) => s.sendTo == 'all'), isTrue,
          reason: 'both phones send unless a receiver prefix narrows it');
      expect(plan.stackResetPerPosition, isTrue);
      expect(plan.steps.last.label, 'd=120 t10');
    });
  });
}
