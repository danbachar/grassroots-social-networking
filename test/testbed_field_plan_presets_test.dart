import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/testbed/field_plan_presets.dart';
import 'package:grassroots_networking/src/testbed/field_runner.dart';
import 'package:grassroots_networking/src/testbed/testbed_config.dart';

void main() {










  group('dilutingLineLoads (the clique at the line sweep\'s loads)', () {
    test('one load only: the line\'s moderate 100 per destination', () {
      final p = FieldPlanPresets.dilutingLineLoads();
      expect(p.steps.map((s) => s.sendCount).toSet(), {100},
          reason: 'a single arm — the overload arm\'s transmit queue '
              'outlived its run and contaminated the next cell, so cells '
              'stay independent only at one load');
      expect(p.steps.every((s) => s.sendBytes == 138), isTrue,
          reason: 'the line sweep\'s payload');
    });

    test('no warm-up steps: every step is a measuring run', () {
      final p = FieldPlanPresets.dilutingLineLoads();
      expect(p.steps.where((s) => s.sendCount == 0), isEmpty);
      expect(p.steps, hasLength(6 * 10),
          reason: 'N=2..7 x ten runs of the one arm, nothing else');
    });

    test('role-free: the schedule is derived, and the mesh stays warm', () {
      final p = FieldPlanPresets.dilutingLineLoads();
      expect(p.steps.every((s) => s.cliqueN != null), isTrue);
      expect(p.resetSessions, isFalse);
      expect(p.resetLinks, isFalse);
      // Every run clears custody, exactly as on the line: ten independent
      // draws per cell, no run draining a predecessor's backlog.
      expect(p.resetDtnBuffer, isTrue);
      expect(p.steps.every((s) => s.resetDtnBuffer == null), isTrue,
          reason: 'the plan flag carries it; no per-step overrides');
      // The join rides the first run of its clique size.
      final firstOfN = <int, String>{};
      for (final s in p.steps) {
        firstOfN.putIfAbsent(s.cliqueN!, () => s.label);
      }
      expect(firstOfN[3], 'N=3 L=moderate t1');
      // ONE session purge, at the run's first run: sessions formed at
      // the desk during staging must not survive into the run — they made
      // phones create messages for peers whose radio was still down. Every
      // later run inherits the plan's false, so the mesh stays warm.
      // One reset, at the test's first run, on every device; every
      // other step — N boundaries included — resets nothing.
      expect(p.steps.first.resetSessions, isTrue);
      expect(p.steps.first.resetLinks, isTrue);
      expect(p.steps.skip(1).every((s) => s.resetSessions == null), isTrue);
      expect(p.steps.skip(1).every((s) => s.resetLinks == null), isTrue);
      // The one bounce happens with every bouncing phone dark at the same
      // lattice instant; the default 30 s gap would eat a whole dwell.
      // The dark window carries the trace flush — it is the only moment
      // nothing can transmit or receive — so it is sized by the write, not
      // by the 3 s bounce, and the slot has to cover it.
      expect(p.linkResetDarkSec, 10);
      expect(p.resetBudgetSec, 15,
          reason: 'the bounce gets a slot; stepStarts charges it only at '
              'the bouncing first step');
      expect(p.joinGapSec, 5,
          reason: 'between Ns every device waits while the operator '
              'enables the joining phone\'s Bluetooth');
    });

    test('the quiet drain survives, because the overload arm needs it', () {
      final p = FieldPlanPresets.dilutingLineLoads();
      expect(p.gapAfterSec(p.steps.first), p.steps.first.dwellSec,
          reason: 'warm plan: the drain IS the dwell, derived not dialed');
    });

    test('manualized() carries every plan field it did not set', () {
      // Same class as the resolvedFor bug: a rebuild that forgets a field
      // drops it on every phone at once. Only tests call this today, which
      // is exactly why it would be found on a field day rather than here.
      final p = FieldPlanPresets.dilutingLineLoads();
      final m = FieldPlanPresets.manualized(p, alignSec: p.alignSec,
          placementSec: p.placementSec);
      expect(m.toJson(), p.toJson(),
          reason: 'manualizing an already-manual plan must be identity');
    });

    test('resolvedFor changes bleOn and NOTHING else', () {
      // The runner executes this rebuild, not the preset, so a step field
      // it forgets is dropped on every phone at once.
      final p = FieldPlanPresets.dilutingLineLoads();
      for (final order in [1, 4, 7]) {
        final r = p.resolvedFor(order);
        expect(r.toJson()..remove('steps'), p.toJson()..remove('steps'),
            reason: 'plan-level fields must survive resolving');
        expect(r.steps.length, p.steps.length);
        for (var i = 0; i < p.steps.length; i++) {
          final was = p.steps[i].toJson()..remove('bleOn');
          final now = r.steps[i].toJson()..remove('bleOn');
          expect(now, was, reason: 'step $i lost a field at order $order');
        }
        expect(r.steps.first.resetLinks, isTrue);
        expect(r.steps.first.resetSessions, isTrue);
        expect(r.steps.first.bleOn, order <= 2);
      }
    });

    test('round-trips through the JSON the phones launch from', () {
      final p = FieldPlanPresets.dilutingLineLoads();
      final back = FieldPlan.fromJson(p.toJson());
      expect(back.steps.length, p.steps.length);
      expect(back.steps.last.label, 'N=7 L=moderate t10');
      expect(back.steps.first.sendCount, 100);
      // The pasted JSON must carry the first run's one-time resets — a
      // phone launches from this JSON, not from the Dart object.
      expect(back.steps.first.resetSessions, isTrue);
      expect(back.steps.first.resetLinks, isTrue);
      expect(back.steps[1].resetLinks, isNull);
      expect(back.steps[10].label, 'N=3 L=moderate t1');
      expect(back.steps[10].resetLinks, isNull,
          reason: 'an N boundary resets nothing');
      expect(back.linkResetDarkSec, 10);
      expect(back.joinGapSec, 5);
    });
  });

  test('every testbed plan records every advertisement sighting', () {
    // The line sweep is the experiment this exists for — RSSI against
    // distance and beacon reception rate are its measurement — and it
    // reaches the dropdown through lineSweepUpTo(), which rebuilds the plan
    // field by field. A field dropped there runs the sweep under the
    // limiter, where the sighting count measures the limiter and not the
    // radio.
    expect(FieldPlanPresets.lineSweepUpTo().traceEveryAdvertisement, isTrue);
    expect(FieldPlanPresets.dilutingLineLoads().traceEveryAdvertisement,
        isTrue);
    for (final entry in FieldPlanPresets.presets.entries) {
      expect(entry.value.traceEveryAdvertisement, isTrue,
          reason: '${entry.key} would measure the rate limiter');
    }
    // It has to survive the two rebuilds a plan goes through on the way to a
    // phone, and be visible to equality so a test like this can see it.
    final p = FieldPlanPresets.dilutingLineLoads();
    expect(p.resolvedFor(3).traceEveryAdvertisement, isTrue);
    expect(FieldPlan.fromJson(p.toJson()).traceEveryAdvertisement, isTrue);
    expect(
        FieldPlanPresets.manualized(p,
                alignSec: p.alignSec, placementSec: p.placementSec)
            .traceEveryAdvertisement,
        isTrue);
    const off = FieldPlan(expId: 'x', steps: [FieldStep(label: 'a', dwellSec: 1)]);
    const on = FieldPlan(
        expId: 'x',
        steps: [FieldStep(label: 'a', dwellSec: 1)],
        traceEveryAdvertisement: true);
    expect(off == on, isFalse, reason: 'equality must see the flag');
  });

  group('desk smoke preset (same code path, shrunk schedule)', () {
    test('reps is a picker value: the count changes, nothing else does', () {
      // The screen picks runs-per-clique-size at launch. Everything that
      // defines the MEASUREMENT — load, payload, dwell, drain, resets, join
      // gap — has to be identical across counts, or a quick build check and
      // a noise-baseline run stop being the same experiment.
      final one = FieldPlanPresets.dilutingSmoke(reps: 1);
      final five = FieldPlanPresets.dilutingSmoke(reps: 5);
      expect(one.steps, hasLength(6), reason: 'N=2..7, one run each');
      expect(five.steps, hasLength(6 * 5));
      expect(one.steps.map((s) => s.sendCount).toSet(),
          five.steps.map((s) => s.sendCount).toSet());
      expect(one.steps.map((s) => s.dwellSec).toSet(),
          five.steps.map((s) => s.dwellSec).toSet());
      expect(one.expId, five.expId);
      expect(one.joinGapSec, five.joinGapSec);
      expect(one.gapAfterSec(one.steps.first),
          five.gapAfterSec(five.steps.first));
      // The one-time resets still ride the FIRST run and nothing else,
      // whatever the count.
      expect(one.steps.first.resetLinks, isTrue);
      expect(one.steps.first.resetSessions, isTrue);
      expect(one.steps.skip(1).every((s) => s.resetLinks == null), isTrue);
      expect(five.steps.skip(1).every((s) => s.resetLinks == null), isTrue);
      // Every clique size is still represented at reps=1.
      expect(one.steps.map((s) => s.cliqueN).toList(), [2, 3, 4, 5, 6, 7]);
    });

    test('the dropdown entry is the real builder at the default reps, '
        'field dwell', () {
      final smoke =
          FieldPlanPresets.presets[FieldPlanPresets.dilutingSmokePresetName]!;
      final full = FieldPlanPresets.dilutingLineLoads();
      expect(smoke.steps.map((s) => s.sendCount).toSet(),
          full.steps.map((s) => s.sendCount).toSet(),
          reason: 'same single arm');
      // Five runs per clique size by default: one or two cannot separate a
      // change from the run-to-run noise, which has reached ~7 points of
      // delivery between repeats of one unchanged build. The screen's
      // picker overrides it for a quick build check.
      expect(smoke.steps, hasLength(6 * 5), reason: 'default reps=5');
      // The dwell is the FIELD's: the same 100 per destination in a
      // shorter window is a heavier test, not a smaller one.
      expect(smoke.steps.map((s) => s.dwellSec).toSet(),
          full.steps.map((s) => s.dwellSec).toSet());
      expect(smoke.expId, isNot(full.expId),
          reason: 'a distinct id so a smoke run never collides with a '
              'field upload of the same name');
      expect(smoke.resetSessions, full.resetSessions);
      expect(smoke.resetLinks, full.resetLinks);
      expect(smoke.resetDtnBuffer, full.resetDtnBuffer);
      expect(smoke.gapAfterSec(smoke.steps.first),
          full.gapAfterSec(full.steps.first),
          reason: 'the drain is derived from the dwell, so it matches too');
      expect(smoke.placementSec, lessThan(full.placementSec),
          reason: 'nothing to walk to at a desk');
      expect(smoke.alignSec, 60,
          reason: 'starts on the next MINUTE, not the field\'s 5-minute '
              'boundary');
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
          reason: '12 distances x 10 runs');
    });

    test('every step is a cold run with the buffer cleared', () {
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

    test('only the first run at a distance waits for the operator', () {
      final p = FieldPlanPresets.lineSweep(distances: [50, 20], runs: 3);
      final flags = p.steps.map((s) => s.autoAdvance).toList();
      expect(flags, [false, true, true, false, true, true]);
    });

    test('the distance survives the JSON round-trip in the label', () {
      final p = FieldPlanPresets.lineSweep(distances: [30], runs: 1);
      final back = FieldPlan.fromJson(p.toJson());
      expect(back.steps.single.label, 'd=30 t1');
    });
  });

  group('lineSweepUpTo (reach and repeats chosen per outing)', () {
    test('reach sets the positions, repeats set the dwells at each', () {
      final plan = FieldPlanPresets.lineSweepUpTo(maxDistance: 40, runs: 2);
      expect(plan.steps.map((s) => s.label).toList(),
          ['d=10 t1', 'd=10 t2', 'd=20 t1', 'd=20 t2',
           'd=30 t1', 'd=30 t2', 'd=40 t1', 'd=40 t2']);
    });

    test('a sweep can start at 1 m — as close as the pickers go', () {
      // Every position the pickers produce is one a log-distance fit can
      // take, so nothing downstream needs a special case for the closest
      // one.
      final plan = FieldPlanPresets.lineSweepUpTo(
          startDistance: 1, maxDistance: 21, stepMetres: 10, runs: 1);
      expect(plan.steps.map((s) => s.label), ['d=1 t1', 'd=11 t1', 'd=21 t1']);

      // The label is what the analyser reads the distance out of, so it has
      // to survive the JSON the phones actually launch from.
      final back = FieldPlan.fromJson(plan.toJson());
      expect(back.steps.first.label, 'd=1 t1');
    });

    test('the sweep starts where the site allows, not always at 10 m', () {
      final plan = FieldPlanPresets.lineSweepUpTo(
          startDistance: 40, maxDistance: 60, runs: 1);
      expect(plan.steps.map((s) => s.label), ['d=40 t1', 'd=50 t1', 'd=60 t1']);
    });

    test('a single position is a whole plan, with nothing to walk to', () {
      // Testing the pipeline on a desk: launch, resets, establishment, sends
      // and upload all exercised, but no second position means no walk.
      final plan = FieldPlanPresets.lineSweepUpTo(
          startDistance: 1, maxDistance: 1, stepMetres: 5, runs: 3);
      expect(plan.steps.map((s) => s.label),
          ['d=1 t1', 'd=1 t2', 'd=1 t3']);
      expect(plan.steps.where((s) => !s.autoAdvance), hasLength(1),
          reason: 'only the first dwell is a position; nothing follows it');
    });

    test('any step spacing the ground calls for, not a fixed set', () {
      for (final step in [1, 3, 7, 250]) {
        final plan = FieldPlanPresets.lineSweepUpTo(
            startDistance: 1, maxDistance: 1 + step, stepMetres: step,
            runs: 1);
        expect(plan.steps.map((s) => s.label),
            ['d=1 t1', 'd=${1 + step} t1'],
            reason: 'step of $step m');
      }
    });

    test('the step size sets how finely the range is sampled', () {
      final coarse = FieldPlanPresets.lineSweepUpTo(
          maxDistance: 100, stepMetres: 50, runs: 1);
      expect(coarse.steps.map((s) => s.label), ['d=10 t1', 'd=60 t1']);

      final fine = FieldPlanPresets.lineSweepUpTo(
          startDistance: 10, maxDistance: 25, stepMetres: 5, runs: 1);
      expect(fine.steps.map((s) => s.label),
          ['d=10 t1', 'd=15 t1', 'd=20 t1', 'd=25 t1']);
    });

    test('a reach short of the start still yields the one position', () {
      // A sweep of a single distance is a legitimate ask; a plan with no
      // steps is not, and would launch into nothing.
      final plan = FieldPlanPresets.lineSweepUpTo(
          startDistance: 80, maxDistance: 20, runs: 2);
      expect(plan.steps.map((s) => s.label), ['d=80 t1', 'd=80 t2']);
    });

    test('a step that cannot advance does not hang the builder', () {
      final plan = FieldPlanPresets.lineSweepUpTo(
          startDistance: 10, maxDistance: 30, stepMetres: 0, runs: 1);
      expect(plan.steps.map((s) => s.label),
          ['d=10 t1', 'd=11 t1', 'd=12 t1'].followedBy(
              [for (var d = 13; d <= 30; d++) 'd=$d t1']));
    });

    test('only the first dwell at a position is somewhere to walk to', () {
      final plan = FieldPlanPresets.lineSweepUpTo(maxDistance: 30, runs: 3);
      final walkTo = plan.steps.where((s) => !s.autoAdvance).map((s) => s.label);
      expect(walkTo, ['d=10 t1', 'd=20 t1', 'd=30 t1']);
    });

    test('a longer reach or more repeats only ever costs more time', () {
      int mins(FieldPlan p) {
        final starts = FieldRunner.stepStarts(p, 0);
        final last = p.steps.last;
        return starts.last + (last.dwellSec + p.gapAfterSec(last)) * 1000;
      }
      final base = FieldPlanPresets.lineSweepUpTo(maxDistance: 60, runs: 3);
      expect(mins(FieldPlanPresets.lineSweepUpTo(maxDistance: 120, runs: 3)),
          greaterThan(mins(base)));
      expect(mins(FieldPlanPresets.lineSweepUpTo(maxDistance: 60, runs: 6)),
          greaterThan(mins(base)));
    });

    test('the thesis line design: 100 one-way sends and a stack reset per '
        'position', () {
      final plan = FieldPlanPresets.lineSweepUpTo(
          maxDistance: 20, runs: 2, receiverPrefix: '499F5C75');
      expect(plan.stackResetPerPosition, isTrue,
          reason: 'the operator cycles the whole stack at every position');
      expect(plan.steps.first.sendCount, 100,
          reason: '100 a run — 1000 a distance at x10, the July load');
      expect(plan.steps.first.sendTo, '499f5c75',
          reason: 'one-way: only phones whose target matches the prefix '
              'send; the receiver matches no target and sends nothing');

      // The flag survives the JSON the phones actually launch from.
      final back = FieldPlan.fromJson(plan.toJson());
      expect(back.stackResetPerPosition, isTrue);
      expect(back.steps.first.sendTo, '499f5c75');

      // Blank prefix keeps both phones sending.
      final both = FieldPlanPresets.lineSweepUpTo(maxDistance: 20, runs: 1);
      expect(both.steps.first.sendTo, 'all');
    });

    test('the dwell and the load are chosen per outing', () {
      final p = FieldPlanPresets.lineSweepUpTo(
          maxDistance: 20, runs: 2, dwellSec: 90, sendCount: 250);
      expect(p.steps.every((s) => s.dwellSec == 90), isTrue);
      expect(p.steps.every((s) => s.sendCount == 250), isTrue);

      // Untouched, the pickers still produce the thesis slate.
      final d = FieldPlanPresets.lineSweepUpTo(maxDistance: 20, runs: 2);
      expect(d.steps.first.dwellSec, 30);
      expect(d.steps.first.sendCount, 100);

      // A dwell too short to hold a reset, or a load of nothing, would make
      // a run that cannot measure what it claims to.
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
      expect(plan.steps, hasLength(120), reason: '12 distances x 10 runs');
      expect(plan.steps.every((s) => s.sendCount == 100), isTrue,
          reason: '100 a run, 1000 a distance, in each direction');
      expect(plan.steps.every((s) => s.sendTo == 'all'), isTrue,
          reason: 'both phones send unless a receiver prefix narrows it');
      expect(plan.stackResetPerPosition, isTrue);
      expect(plan.steps.last.label, 'd=120 t10');
    });
  });

  group('advertisementCapture (one scans, one advertises, nothing else '
      'on the radio)', () {
    test('twenty 30 s dwells, no send traffic, dialing fully capped', () {
      final p = FieldPlanPresets.advertisementCapture();
      expect(p.steps, hasLength(20));
      expect(p.steps.every((s) => s.dwellSec == 30), isTrue,
          reason: 'enough repeats to quote a spread on the rate, at the '
              'dwell the line sweep itself samples in');
      expect(p.steps.every((s) => s.sendCount == 0), isTrue,
          reason: 'no application traffic to seal or ACK — this measures '
              'raw ADV reception, nothing else on the radio');
      expect(p.steps.every((s) => s.maxParallelDials == 0), isTrue,
          reason: 'the dial cap is what stops a GATT link ever forming: '
              '0 in-flight dials already satisfies connectToDevice\'s own '
              '_inFlightCentralDials() >= maxInFlightCentralDials gate, '
              'unconditionally, on every step');
    });

    test('every dwell is cold: no per-step override, plan-level reset '
        'true throughout', () {
      final p = FieldPlanPresets.advertisementCapture();
      // Unlike a plan with a one-time bounce, there is no "first run only"
      // override here at all — every step inherits the plan-level default,
      // exactly like lineSweep's own steps do.
      expect(p.steps.every((s) => s.resetSessions == null), isTrue);
      expect(p.steps.every((s) => s.resetLinks == null), isTrue);
      expect(p.steps.every((s) => s.resetDtnBuffer == null), isTrue);
      expect(p.resetSessions, isTrue);
      expect(p.resetLinks, isTrue);
      expect(p.resetDtnBuffer, isTrue);
    });

    test('every bounce gets a reserved slot, like lineSweep\'s does', () {
      // Both phones bounce links simultaneously at every dwell (the same
      // identical plan on every device), so a short dark window is enough
      // and it must be RESERVED ahead of each step's own start — otherwise
      // the bounce (dark window + transport rebuild) runs inside the dwell
      // instead of ahead of it and silently shortens it.
      final p = FieldPlanPresets.advertisementCapture();
      expect(p.linkResetDarkSec, 10);
      expect(p.resetBudgetSec, 15,
          reason: 'must cover the dark window plus transport re-init, or '
              'a run opens late into its own dwell instead of at full '
              'length');
    });

    test('twenty 30 s dwells span about fourteen and three quarter '
        'wall-clock minutes', () {
      // A cold plan (resetLinks true) charges resetBudgetSec ahead of
      // EVERY step and derives no drain after any of them — gapAfterSec is
      // 0 once the plan's own resetLinks is true, because the following
      // step's own dark window is the settle. Each cap-tN marker's OWN
      // segment still ends cleanly at its own run-end, unaffected by the
      // reset that precedes the next one.
      final p = FieldPlanPresets.advertisementCapture();
      final starts = FieldRunner.stepStarts(p, 0);
      for (var i = 1; i < starts.length; i++) {
        expect(starts[i] - starts[i - 1], 45000,
            reason: '15s reserved reset + 30s dwell between every pair of '
                'steps');
      }
      final last = p.steps.last;
      final totalMs =
          starts.last + (last.dwellSec + p.gapAfterSec(last)) * 1000;
      expect(totalMs, 885000,
          reason: 'about 14 minutes 45 seconds of scheduled step time for '
              'twenty 30s dwells, each preceded by its own 15s reset slot');
    });

    test('only the first dwell waits for the operator', () {
      final p = FieldPlanPresets.advertisementCapture();
      expect(p.steps.first.autoAdvance, isFalse);
      expect(p.steps.skip(1).every((s) => s.autoAdvance), isTrue);
    });

    test('every sighting is traced, with none of the usual 900 ms throttle',
        () {
      final p = FieldPlanPresets.advertisementCapture();
      expect(p.traceEveryAdvertisement, isTrue);
    });

    test('runs on the wall-clock lattice, with a desk-sized placement '
        'window', () {
      // manualJoin is the ONE scheduling mode every plan runs under —
      // FieldRunner.start() refuses outright without it ('not a
      // wall-clock plan') — and it is what actually makes placementSec/
      // alignSec below mean anything. Short like the smoke test's:
      // both phones are stationary, so there is nothing to walk to and no
      // reason to wait most of a 10-minute boundary.
      final p = FieldPlanPresets.advertisementCapture();
      expect(p.manualJoin, isTrue);
      expect(p.placementSec, 20);
      expect(p.alignSec, 120,
          reason: 'both phones bounce before every step on their own '
              'lattice, so a one-window stagger puts the advertiser\'s '
              'dark windows inside the scanner\'s dwells — the wide '
              'boundary makes a tap-spread straddle unlikely');
    });

    test('the dropdown entry is the real builder, twenty labelled runs',
        () {
      final preset = FieldPlanPresets
          .presets[FieldPlanPresets.advertisementCapturePresetName]!;
      expect(preset.steps.map((s) => s.label).toList(),
          [for (var t = 1; t <= 20; t++) 'cap t$t']);
    });

    test('round-trips through the JSON the phones launch from', () {
      final p = FieldPlanPresets.advertisementCapture();
      final back = FieldPlan.fromJson(p.toJson());
      expect(back.steps.length, p.steps.length);
      expect(back.steps.first.maxParallelDials, 0);
      expect(back.steps.last.maxParallelDials, 0,
          reason: 'the cap applies to every step, not just the first');
      expect(back.resetLinks, isTrue);
      expect(back.resetSessions, isTrue);
      expect(back.resetDtnBuffer, isTrue);
      expect(back.steps.every((s) => s.resetLinks == null), isTrue,
          reason: 'every step inherits the plan-level reset; none override '
              'it individually');
      expect(back.traceEveryAdvertisement, isTrue);
    });
  });

  group('mtuCheck (both legs of a pair know their link\'s MTU)', () {
    test('every step is an independent convergence', () {
      final plan = FieldPlanPresets.mtuCheck();
      expect(plan.resetLinks, isTrue);
      expect(plan.steps.every((s) => s.resetLinks == null), isTrue,
          reason: 'No step opts out — the bounce is the point, and the MTU '
              'exchange only happens while a link is coming up.');
      expect(plan.linkResetDarkSec, 10);
      expect(plan.resetBudgetSec, greaterThan(15),
          reason: 'A budget that cuts a bounce short opens the step late '
              'into the dwell that is measuring the bounce.');
    });

    test('the load is bigger than an ANNOUNCE, which is the whole test', () {
      final plan = FieldPlanPresets.mtuCheck();
      expect(plan.steps.every((s) => s.sendBytes > 182), isTrue,
          reason: 'An ANNOUNCE is the largest thing a peripheral leg '
              'receives once control traffic is all that is written to it, '
              'so a leg that believes what it receives caps there. Only a '
              'bigger payload separates that leg from a correct one.');
      expect(plan.steps.every((s) => s.sendCount > 0), isTrue);
    });

    test('desk-sized lattice windows, and one operator tap', () {
      final plan = FieldPlanPresets.mtuCheck();
      expect(plan.manualJoin, isTrue);
      expect(plan.placementSec, 20);
      expect(plan.alignSec, 60);
      expect(plan.steps.first.autoAdvance, isFalse);
      expect(plan.steps.skip(1).every((s) => s.autoAdvance), isTrue);
    });

    test('the dropdown entry is the real builder, and survives the JSON', () {
      final entry = FieldPlanPresets.presets[FieldPlanPresets.mtuCheckPresetName];
      expect(entry, isNotNull);
      expect(entry!.expId, 'mtu-check${FieldPlanPresets.mtuCheckRun}');
      expect(entry.steps, hasLength(8));
      expect(FieldPlan.fromJson(entry.toJson()), entry);
    });
  });

  group('strict plan parsing', () {
    test('a typo\'d plan field is refused, not defaulted', () {
      final json = FieldPlanPresets.dilutingLineLoads().toJson();
      json['manualJoi'] = true; // the typo a field day cannot afford
      expect(() => FieldPlan.fromJson(json),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains("manualJoi"))));
    });

    test('a typo\'d step field is refused with the step named', () {
      final json = FieldPlanPresets.dilutingLineLoads().toJson();
      final step0 = (json['steps'] as List).first as Map<String, dynamic>;
      step0['dwelSec'] = 5;
      expect(() => FieldPlan.fromJson(json),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              allOf(contains("dwelSec"), contains('N=2')))));
    });
  });
  group('ringSweep', () {
    test('emits r=<radius> t<trial>, with trial counting per radius', () {
      final p = FieldPlanPresets.ringSweep(radii: const [1, 2], sweeps: 3);
      final labels = p.steps
          .where((s) => s.sendCount > 0)
          .map((s) => s.label)
          .toList();
      expect(labels, hasLength(6));
      // Each radius appears once per sweep, and its own trial counter runs
      // 1..sweeps independently of the interleaving.
      expect(labels.where((l) => l.startsWith('r=1 ')).toList(),
          ['r=1 t1', 'r=1 t2', 'r=1 t3']);
      expect(labels.where((l) => l.startsWith('r=2 ')).toList(),
          ['r=2 t1', 'r=2 t2', 'r=2 t3']);
    });

    test('every sweep is a permutation: each radius exactly once', () {
      final p = FieldPlanPresets.ringSweep(
          radii: const [1, 2, 3, 4, 5], sweeps: 10);
      final trials = p.steps.where((s) => s.sendCount > 0).toList();
      expect(trials, hasLength(50));
      for (var sweep = 0; sweep < 10; sweep++) {
        final window = trials.sublist(sweep * 5, sweep * 5 + 5);
        final radii = window.map((s) => s.ringRadius).toSet();
        expect(radii, {1, 2, 3, 4, 5},
            reason: 'sweep $sweep must visit every radius exactly once');
      }
    });

    test('radii default to 1..diameter of the declared ring', () {
      // Past the diameter every radius is the complete graph again, so a
      // sweep that kept r=1..5 at n=7 would spend two fifths of its trials
      // measuring the same topology.
      expect(FieldPlanPresets.ringSweep(n: 7).steps.map((s) => s.ringRadius).toSet(),
          {1, 2, 3});
      expect(FieldPlanPresets.ringSweep().steps.map((s) => s.ringRadius).toSet(),
          {1, 2, 3, 4, 5});
    });

    test('the label and the ringRadius field can never disagree', () {
      final p = FieldPlanPresets.ringSweep();
      for (final s in p.steps.where((s) => s.sendCount > 0)) {
        final parsed =
            int.parse(RegExp(r'^r=(\d+) ').firstMatch(s.label)!.group(1)!);
        expect(s.ringRadius, parsed, reason: s.label);
      }
    });

    test('no token precedes the r=, which would break the analyzer', () {
      // analyze.py splits labels on " r" for the power ladder's legacy repeat
      // convention, and its position regex would read a d= token here as a
      // line-sweep distance.
      for (final s in FieldPlanPresets.ringSweep().steps
          .where((s) => s.sendCount > 0)) {
        expect(s.label, startsWith('r='));
        expect(s.label, isNot(contains('d=')));
        expect(s.label, isNot(contains('side=')));
      }
    });

    test('windows are uniform across every radius — the bias test', () {
      final p = FieldPlanPresets.ringSweep();
      // A drain that varied with r would bake an r-dependent censoring bias
      // into the design: drain length is exactly what decides how much of the
      // multi-hop tail is counted.
      final trials = p.steps.where((s) => s.sendCount > 0);
      // Uniform is the requirement, not equal-to-dwell: a window that varied
      // with r would bake an r-dependent censoring bias into the design, and
      // the drain is exactly what decides how much of the multi-hop tail is
      // counted.
      final gaps = trials.map((s) => p.gapAfterSec(s)).toSet();
      expect(gaps, hasLength(1));
      // 300 s: the sync sweep moves one 106-id frame per 10 s round per
      // peer, and at N=11 and r=1 a trial's backlog needs most of that just
      // to be offered once at each hop.
      expect(gaps.single, 300, reason: 'drain is decoupled from the dwell');
      expect(trials.map((s) => s.dwellSec).toSet(), {100});
    });

    test('never cleans sessions, links or the DTN buffer', () {
      final p = FieldPlanPresets.ringSweep();
      // One purge and every later message to a non-neighbour fails at
      // creation — no session, no packet — and the run is dead from there.
      expect(p.resetSessions, isFalse);
      // Links bounce, but ONLY inside a settle. The plan-level flag fires at
      // the top of every step, which would tear the mesh down at the start of
      // each trial as well as before it.
      expect(p.resetLinks, isFalse);
      // The DTN buffer IS cleared every stage, so each trial's delivery is
      // decided inside its own window rather than by how much of its
      // successors' time it happened to borrow.
      expect(p.resetDtnBuffer, isTrue);
      expect(p.steps.every((s) => s.resetSessions != true), isTrue);
      // A trial never bounces; the settle before it does, so the rebuild
      // finishes before the dwell that measures the data plane begins.
      expect(
          p.steps
              .where((s) => s.sendCount > 0)
              .every((s) => s.resetLinks != true),
          isTrue);
      expect(p.steps.where((s) => s.settle).every((s) => s.resetLinks == true),
          isTrue);
      expect(p.steps.every((s) => s.resetDtnBuffer != false), isTrue);
      // Severing is still never used: a settle's bounce is a reconnecting
      // teardown the mesh comes back from, which is not the same act.
      expect(p.severLinks, isFalse);
      expect(p.steps.every((s) => s.severLinks != true), isTrue);
    });

    test('sends a total of perPair * (n-1), rotated so pairs share equally',
        () {
      final p = FieldPlanPresets.ringSweep(n: 11, perPair: 10);
      for (final s in p.steps.where((s) => s.sendCount > 0)) {
        // Per DESTINATION: one timer per session, each firing this many times.
        expect(s.sendCount, 10);
        expect(s.perPairPacing, isTrue);
        expect(s.sendTo, 'all');
        expect(s.sendBytes, 138);
      }
    });

    test('EVERY trial is preceded by a settle, and it carries no drain', () {
      final p = FieldPlanPresets.ringSweep(
          radii: const [1, 2, 3, 4, 5], sweeps: 6);
      var checked = 0;
      for (var i = 0; i < p.steps.length; i++) {
        final st = p.steps[i];
        if (st.sendCount == 0) continue; // a settle
        // Independence is the point: a trial that inherited the previous
        // one's mesh is a second sample of one trajectory, not a second draw.
        expect(i > 0 && p.steps[i - 1].settle, isTrue,
            reason: 'r=${st.ringRadius} must open on a mesh it built itself');
        expect(p.steps[i - 1].ringRadius, st.ringRadius,
            reason: 'the settle builds the topology its trial will measure');
        checked++;
      }
      expect(checked, greaterThan(20), reason: 'exercised many trials');
      // A settle is exactly settleSec long: it measures nothing, so it has no
      // tail in flight and carries no drain.
      for (final st in p.steps.where((s) => s.sendCount == 0)) {
        expect(st.settle, isTrue);
        // Long enough to contain the dark window, the reset budget and ~20 s
        // of convergence, with margin — not merely their sum.
        expect(st.dwellSec, 90);
        expect(p.gapAfterSec(st), 0);
      }
    });

    test('a settle stage is never read as a ring trial', () {
      // Its label carries no `r=` token, so the analyzer opens a segment for
      // it without counting it among the radii.
      for (final st in FieldPlanPresets.ringSweep().steps
          .where((s) => s.sendCount == 0)) {
        expect(st.label, startsWith('settle '));
        expect(st.label, isNot(contains('r=')));
      }
    });

    test('every trial starts on an empty buffer, so windows are comparable',
        () {
      // A trial's stragglers would otherwise keep being conveyed during the
      // NEXT trial, giving every trial but the last a bonus window made of its
      // successors' time — measured at 301 s versus 60 s in the 4-phone smoke.
      final p = FieldPlanPresets.ringSweep();
      expect(p.resetDtnBuffer, isTrue);
      // Sessions and links are still never touched: clearing the buffer must
      // not become clearing the run.
      expect(p.resetSessions, isFalse);
      expect(p.resetLinks, isFalse);
      expect(p.steps.every((s) => s.resetSessions != true), isTrue);
    });

    test('paces one message per pair per sync round', () {
      // 10 messages across a 100 s dwell is one per pair per 10 s, which is
      // exactly one ANNOUNCE/sync round — the quantum a carried packet moves
      // at. A pair offers the mesh one packet per opportunity to move it.
      final p = FieldPlanPresets.ringSweep();
      final t = p.steps.firstWhere((s) => s.sendCount > 0);
      expect(t.dwellSec / t.sendCount, 10.0);
    });

    test('declares its fleet size and carries no session floor', () {
      final p = FieldPlanPresets.ringSweep(n: 11);
      // The ring's size is declared once, as itself. It used to be read off
      // minSessionsToLaunch + 1, which put two meanings in one number: that
      // field is a floor ("at least this many"), so a plan using it as one was
      // refused for it and a plan leaving it at zero switched the ring check
      // off entirely.
      expect(p.ringSize, 11);
      expect(p.minSessionsToLaunch, 0,
          reason: 'a floor cannot say anything ringSize does not say better');
    });

    test('every preset that derives a ring declares a workable size', () {
      // The runner refuses a derive-without-size plan at launch, which is the
      // right place for a pasted one — but a preset author should find out
      // here rather than on a desk with the fleet warmed up.
      for (final entry in FieldPlanPresets.presets.entries) {
        if (!entry.value.ringRosterFromSessions) continue;
        expect(entry.value.ringSize, isNotNull, reason: entry.key);
        expect(entry.value.ringSize, greaterThanOrEqualTo(4),
            reason: '${entry.key}: below four every pair is adjacent');
      }
    });

    test('a derived ring without a size is refused at the parse', () {
      final json = FieldPlanPresets.ringSweep(radii: const [1], sweeps: 1)
          .toJson();
      json.remove('ringSize');
      expect(() => FieldPlan.fromJson(json), throwsFormatException);
    });

    test('the seed is reproducible and rides in the expId', () {
      final a = FieldPlanPresets.ringSweep(seed: 7);
      final b = FieldPlanPresets.ringSweep(seed: 7);
      final c = FieldPlanPresets.ringSweep(seed: 8);
      expect(a.steps.map((s) => s.label).toList(),
          b.steps.map((s) => s.label).toList());
      expect(a.steps.map((s) => s.ringRadius).toList(),
          isNot(c.steps.map((s) => s.ringRadius).toList()));
      expect(a.expId, contains('s7'));
    });

    test('survives the JSON round trip a phone actually launches from', () {
      final p = FieldPlanPresets.ringSweep(radii: const [1, 2], sweeps: 2);
      final revived = FieldPlan.fromJson(p.toJson());
      expect(revived, equals(p));
      expect(revived.steps.map((s) => s.ringRadius).toList(),
          p.steps.map((s) => s.ringRadius).toList());
      expect(revived.severLinks, isFalse);
      expect(revived.minSessionsToLaunch, p.minSessionsToLaunch);
    });

    test('resolvedFor does not drop the ring fields', () {
      // resolvedFor rebuilds every step field by field, and a field forgotten
      // there is dropped silently on EVERY phone. The ring plan has no
      // cliqueN, so it must pass through untouched.
      final p = FieldPlanPresets.ringSweep(radii: const [1, 2], sweeps: 1);
      expect(identical(p.resolvedFor(1), p), isTrue);

      // And when a plan DOES resolve, the ring fields still survive.
      final mixed = FieldPlan(
        expId: 'mixed',
        manualJoin: true,
        steps: const [
          FieldStep(
              label: 'r=1 t1',
              dwellSec: 10,
              cliqueN: 2,
              ringRadius: 1,
              severLinks: true,
              perPairPacing: true),
        ],
      );
      final resolved = mixed.resolvedFor(1).steps.single;
      expect(resolved.ringRadius, 1);
      expect(resolved.severLinks, isTrue);
      expect(resolved.perPairPacing, isTrue);
    });
  });

  group('ringSmoke', () {
    test('is a 10-ring over its two extreme radii', () {
      final p = FieldPlanPresets.ringSmoke();
      // The whole fleet, and the two topologies the contrast is between: the
      // bare ring at r=1, where a message four hops away must be conveyed,
      // and the complete graph at the diameter, where nothing needs a relay.
      expect(p.ringSize, 10);
      expect(p.steps.map((s) => s.ringRadius).toSet(), {1, 5});
      final trials = p.steps.where((s) => s.sendCount > 0).toList();
      expect(trials, hasLength(4));
      // Ten times the sweep's cadence: one message per pair per second, so the
      // ask window is measured while the seen-set outruns one filter.
      expect(trials.every((s) => s.sendCount == 100), isTrue);
    });

    test('sized for the room: radii are ring and full mesh for any n', () {
      // The contrast the smoke proves is ring against complete graph, and
      // the radius that completes an n-ring is its diameter n ~/ 2.
      final p = FieldPlanPresets.ringSmoke(n: 6);
      expect(p.ringSize, 6);
      expect(p.steps.map((s) => s.ringRadius).toSet(), {1, 3});
      expect(FieldPlanPresets.ringSmokeDesk(n: 6).ringSize, 6);
      // Four is the smallest ring the contrast means anything on: on a
      // 3-ring every pair is already at distance 1, so r=1 is complete and
      // no message can require a relay.
      final four = FieldPlanPresets.ringSmoke(n: 4);
      expect(four.ringSize, 4);
      expect(four.steps.map((s) => s.ringRadius).toSet(), {1, 2});
    });

    test('the desk variant carries no roster at all', () {
      // It used to carry the desk fleet's four pubkeys. They were dead twice
      // over — the derived ring decides both the topology and the send targets
      // — so all they did was ride into the plan JSON and every trace naming a
      // fleet that was not the one running, and one entry had already gone
      // stale. The room says who is in the ring; the plan says only how many.
      final p = FieldPlanPresets.ringSmokeDesk();
      expect(p.roster, isEmpty);
      expect(p.ringRosterFromSessions, isTrue);
      expect(p.ringSize, 10);
      expect(p.expId, contains('ring-smoke'));
    });

    test('uses desk-sized lattice windows, not the field-day defaults', () {
      // FieldPlan defaults are 300/600, sized for carrying phones to
      // positions. Inheriting them would add a quarter of an hour of standing
      // around to a twelve-minute desk run.
      final p = FieldPlanPresets.ringSmoke();
      expect(p.placementSec, 60);
      // Wider than placement, and that gap is the point: a tap spread may be
      // at most `alignSec - placementSec` and still land on one anchor, so
      // equal values leave no guarantee at all.
      expect(p.alignSec, 180);
      expect(p.alignSec - p.placementSec, greaterThanOrEqualTo(120));
    });

    test('drains far longer than it sends, because conveyance is slow', () {
      final p = FieldPlanPresets.ringSmoke();
      // Every MEASURED trial: identical dwell and identical drain. The settle
      // stages are excluded because they send nothing and so carry no drain —
      // they are not windows the analysis reads.
      //
      // The drain is three times the dwell. At the sweep's cadence relayed
      // mail drained inside 120 s; at ten times that load the tail is the
      // measurement, and a drain that cuts it off reports slow mail as lost.
      final trials = p.steps.where((s) => s.sendCount > 0);
      expect(trials.map((s) => p.gapAfterSec(s)).toSet(), {300});
      expect(trials.map((s) => s.dwellSec).toSet(), {100});
    });
  });

  group('BLE throughput presets', () {
    List<String> labels(FieldPlan p) => [for (final s in p.steps) s.label];

    test('the sender saturates and the receiver sends nothing', () {
      // A step's sends otherwise target every known peer, so a receiver
      // running the sender's plan would push back down the link under test
      // and the measurement would be of two directions at once.
      final tx = FieldPlanPresets.bleThroughput();
      final rx = FieldPlanPresets.bleThroughput(saturating: false);
      expect(tx.steps.every((s) => s.saturate), isTrue);
      expect(rx.steps.every((s) => !s.saturate), isTrue);
      expect(rx.steps.every((s) => s.sendCount == 0), isTrue);
      expect(labels(rx), labels(tx),
          reason: 'The two phones must segment identically on the server.');
    });

    test('three arms, ten trials each, interleaved not blocked', () {
      final p = FieldPlanPresets.bleThroughput();
      expect(p.steps, hasLength(30));
      for (final arm in ['p=138B lanes=1', 'p=138B lanes=2', 'p=1380B lanes=1']) {
        expect(labels(p).where((l) => l.startsWith('$arm t')), hasLength(10),
            reason: '$arm must run ten times');
      }
      // Blocked would run all five of one arm before the next; interleaved
      // visits every arm once per sweep, so no arm owns a contiguous third of
      // the run and thermal drift is spread across all three.
      final firstThree = labels(p).take(3).map((l) => l.split(' t').first);
      expect(firstThree.toSet(), hasLength(3));
    });

    test('links and sessions stay warm; the DTN buffer does not', () {
      // This measures the data plane, not establishment. But a write refused
      // in one step is buffered and conveyed by a sync round inside the next,
      // where it would be counted.
      final p = FieldPlanPresets.bleThroughput();
      expect(p.resetSessions, isFalse);
      expect(p.resetLinks, isFalse);
      expect(p.steps.every((s) => s.resetDtnBuffer == true), isTrue);
    });

    test('the interval arm runs arm A alone and says so in the label', () {
      final p = FieldPlanPresets.bleThroughput(
          expId: 'ble-tp-hi-1', arms: const [0], connectionPriorityHigh: true);
      expect(p.connectionPriorityHigh, isTrue);
      expect(p.steps, hasLength(10));
      expect(labels(p).every((l) => l.contains('prio=high')), isTrue);
      expect(labels(p).every((l) => l.startsWith('p=138B lanes=1')), isTrue);
    });

    test('the priority field round-trips through JSON', () {
      final p = FieldPlanPresets.bleThroughput(connectionPriorityHigh: true);
      expect(FieldPlan.fromJson(p.toJson()).connectionPriorityHigh, isTrue);
      // Absent means "leave the interval alone", which is not the same as
      // false — a plan that asked for BALANCED would fight the other launch.
      final plain = FieldPlanPresets.bleThroughput();
      expect(plain.toJson().containsKey('connectionPriorityHigh'), isFalse);
      expect(FieldPlan.fromJson(plain.toJson()).connectionPriorityHigh, isNull);
    });

    test('saturate and sendLanes survive a JSON round-trip', () {
      final p = FieldPlanPresets.bleThroughput();
      final back = FieldPlan.fromJson(p.toJson());
      expect(back.steps, p.steps);
      expect(back.steps.where((s) => s.sendLanes == 2), hasLength(10));
    });
  });

  group('BLE goodput ceiling preset', () {
    List<String> labels(FieldPlan p) => [for (final s in p.steps) s.label];

    test('every payload runs paced and unpaced, in the same run', () {
      // The control has to sit beside its own arm. Comparing an unpaced run
      // against a previous paced one would fold a day of drift into the
      // difference the run exists to measure.
      final p = FieldPlanPresets.bleGoodputCeiling();
      for (final bytes in const [138, 1380, 4140, 13800]) {
        expect(labels(p).where((l) => l.startsWith('p=${bytes}B lanes=1 pace=0 ')),
            hasLength(5), reason: '$bytes B unpaced must run five times');
        expect(labels(p).where((l) => l.startsWith('p=${bytes}B lanes=1 pace=20 ')),
            hasLength(5), reason: '$bytes B paced must run five times');
      }
      expect(p.steps, hasLength(40));
    });

    test('only the unpaced arm zeroes the spacing; the control leaves it', () {
      // Null is not zero: null restores production, which is what makes the
      // control a control.
      final p = FieldPlanPresets.bleGoodputCeiling();
      for (final s in p.steps) {
        expect(s.fragmentDelayMs, s.label.contains('pace=0') ? 0 : isNull);
      }
    });

    test('one lane throughout — the lane question is closed', () {
      // Two lanes carried no more than one and produced a single write-busy
      // refusal in an hour. Sweeping lanes again would spend a run to
      // reproduce that.
      final p = FieldPlanPresets.bleGoodputCeiling();
      expect(p.steps.every((s) => s.sendLanes == 1), isTrue);
    });

    test('the advertised duration matches the plan it builds', () {
      // A preset's name is what an operator budgets battery and an evening
      // against. This one shipped saying ~50m and ran 83 — eight arms times
      // five sweeps is forty steps, not twenty.
      final p = FieldPlanPresets.bleGoodputCeiling();
      final secs = p.steps.fold<int>(0, (a, s) => a + s.dwellSec) +
          (p.drainSec ?? 0) * p.steps.length +
          p.placementSec +
          p.alignSec;
      expect((secs / 60).round(), 83);
      expect(FieldPlanPresets.bleCeilingSenderPresetName, contains('~83m'));
    });

    test('the tap tolerance is two minutes, not one', () {
      // alignSec is the anchor granularity: an anchor rounds up to the next
      // multiple of it. At 60 s two phones must tap inside one wall-clock
      // minute, and a smoke run was lost to taps either side of a boundary.
      expect(FieldPlanPresets.bleGoodputCeiling().alignSec, 120);
    });

    test('the receiver sends nothing but segments identically', () {
      final tx = FieldPlanPresets.bleGoodputCeiling();
      final rx = FieldPlanPresets.bleGoodputCeiling(saturating: false);
      expect(rx.steps.every((s) => !s.saturate && s.sendCount == 0), isTrue);
      expect(labels(rx), labels(tx));
    });

    test('the step fields survive a JSON round-trip', () {
      final p = FieldPlanPresets.bleGoodputCeiling();
      expect(FieldPlan.fromJson(p.toJson()).steps, p.steps);
    });
  });

  group('BLE one-way ceiling preset', () {
    test('the receiver never acknowledges, so the link carries one direction',
        () {
      // Every acknowledgement is a packet back down the same radio. A duplex
      // run reports duplex capacity as if it were simplex.
      final p = FieldPlanPresets.bleOneWayCeiling();
      expect(p.suppressAcks, isTrue);
      expect(FieldPlan.fromJson(p.toJson()).suppressAcks, isTrue);
    });

    test('the run silences everything that is not payload', () {
      // Advertising, scanning, ANNOUNCE and the DTN buffer all spend the same
      // radio and the same controller. A ceiling measured with them running
      // is a ceiling on the protocol, not on the link.
      final p = FieldPlanPresets.bleOneWayCeiling();
      expect(p.quietLink, isTrue);
      expect(FieldPlan.fromJson(p.toJson()).quietLink, isTrue);
    });

    test('quiet is never the default — it disables discovery', () {
      // A phone left quiet cannot find anyone again, so only a run may ask.
      expect(FieldPlanPresets.bleGoodputCeiling().quietLink, isFalse);
      expect(FieldPlanPresets.bleThroughput().quietLink, isFalse);
      expect(FieldPlanPresets.ringSweep().quietLink, isFalse);
    });

    test('acknowledging stays the default everywhere else', () {
      expect(FieldPlanPresets.bleGoodputCeiling().suppressAcks, isFalse);
      expect(FieldPlanPresets.bleThroughput().suppressAcks, isFalse);
    });

    test('spacing off throughout, and payloads start where the last run '
        'stopped climbing', () {
      final p = FieldPlanPresets.bleOneWayCeiling();
      expect(p.steps.every((s) => s.fragmentDelayMs == 0), isTrue);
      final sizes = p.steps.map((s) => s.sendBytes).toSet();
      expect(sizes, {1380, 4140, 13800, 27600, 55200});
      expect(p.steps, hasLength(20));
    });

    test('the advertised duration matches the plan', () {
      final p = FieldPlanPresets.bleOneWayCeiling();
      final secs = p.steps.fold<int>(0, (a, s) => a + s.dwellSec) +
          (p.drainSec ?? 0) * p.steps.length + p.placementSec + p.alignSec;
      expect((secs / 60).round(), 33);
      expect(FieldPlanPresets.bleOneWaySenderPresetName, contains('~33m'));
    });
  });
}
