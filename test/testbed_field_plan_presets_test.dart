import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/testbed/field_plan_presets.dart';
import 'package:grassroots_networking/src/testbed/testbed_config.dart';

void main() {
  group('FieldPlanPresets', () {
    test('home soak: one long rosterless dwell with sends', () {
      final p = FieldPlanPresets.homeSoak(dwellMin: 40, sends: 40);
      expect(p.roster, isEmpty);
      expect(p.steps, hasLength(1));
      expect(p.steps.single.dwellSec, 40 * 60);
      expect(p.steps.single.sendCount, 40);
      expect(FieldPlan.fromJson(p.toJson()), p);
    });

    test('line sweep: approach sorted, retreat excludes near anchors', () {
      final p = FieldPlanPresets.lineSweep(
          distances: const [1, 5, 10, 40], retreat: true);
      final labels = p.steps.map((s) => s.label).toList();
      expect(labels, [
        'd=1 approach',
        'd=5 approach',
        'd=10 approach',
        'd=40 approach',
        'd=40 retreat',
        'd=10 retreat',
      ]);
      // Anchors dwell shorter; every step resets links + sessions + sends.
      expect(p.resetSessions, isTrue);
      expect(p.resetLinks, isTrue,
          reason: 'the sweep measures the full discovered→connected ladder');
      expect(FieldPlan.fromJson(p.toJson()).resetLinks, isTrue);
      expect(p.steps.every((s) => s.sendCount > 0), isTrue);
      expect(FieldPlan.fromJson(p.toJson()), p);
    });

    test('line sweep without retreat is approach-only', () {
      final p = FieldPlanPresets.lineSweep(
          distances: const [5, 10, 20], retreat: false);
      expect(p.steps.map((s) => s.label),
          ['d=5 approach', 'd=10 approach', 'd=20 approach']);
    });

    test('data plane: bulk steps, warm sessions', () {
      final p = FieldPlanPresets.dataPlane(sideLengths: const [10, 20]);
      expect(p.resetSessions, isFalse);
      expect(p.steps.every((s) => s.bulk), isTrue);
      expect(p.steps.every((s) => s.sendCount == 0), isTrue);
      expect(p.steps.map((s) => s.label), ['side=10', 'side=20']);
      expect(FieldPlan.fromJson(p.toJson()), p);
    });

    test('repeat expands each step into N uniquely-labelled trials', () {
      final soak = FieldPlanPresets.homeSoak(dwellMin: 1, sends: 2, repeat: 3);
      expect(soak.steps.map((s) => s.label),
          ['c1 d=3 soak', 'c2 d=3 soak', 'c3 d=3 soak']);
      expect(soak.steps.map((s) => s.label).toSet(), hasLength(3),
          reason: 'labels unique so the analyzer keeps each trial separate');

      final line = FieldPlanPresets.lineSweep(
          distances: const [10], retreat: false, repeat: 2);
      expect(line.steps.map((s) => s.label),
          ['d=10 approach t1', 'd=10 approach t2']);

      final dp = FieldPlanPresets.dataPlane(sideLengths: const [20], repeat: 2);
      expect(dp.steps.map((s) => s.label), ['side=20 t1', 'side=20 t2']);
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

    test('lineSweep: autoAdvance only on same-distance repeats', () {
      final p = FieldPlanPresets.lineSweep(
          distances: const [10, 20], retreat: false, repeat: 2);
      // d=10 t1 (tap), d=10 t2 (auto), d=20 t1 (tap), d=20 t2 (auto)
      expect(p.steps.map((s) => s.autoAdvance),
          [false, true, false, true]);
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

      final line = FieldPlanWizard.build(
          kind: FieldPlanKind.lineSweep, expId: 'l', distances: const [2, 8]);
      expect(line.steps.first.label, 'd=2 approach');

      final dp = FieldPlanWizard.build(
          kind: FieldPlanKind.dataPlane, expId: 'd', sideLengths: const [30]);
      expect(dp.steps.single.label, 'side=30');
    });

    test('empty id falls back to "exp"', () {
      final p = FieldPlanWizard.build(kind: FieldPlanKind.homeSoak, expId: '   ');
      expect(p.expId, 'exp');
    });

    test('reset toggles: null uses kind defaults, explicit overrides', () {
      // Defaults: soak (sess on, links off); line (both on); data (both off).
      expect(FieldPlanWizard.resetDefaults(FieldPlanKind.homeSoak), (true, false));
      expect(FieldPlanWizard.resetDefaults(FieldPlanKind.lineSweep), (true, true));
      expect(FieldPlanWizard.resetDefaults(FieldPlanKind.dataPlane), (false, false));

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

    test('parseInts handles commas/spaces and rejects junk', () {
      expect(FieldPlanWizard.parseInts('1, 5,  10', const [99]), [1, 5, 10]);
      expect(FieldPlanWizard.parseInts('  ', const [99]), [99]);
      expect(FieldPlanWizard.parseInts('a, -3, 0, 7', const [99]), [7]);
    });
  });
}
