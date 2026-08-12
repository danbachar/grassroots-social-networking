import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/protocol/fragment_handler.dart';
import 'package:grassroots_networking/src/testbed/field_plan_presets.dart';
import 'package:grassroots_networking/src/testbed/testbed_config.dart';

void main() {
  group('storeCarryForward', () {
    test('the traveller goes dark and never sends; senders address IT', () {
      final traveller =
          FieldPlanPresets.storeCarryForward(role: 1, travellerPrefix: 'abcd1234');
      final sender =
          FieldPlanPresets.storeCarryForward(role: 2, travellerPrefix: 'abcd1234');

      final dark = traveller.steps.where((s) => s.label.startsWith('dark'));
      expect(dark, isNotEmpty);
      for (final s in dark) {
        expect(s.bleOn, isFalse, reason: 'the traveller is the one that leaves');
        expect(s.sendCount, 0);
        expect(s.saturate, isFalse);
      }

      for (final s in sender.steps.where((s) => s.label.startsWith('dark'))) {
        expect(s.bleOn, isTrue);
        expect(s.sendTo, 'abcd1234',
            reason: 'a prefix concentrates the load on the absent phone');
      }

      // Empty prefix is the desk default: address everyone, one member away.
      final broad = FieldPlanPresets.storeCarryForward(role: 2);
      for (final s in broad.steps.where((s) => s.label.startsWith('dark'))) {
        expect(s.sendTo, 'all');
      }
    });

    test('the high arm is the field-day setting exactly', () {
      // mesh-scale-30m-2 ran saturate + ONE lane at 132 B; the desk arm has to
      // match it or the two results are not comparable.
      final sender = FieldPlanPresets.storeCarryForward(role: 2);
      final high =
          sender.steps.firstWhere((s) => s.label == 'dark high');
      expect(high.saturate, isTrue);
      expect(high.sendLanes, 1);
      expect(high.sendBytes, defaultSendBytes);

      final low = sender.steps.firstWhere((s) => s.label == 'dark low');
      final medium = sender.steps.firstWhere((s) => s.label == 'dark medium');
      expect(low.saturate, isFalse);
      expect(medium.saturate, isFalse);
      expect(low.sendCount, lessThan(medium.sendCount),
          reason: 'the arms must actually differ in offered load');
    });

    test('nobody sends during the return window', () {
      // Otherwise a delivery there could have come off the wire instead of
      // out of a buffer, and the measurement means nothing.
      for (final role in [1, 2, 3]) {
        final plan = FieldPlanPresets.storeCarryForward(role: role);
        for (final s in plan.steps.where((s) => s.label.startsWith('return'))) {
          expect(s.sendCount, 0);
          expect(s.saturate, isFalse);
          expect(s.bleOn, isTrue, reason: 'the traveller must come back');
        }
      }
    });

    test('each arm clears the buffer at warm, and nowhere else', () {
      // Carrying the backlog across dark->return IS the experiment, so the
      // plan-level flag must stay off; but an arm that inherits the previous
      // arm's undelivered packets scores them as its own deliveries. The only
      // safe boundary is the arm's first step.
      final plan = FieldPlanPresets.storeCarryForward(role: 2);
      expect(plan.resetDtnBuffer, isFalse,
          reason: 'plan-level would fire on every step, wiping the backlog');
      for (final s in plan.steps) {
        expect(s.resetDtnBuffer, s.label.startsWith('warm') ? isTrue : isNull,
            reason: 'only warm clears: ${s.label}');
      }
      // Sessions and links are deliberately NOT reset — the arm starts warm.
      expect(plan.resetSessions, isFalse);
      expect(plan.resetLinks, isFalse);
      expect(FieldPlan.fromJson(plan.toJson()), plan,
          reason: 'the override has to survive the JSON the phones load');
    });

    test('the relay cap is ON unless a plan explicitly lifts it', () {
      // The cap is a charter requirement, so the default must never drift to
      // off; lifting it is an arm you opt into, and it has to survive the
      // JSON the phones actually load or the run silently keeps the cap.
      expect(FieldPlanPresets.storeCarryForward(role: 2).relayBudgetDisabled,
          isFalse,
          reason: 'the builder default stays capped; lifting is per-plan');
      // The shipped nocap arm runs UNCAPPED, deliberately; its twin does not.
      expect(
          FieldPlanPresets
              .presets['SCF nocap — sender (1 rep, ~17 min)']!
              .relayBudgetDisabled,
          isTrue);
      expect(
          FieldPlanPresets
              .presets['SCF cap — sender (1 rep, ~17 min)']!
              .relayBudgetDisabled,
          isFalse);
      final lifted = FieldPlanPresets.storeCarryForward(
          role: 2, relayBudgetDisabled: true);
      expect(lifted.relayBudgetDisabled, isTrue);
      expect(lifted.toJson()['relayBudgetDisabled'], isTrue);
      expect(FieldPlan.fromJson(lifted.toJson()).relayBudgetDisabled, isTrue);
      expect(FieldPlan.fromJson(lifted.toJson()), lifted);
    });

    test('anchored to a 5-minute grid, with the runner working the radio', () {
      // The dark window has to open on every phone at the same instant, and
      // nobody is standing at the desk to toggle six radios at that instant.
      // Those are separate needs: manualJoin gives the shared anchor,
      // scriptedRadio keeps the toggling with the runner.
      final plan = FieldPlanPresets.storeCarryForward(role: 1);
      expect(plan.manualJoin, isTrue);
      expect(plan.alignSec, 300);
      expect(plan.scriptedRadio, isTrue,
          reason: 'hands-free is the point of a desk run');
      expect(plan.toJson()['scriptedRadio'], isTrue,
          reason: 'it has to survive the JSON the phones actually load');
      expect(FieldPlan.fromJson(plan.toJson()).scriptedRadio, isTrue);
    });

    test('the dropdown entries run 10 reps of every arm, windows unchanged', () {
      // The arms must differ only in offered load, so each keeps the same
      // wall-clock exposure; and one rep per arm is an anecdote, not a
      // distribution.
      final plan =
          FieldPlanPresets.presets['SCF desk — sender (everyone else)']!;
      expect(plan.steps, hasLength(3 * 10 * 3));
      for (final arm in ['low', 'medium', 'high']) {
        expect(plan.steps.where((s) => s.label == 'dark $arm t1'), hasLength(1));
        expect(plan.steps.where((s) => s.label == 'dark $arm t10'), hasLength(1));
      }
      final darks = plan.steps.where((s) => s.label.startsWith('dark'));
      expect(darks.map((s) => s.dwellSec).toSet(), {120},
          reason: 'every arm gets the same window');
      expect(plan.steps.where((s) => s.label.startsWith('warm'))
          .map((s) => s.dwellSec).toSet(), {60});
    });

    test('the A/B pair differs ONLY in the relay cap', () {
      // The whole point of a pair is that one variable moves. If anything
      // else differs the two traces are not comparable and the run is wasted.
      final capped = FieldPlanPresets.presets['SCF cap — sender (1 rep, ~17 min)']!;
      final nocap = FieldPlanPresets.presets['SCF nocap — sender (1 rep, ~17 min)']!;
      expect(capped.relayBudgetDisabled, isFalse);
      expect(nocap.relayBudgetDisabled, isTrue);
      expect(capped.expId, isNot(nocap.expId),
          reason: 'separate ids or the two runs merge into one file');
      expect(capped.steps.map((s) => s.label).toList(),
          nocap.steps.map((s) => s.label).toList());
      expect(capped.steps.map((s) => s.dwellSec).toList(),
          nocap.steps.map((s) => s.dwellSec).toList());
      expect(capped.steps.map((s) => s.saturate).toList(),
          nocap.steps.map((s) => s.saturate).toList());
      expect(capped.alignSec, nocap.alignSec);
      expect(capped.scriptedRadio, nocap.scriptedRadio);
      // Exactly one traveller preset per arm, and it is the one that goes dark.
      for (final arm in ['cap', 'nocap']) {
        final t = FieldPlanPresets.presets['SCF $arm — TRAVELLER (1 rep, ~17 min)']!;
        expect(t.steps.firstWhere((s) => s.label.startsWith('dark')).bleOn,
            isFalse);
      }
    });

    test('both dropdown entries exist and differ in who goes dark', () {
      final measured =
          FieldPlanPresets.presets.keys.where((k) => k.startsWith('SCF desk'));
      final checks = FieldPlanPresets.presets.keys
          .where((k) => k.startsWith('SCF cap') || k.startsWith('SCF nocap'));
      expect(measured, hasLength(2));
      expect(checks, hasLength(4),
          reason: 'the A/B pair ships beside the measured run: a traveller '
              'and a sender for each arm');
      final traveller =
          FieldPlanPresets.presets['SCF desk — TRAVELLER (this phone goes dark)']!;
      final sender =
          FieldPlanPresets.presets['SCF desk — sender (everyone else)']!;
      expect(traveller.steps.firstWhere((s) => s.label == 'dark low t1').bleOn,
          isFalse);
      expect(sender.steps.firstWhere((s) => s.label == 'dark low t1').bleOn,
          isTrue);
    });

    test('all three arms are present, warm-dark-return each', () {
      final plan = FieldPlanPresets.storeCarryForward(role: 2);
      expect(plan.steps.map((s) => s.label).toList(), [
        'warm low', 'dark low', 'return low',
        'warm medium', 'dark medium', 'return medium',
        'warm high', 'dark high', 'return high',
      ]);
      // Carrying the backlog across the dark step IS the experiment.
      expect(plan.resetDtnBuffer, isFalse);
    });
  });

  group('loadSweep', () {
    test('the send rate is per destination and does not move with n', () {
      // Each scheduled send fans out to every peer, so this count is the rate
      // TO EACH destination: 1/s with six peers is six messages a second on
      // the air, 1/s with one peer is one. What the sweep holds fixed is the
      // rate itself; the fleet total rising with n is the measurement, not a
      // confound to divide away. The old form divided by (n-1) — the wrong
      // quantity, and computed from a target count the plan only assumed.
      for (final rate in [1, 5, 10, 20]) {
        for (final n in [2, 4, 7]) {
          final plan = FieldPlanPresets.loadSweep(
              role: 1, nRange: [n], rates: [rate], repeat: 1, dwellSec: 60);
          final step = plan.steps.single;
          expect(step.sendCount / step.dwellSec, closeTo(rate.toDouble(), 1e-9),
              reason: 'n=\$n sent \${step.sendCount / step.dwellSec}/s to '
                  'each peer, wanted \$rate');
        }
      }
    });

    test('rate 0 means saturate, and only participants send', () {
      final plan = FieldPlanPresets.loadSweep(
          role: 5, nRange: [2, 7], rates: [0], repeat: 1, dwellSec: 30);
      final small = plan.steps.firstWhere((s) => s.label.startsWith('n=2'));
      final big = plan.steps.firstWhere((s) => s.label.startsWith('n=7'));
      // #5 is not in an n=2 mesh: radio down, sends nothing.
      expect(small.bleOn, isFalse);
      expect(small.saturate, isFalse);
      expect(small.sendCount, 0);
      // In an n=7 mesh it participates and saturates.
      expect(big.bleOn, isTrue);
      expect(big.saturate, isTrue);
    });

    test('each cell starts from an empty buffer, links and sessions warm', () {
      final plan = FieldPlanPresets.loadSweep(
          role: 1, nRange: [3], rates: [1, 5], repeat: 3, dwellSec: 30);
      expect(plan.steps, hasLength(6));
      for (final s in plan.steps) {
        expect(s.resetDtnBuffer, s.label.endsWith('t1') ? isTrue : isFalse,
            reason: 'only the first rep of a cell clears: \${s.label}');
      }
      expect(plan.resetSessions, isFalse);
      expect(plan.resetLinks, isFalse);
    });

    test('the shipped sweep is 300 cells across seven device orders', () {
      final entries = FieldPlanPresets.presets.keys
          .where((k) => k.startsWith('Load sweep'));
      expect(entries, hasLength(7));
      final plan = FieldPlanPresets.presets[entries.first]!;
      expect(plan.steps, hasLength(6 * 5 * 10));
      expect(plan.steps.map((s) => s.dwellSec).toSet(), {30});
    });
  });

  group('FieldPlanPresets', () {
    test('home soak: one long rosterless dwell with sends', () {
      final p = FieldPlanPresets.homeSoak(dwellMin: 40, sends: 40);
      expect(p.roster, isEmpty);
      expect(p.steps, hasLength(1));
      expect(p.steps.single.dwellSec, 40 * 60);
      expect(p.steps.single.sendCount, 40);
      expect(FieldPlan.fromJson(p.toJson()), p);
    });




    test('repeat expands each step into N uniquely-labelled trials', () {
      final soak = FieldPlanPresets.homeSoak(dwellMin: 1, sends: 2, repeat: 3);
      expect(soak.steps.map((s) => s.label),
          ['c1 d=3 soak', 'c2 d=3 soak', 'c3 d=3 soak']);
      expect(soak.steps.map((s) => s.label).toSet(), hasLength(3),
          reason: 'labels unique so the analyzer keeps each trial separate');

    });

    test('cycleCheck: tap the first, auto-advance the other four', () {
      final p = FieldPlanPresets.cycleCheck();
      expect(p.steps, hasLength(5));
      expect(p.resetLinks, isTrue);
      expect(p.resetSessions, isTrue);
      // All at d=3: only the first waits for the tap.
      expect(p.steps.map((s) => s.autoAdvance),
          [false, true, true, true, true]);
      expect(p.steps.map((s) => s.label).toSet(), hasLength(5));
      expect(FieldPlan.fromJson(p.toJson()), p);
    });


    test('throughput lanes survive the round-trip', () {
      final p = FieldPlanPresets.throughput(sendLanes: 8);
      expect(p.steps.single.saturate, isTrue);
      expect(p.steps.single.sendLanes, 8);
      expect(FieldPlan.fromJson(p.toJson()), p);
    });

    test('ceiling sweep: one step per lane count, count in the label', () {
      final p = FieldPlanPresets.throughputCeiling(lanes: const [1, 8, 32]);
      expect(p.steps.map((s) => s.sendLanes), [1, 8, 32]);
      expect(p.steps.map((s) => s.label), ['lanes=1', 'lanes=8', 'lanes=32']);
      expect(p.steps.every((s) => s.saturate), isTrue);
      expect(p.steps.every((s) => s.sendBytes == defaultSendBytes), isTrue,
          reason: 'fixed payload — lanes must be the only variable');
      // Stationary: one tap for the whole sweep.
      expect(p.steps.map((s) => s.autoAdvance), [false, true, true]);
      expect(p.settleSec, greaterThanOrEqualTo(90),
          reason: 'an overrun leaves a backlog still draining at dwell end');
      expect(FieldPlan.fromJson(p.toJson()), p);
    });

    test('ceiling sweep: empty lane list falls back to a single lane', () {
      expect(FieldPlanPresets.throughputCeiling(lanes: const [])
          .steps.single.sendLanes, 1);
    });

    test('throughput: saturating steps, warm sessions, repeats auto-advance',
        () {
      final p = FieldPlanPresets.throughput(repeat: 3, sendLanes: 4);
      expect(p.steps, hasLength(3));
      expect(p.steps.every((s) => s.saturate), isTrue);
      expect(p.steps.every((s) => s.sendLanes == 4), isTrue);
      expect(p.steps.every((s) => s.sendBytes == defaultSendBytes), isTrue,
          reason: 'one sealed packet per message unless asked otherwise');
      expect(p.resetSessions, isFalse, reason: 'data plane, not establishment');
      expect(p.resetLinks, isFalse);
      expect(p.steps.map((s) => s.autoAdvance), [false, true, true]);
      expect(FieldPlan.fromJson(p.toJson()), p);
    });

    test('throughput payload arm: one step per size, size in the label', () {
      final p = FieldPlanPresets.throughput(payloadSizes: const [132, 1200]);
      expect(p.steps.map((s) => s.sendBytes), [132, 1200]);
      expect(p.steps.map((s) => s.label), ['p=132B', 'p=1200B']);
      // Stationary: one tap for the whole arm.
      expect(p.steps.map((s) => s.autoAdvance), [false, true]);
      expect(FieldPlan.fromJson(p.toJson()), p,
          reason: 'a saturating step carries no sendCount — its payload size '
              'must still survive the round-trip, it IS the arm variable');
    });

    test('throughput payload arm x repeat: sizes outer, trials inner', () {
      final p = FieldPlanPresets.throughput(
          payloadSizes: const [132, 264], repeat: 2);
      expect(p.steps.map((s) => s.label),
          ['p=132B t1', 'p=132B t2', 'p=264B t1', 'p=264B t2']);
      expect(p.steps.map((s) => s.sendBytes), [132, 132, 264, 264]);
      expect(p.steps.map((s) => s.autoAdvance), [false, true, true, true]);
    });

    test('empty payload list falls back to the one-packet default', () {
      final p = FieldPlanPresets.throughput(payloadSizes: const []);
      expect(p.steps.single.sendBytes, defaultSendBytes);
    });

    test('the default send size is exactly one sealed packet', () {
      expect(defaultSendBytes, FragmentHandler.fragmentThreshold);
      expect(FragmentHandler().needsFragmentation(Uint8List(defaultSendBytes)),
          isFalse);
      expect(
          FragmentHandler().needsFragmentation(Uint8List(defaultSendBytes + 1)),
          isTrue);
      // Every plan builder inherits it.
      expect(FieldPlanPresets.homeSoak().steps.single.sendBytes,
          defaultSendBytes);
    });





    test('all named presets parse back and are non-empty', () {
      for (final entry in FieldPlanPresets.presets.entries) {
        expect(entry.value.steps, isNotEmpty, reason: entry.key);
        expect(FieldPlan.fromJson(entry.value.toJson()), entry.value);
      }
    });
  });

  group('FieldPlanWizard', () {
    test('build routes to the right shape and trims the id', () {
      final soak = FieldPlanWizard.build(
          kind: FieldPlanKind.homeSoak, expId: '  s1  ', dwellMin: 10);
      expect(soak.expId, 's1');
      expect(soak.steps.single.dwellSec, 600);

    });

    test('empty id falls back to "exp"', () {
      final p = FieldPlanWizard.build(kind: FieldPlanKind.homeSoak, expId: '   ');
      expect(p.expId, 'exp');
    });

    test('reset toggles: null uses kind defaults, explicit overrides', () {
      // Defaults: soak (sess on, links off); throughput (both off).
      expect(FieldPlanWizard.resetDefaults(FieldPlanKind.homeSoak), (true, false));
      expect(FieldPlanWizard.resetDefaults(FieldPlanKind.throughput),
          (false, false));

      final def = FieldPlanWizard.build(kind: FieldPlanKind.homeSoak, expId: 'a');
      expect((def.resetSessions, def.resetLinks), (true, false));

      final forced = FieldPlanWizard.build(
          kind: FieldPlanKind.homeSoak,
          expId: 'a',
          resetLinks: true,
          resetSessions: false);
      expect((forced.resetSessions, forced.resetLinks), (false, true));
    });

    test('wizard repeat threads through', () {
      final p = FieldPlanWizard.build(
          kind: FieldPlanKind.homeSoak, expId: 'a', dwellMin: 1, repeat: 4);
      expect(p.steps, hasLength(4));
    });

    test('reset toggles reach the throughput kinds (they were dropped)', () {
      final p = FieldPlanWizard.build(
          kind: FieldPlanKind.throughputCeiling,
          expId: 'c',
          resetSessions: true,
          resetLinks: true);
      expect((p.resetSessions, p.resetLinks), (true, true),
          reason: 'a wizard switch the JSON ignores is a lying UI');
      final t = FieldPlanWizard.build(
          kind: FieldPlanKind.throughput, expId: 't', resetLinks: true);
      expect(t.resetLinks, isTrue);
    });

    test('DTN buffer resets per step by default; mesh kinds keep it', () {
      // Measurement plans: an overrun step's backlog must not drain into the
      // next step's window.
      expect(FieldPlanPresets.throughputCeiling().resetDtnBuffer, isTrue);
      expect(FieldPlanPresets.throughput().resetDtnBuffer, isTrue);
      expect(FieldPlanPresets.homeSoak().resetDtnBuffer, isTrue);
      // Buffer persistence IS the subject of the mesh-growth run.
      final p = FieldPlanPresets.meshScale(role: 1);
      expect(p.resetDtnBuffer, isFalse);
      expect(FieldPlan.fromJson(p.toJson()).resetDtnBuffer, isFalse,
          reason: 'must survive the JSON round-trip');
    });

    test('powerBaseline conditions: subset keeps canonical order and one tap',
        () {
      final p = FieldPlanPresets.powerBaseline(
          role: 1, reps: 1, conditions: const ['light', 'base', 'linked']);
      expect(p.steps.map((s) => s.label), ['base', 'linked', 'light'],
          reason: 'canonical order regardless of how the subset is written');
      expect(p.steps.where((s) => !s.autoAdvance), hasLength(1));
      // The subset must exercise the same behaviours as the full ladder.
      expect(p.steps[0].bleOn, isFalse);
      expect(p.steps[1].bleOn, isTrue);
      expect(p.steps[2].sendCount, greaterThan(0));
      expect(FieldPlan.fromJson(p.toJson()), p);
    });

    test('the pre-check preset is short and screen-off testable', () {
      final pre = FieldPlanPresets
          .presets['Power PRE-CHECK P1 (~3.5 min, screen off)']!;
      expect(pre.steps, hasLength(3));
      // 60s per condition — the same granularity as the real ladder, so a
      // segment that survives screen-off here survives it there. Anything
      // shorter would also starve the 10s power sampler.
      expect(pre.steps.every((s) => s.dwellSec == 60), isTrue);
      final total = pre.steps.fold<int>(0, (a, s) => a + s.dwellSec) +
          pre.steps.length * pre.autoAdvanceGapSec +
          pre.settleSec;
      expect(total, lessThan(240), reason: 'a smoke test nobody will skip');
    });

    test('rawLink: one step per leg, leg in the label, raw mode set', () {
      final p = FieldPlanPresets.rawLink(legs: const ['notify', 'stripe']);
      expect(p.steps.map((s) => s.rawLeg), ['notify', 'stripe']);
      expect(p.steps.map((s) => s.label), ['leg=notify', 'leg=stripe']);
      expect(p.steps.map((s) => s.autoAdvance), [false, true]);
      expect(p.resetSessions, isFalse);
      expect(p.resetLinks, isTrue,
          reason: 'the plugin GATT op queue is unbounded and survives every '
              'app-level reset; only a link teardown discards a blast '
              'step\'s backlog, so raw steps bounce the link by default');
      expect(p.resetDtnBuffer, isFalse,
          reason: 'raw blobs never touch the DTN buffer — nothing to clear');
      expect(FieldPlanWizard.resetDefaults(FieldPlanKind.rawLink),
          (false, true));
      expect(FieldPlan.fromJson(p.toJson()), p,
          reason: 'rawLeg must survive the JSON round-trip');
    });

    test('powerBaseline: complementary roles under identical labels', () {
      final p1 = FieldPlanPresets.powerBaseline(role: 1, reps: 2);
      final p2 = FieldPlanPresets.powerBaseline(role: 2, reps: 2);
      expect(p1.steps.map((s) => s.label), p2.steps.map((s) => s.label),
          reason: 'both phones stamp the SAME segment labels so the '
              'analyzer aligns their power samples');
      expect(p1.steps, hasLength(16));
      expect(p1.steps.map((s) => s.label).toSet(), hasLength(16),
          reason: 'repeat suffixes keep every segment distinct');
      // One tap total: only the very first step waits.
      expect(p1.steps.where((s) => !s.autoAdvance), hasLength(1));

      Map<String, FieldStep> by(FieldPlan p) =>
          {for (final s in p.steps) s.label: s};
      final a = by(p1), b = by(p2);
      // base: both down. solo: exactly one up. linked: both up.
      expect((a['base r1']!.bleOn, b['base r1']!.bleOn), (false, false));
      expect((a['solo r1']!.bleOn, b['solo r1']!.bleOn), (true, false));
      expect((a['solo2 r1']!.bleOn, b['solo2 r1']!.bleOn), (false, true));
      expect((a['linked r1']!.bleOn, b['linked r1']!.bleOn), (true, true));
      // light: exactly one sends; heavy: exactly one saturates (1 sender —
      // the measured capacity knee).
      expect((a['light r1']!.sendCount > 0, b['light r1']!.sendCount > 0),
          (true, false));
      expect((a['light2 r1']!.sendCount > 0, b['light2 r1']!.sendCount > 0),
          (false, true));
      expect((a['heavy r1']!.saturate, b['heavy r1']!.saturate),
          (true, false));
      expect(a['heavy r1']!.sendLanes, 1);
      expect((a['heavy2 r1']!.saturate, b['heavy2 r1']!.saturate),
          (false, true));
      expect(FieldPlan.fromJson(p1.toJson()), p1,
          reason: 'bleOn must survive the JSON round-trip');

      // Every condition gets the SAME window, saturating ones included: a
      // shorter heavy segment would trade measurement uniformity for an
      // upload limit, which is the server's problem to fix, not the
      // experiment's to design around.
      expect(p1.steps.every((s) => s.dwellSec == 600), isTrue);
    });

    test('rawLink route threads legs through the wizard', () {
      final p = FieldPlanWizard.build(
          kind: FieldPlanKind.rawLink,
          expId: 'r',
          rawLegs: const ['write']);
      expect(p.steps.single.rawLeg, 'write');
    });

    test('ceiling route threads the lane sweep through', () {
      final p = FieldPlanWizard.build(
          kind: FieldPlanKind.throughputCeiling,
          expId: 'c',
          laneCounts: const [2, 8]);
      expect(p.steps.map((s) => s.sendLanes), [2, 8]);
    });

    test('throughput route threads the payload arm through', () {
      final p = FieldPlanWizard.build(
          kind: FieldPlanKind.throughput,
          expId: 't',
          payloadSizes: const [132, 1200]);
      expect(p.steps.map((s) => s.sendBytes), [132, 1200]);
    });

    test('parseInts handles commas/spaces and rejects junk', () {
      expect(FieldPlanWizard.parseInts('1, 5,  10', const [99]), [1, 5, 10]);
      expect(FieldPlanWizard.parseInts('  ', const [99]), [99]);
      expect(FieldPlanWizard.parseInts('a, -3, 0, 7', const [99]), [7]);
    });
  });

  group('bounceStress', () {
    test('alternates down/up and every up step outlives the watchdog', () {
      final plan = FieldPlanPresets.bounceStress();

      expect(plan.steps.length, 8, reason: '4 down-times x (down + up)');
      for (var i = 0; i < plan.steps.length; i += 2) {
        expect(plan.steps[i].bleOn, isFalse);
        expect(plan.steps[i + 1].bleOn, isTrue);
        // A bleOn:true step at or below the 30s watchdog is never watched,
        // which would make the whole diagnostic silently useless.
        expect(plan.steps[i + 1].dwellSec, greaterThan(30));
      }
      expect(plan.steps.map((s) => s.dwellSec).where((d) => d != 60).toList(),
          [120, 300, 600], reason: 'down-times increase');
    });

    test('only the first step waits for a tap', () {
      final plan = FieldPlanPresets.bounceStress();
      expect(plan.steps.first.autoAdvance, isFalse);
      expect(plan.steps.skip(1).every((s) => s.autoAdvance), isTrue);
    });
  });

  group('meshScale (stable dilating clique)', () {
    test('join order decides presence; blocks n=3..N with stable reps', () {
      final p = FieldPlanPresets.meshScale(role: 5, maxDevices: 6, repeat: 2);
      final byLabel = {for (final st in p.steps) st.label: st};
      expect(byLabel.keys.toSet(), {
        for (var n = 3; n <= 6; n++) ...{'n=$n t1', 'n=$n t2'}
      });
      expect(byLabel['n=4 t1']!.bleOn, isFalse, reason: 'role 5 not yet in');
      expect(byLabel['n=5 t1']!.bleOn, isTrue);
      expect(byLabel['n=5 t1']!.saturate, isTrue,
          reason: 'performance run: everyone up saturates');
      // NO toggling inside blocks — churn belongs to the joinTime run.
      expect(p.steps.where((st) => st.label.startsWith('off ')), isEmpty);
      expect(p.steps.every((st) => st.resetSessions == null), isTrue);
    });

    test('manual by construction: no GPS, wall-clock anchor, order stamped',
        () {
      final p = FieldPlanPresets.meshScale(role: 4);
      expect(p.manualJoin, isTrue);
      expect(p.sampleGps, isFalse);
      expect(p.deviceOrder, 4);
      expect(p.resetDtnBuffer, isFalse,
          reason: 'buffer persistence across steps IS part of the subject');
      expect(FieldPlan.fromJson(p.toJson()), p);
    });
  });

  group('joinTime (toggling frontier, quiet mesh)', () {
    test('the frontier toggles through its block, then stands', () {
      final p = FieldPlanPresets.joinTime(role: 5, maxDevices: 6, repeat: 3);
      final off = p.steps.firstWhere((st) => st.label == 'off n=5 t2');
      expect(off.bleOn, isFalse);
      expect(off.resetSessions, isTrue,
          reason: 'reset while DARK so every join is a cold handshake');
      final join = p.steps.firstWhere((st) => st.label == 'n=5 t2');
      expect(join.bleOn, isTrue);
      expect(join.resetSessions, isNull,
          reason: 'a reset at the join step would measure itself');
      expect(join.saturate, isFalse,
          reason: 'the establishment run keeps the mesh QUIET');
      // Annealed for block 6; dark before its turn.
      expect(p.steps.where((st) => st.label == 'off n=6 t1'), isEmpty);
      expect(p.steps.firstWhere((st) => st.label == 'n=6 t1').bleOn, isTrue);
      expect(p.steps.firstWhere((st) => st.label == 'n=4 t1').bleOn, isFalse);
    });

    test('standing phones are quiet: no saturation, no sends', () {
      final p = FieldPlanPresets.joinTime(role: 1, maxDevices: 5);
      expect(p.steps.every((st) => !st.saturate && st.sendCount == 0), isTrue);
      expect(p.steps.every((st) => st.bleOn == true), isTrue,
          reason: 'the founding trio stands throughout');
    });

    test('all roles tick in exact wall-clock lockstep', () {
      int span(FieldPlan p) => p.steps
          .fold(0, (a, st) => a + st.dwellSec + p.autoAdvanceGapSec);
      final frontier = FieldPlanPresets.joinTime(role: 5, maxDevices: 8);
      final standing = FieldPlanPresets.joinTime(role: 1, maxDevices: 8);
      final late_ = FieldPlanPresets.joinTime(role: 8, maxDevices: 8);
      expect(span(frontier), span(standing));
      expect(span(standing), span(late_));
      expect(frontier.alignSec, standing.alignSec);
    });

    test('blocks start at the first frontier: k=4, trio unmeasured', () {
      final p = FieldPlanPresets.joinTime(role: 1, maxDevices: 8);
      final ks = p.steps
          .where((st) => !st.label.startsWith('off '))
          .map((st) => st.label.split(' ').first)
          .toSet();
      expect(ks, {for (var k = 4; k <= 8; k++) 'n=$k'});
    });
  });

  group('wizard: mesh scaling', () {
    test('device count, role and reps come from the wizard', () {
      final plan = FieldPlanWizard.build(
        kind: FieldPlanKind.meshScale,
        expId: 'scale',
        maxDevices: 5,
        meshRole: 4,
        dwellSec: 90,
        repeat: 2,
      );
      // 5 devices -> sizes 3..5, 2 stable reps each; role 4 joins at n=4.
      expect(plan.steps.map((s) => s.label).toList(), [
        'n=3 t1', 'n=3 t2', 'n=4 t1', 'n=4 t2', 'n=5 t1', 'n=5 t2',
      ]);
      final byLabel = {for (final s in plan.steps) s.label: s};
      expect(byLabel['n=3 t1']!.bleOn, isFalse);
      expect(byLabel['n=4 t1']!.bleOn, isTrue);
      expect(byLabel['n=4 t1']!.dwellSec, 90);
    });

    test('the joinTime kind routes with the id carrying the spacing', () {
      final plan = FieldPlanWizard.build(
        kind: FieldPlanKind.joinTime,
        expId: 'join-time-30m',
        meshRole: 4,
        maxDevices: 5,
        dwellSec: 45,
        repeat: 2,
      );
      expect(plan.expId, 'join-time-30m');
      expect(plan.steps.map((s) => s.label).toList(), [
        'off n=4 t1', 'n=4 t1', 'off n=4 t2', 'n=4 t2', 'n=5 t1', 'n=5 t2',
      ]);
    });

    test('the wizard keeps sessions and links warm plan-wide', () {
      // Only the frontier's own off steps reset, and only while dark.
      final plan = FieldPlanWizard.build(
          kind: FieldPlanKind.meshScale, expId: 'scale');
      expect(plan.resetSessions, isFalse);
      expect(plan.resetLinks, isFalse);
    });

    test('the wizard can build the fixed-rate arm', () {
      final plan = FieldPlanWizard.build(
        kind: FieldPlanKind.meshScale,
        expId: 'scale',
        saturate: false,
        sends: 40,
        maxDevices: 4,
        meshRole: 1,
        repeat: 1,
      );
      // Role 1 is up from the start; fixed-rate sends thread through.
      expect(plan.steps.every((s) => !s.saturate), isTrue);
      expect(plan.steps.first.sendCount, 40);
    });
  });

  group('PREFLIGHT preset (manual join, 4 devices)', () {
    FieldPlan row(int r) => FieldPlanPresets.presets[
        'PREFLIGHT 4 devices, manual join (~7 min) — this phone is #$r']!;

    test('rehearses the real procedure: manual, no GPS, own id', () {
      final p = row(1);
      expect(p.manualJoin, isTrue);
      expect(p.sampleGps, isFalse);
      expect(p.expId, 'mesh-preflight',
          reason: 'a rehearsal must never land in a real run\'s file');
      expect(p.deviceOrder, 1);
      // 4 devices -> sizes 3 and 4, two stable reps each.
      expect(p.steps.map((s) => s.label),
          ['n=3 t1', 'n=3 t2', 'n=4 t1', 'n=4 t2']);
    });

    test('phone 4 is dark at n=3 and joins at n=4', () {
      final p = row(4);
      expect(p.steps.firstWhere((s) => s.label == 'n=3 t1').bleOn, isFalse);
      expect(p.steps.firstWhere((s) => s.label == 'n=4 t1').bleOn, isTrue);
    });

    test('aligns to 2 minutes, not 10 — a table test must start soon', () {
      final p = row(2);
      expect(p.alignSec, 120);
      expect(p.placementSec, 60);
    });

    test('the dead procedures are gone from the preset list', () {
      final names = FieldPlanPresets.presets.keys;
      expect(names.where((n) => n.contains('SMOKE')), isEmpty);
      expect(names.where((n) => n.contains('@ 30m')), isEmpty);
      expect(names.where((n) => n.contains('@ 50m')), isEmpty);
      expect(names.where((n) => n.contains('line sweep')), isEmpty);
      expect(names.where((n) => n.contains('multi-hop')), isEmpty);
      expect(names.where((n) => n.contains('store-carry')), isEmpty);
    });
  });


}
