import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/testbed/field_plan_presets.dart';
import 'package:grassroots_networking/src/testbed/testbed_config.dart';

void main() {
  final p = FieldPlanPresets.linkChurn();
  List<FieldStep> arm(String load) =>
      p.steps.where((s) => s.label.contains('L=$load')).toList();

  test('three arms, ten runs each, all at N=8', () {
    expect(arm('moderate').length, 10);
    expect(arm('sat').length, 10);
    expect(arm('hold').length, 10);
    expect(p.steps.length, 30);
    // k = N-1, so N=8 is the k=7 row the simulator lacks.
    expect(p.steps.map((s) => s.cliqueN).toSet(), {8});
  });

  test('fixed-load arm: 60s of 100 messages to every session, links broken',
      () {
    for (final s in arm('moderate')) {
      expect(s.saturate, isFalse);
      expect(s.sendLanes, 1);
      expect(s.dwellSec, 60);
      expect(s.sendCount, 100);
      expect(s.sendBytes, 138);
      expect(p.gapAfterSec(s), 60);
      expect(s.sendTo, 'all');
      expect(s.resetLinks, isTrue);
    }
  });

  test('saturating arm: same window, offering what the radio takes', () {
    for (final s in arm('sat')) {
      expect(s.saturate, isTrue);
      expect(s.sendLanes, 1);
      expect(s.dwellSec, 60);
      expect(s.cliqueN, 8);
      expect(s.resetLinks, isTrue);
    }
  });

  test('long hold: ten minutes, no in-run link reset', () {
    for (final s in arm('hold')) {
      expect(s.dwellSec, 600);
      // Ten times the dwell, so ten times the count: sends are paced evenly
      // across the window, so a fixed count would offer a tenth the RATE and
      // the hold arm would measure outages under a load no other arm sees.
      expect(s.sendCount, 1000);
      expect(s.saturate, isFalse);
      expect(s.cliqueN, 8);
      // The whole point: an outage must be watched to completion, not ended
      // by the harness bouncing the transport.
      expect(s.resetLinks, isFalse);
    }
  });

  test('every arm offers the same rate: messages per second per destination',
      () {
    double rate(FieldStep s) => s.sendCount / s.dwellSec;
    final rates = p.steps.map(rate).toSet();
    expect(rates, hasLength(1),
        reason: 'arms must be comparable: $rates');
    expect(rates.single, closeTo(100 / 60, 1e-9));
  });

  test('the buffer is purged at ARM boundaries and nowhere else', () {
    // Per-run purging truncates latency; never purging lets an arm inherit a
    // buffer built under a different offered load, which the saturating arm
    // would then measure as part of its own ceiling.
    for (final load in ['moderate', 'sat', 'hold']) {
      final a = arm(load);
      expect(a.first.resetDtnBuffer, isTrue,
          reason: '$load must generate its own buffer');
      expect(a.skip(1).every((s) => s.resetDtnBuffer == false), isTrue,
          reason: '$load must not purge mid-arm');
    }
    expect(p.steps.where((s) => s.resetDtnBuffer == true).length, 3,
        reason: 'exactly one purge per arm');
  });

  test('no cap override, so eviction never fires', () {
    // A cap plus a uniform offered rate would make slower phones evict more,
    // and eviction is oldest-first — so the loss would correlate with write
    // capability, which is the very thing being measured.
    expect(p.dtnMaxBytes, isNull);
  });

  test('sessions are never reset, at plan level or on any step', () {
    expect(p.resetSessions, isFalse);
    expect(p.steps.every((s) => s.resetSessions == null), isTrue);
  });

  test('the drain actually fires — plan-level resetLinks must stay false', () {
    // `FieldPlan.gapAfterSec` reads the PLAN flag, not the step's, and
    // short-circuits to 0 when it is true. A plan-level `true` would
    // silently discard every drain in the run, and a saturating dwell ends
    // with acknowledgements still in flight.
    expect(p.resetLinks, isFalse,
        reason: 'plan-level true kills drainSec for every step');
    expect(p.drainSec, 60);
    for (final s in p.steps) {
      expect(p.gapAfterSec(s), 60,
          reason: 'every step must get its drain, ${s.label}');
    }
  });

  test('the dropdown duration is honest', () {
    // A preset's name is what an operator budgets an evening against.
    final dwell = p.steps.fold<int>(0, (a, s) => a + s.dwellSec);
    final drain = p.steps.fold<int>(0, (a, s) => a + p.gapAfterSec(s));
    final total = dwell + drain + p.placementSec + p.alignSec;
    expect(dwell, 10 * 60 + 10 * 60 + 10 * 600);
    // Label claims ~2h10m; hold the estimate inside a sane band of it.
    expect(total, greaterThan(110 * 60));
    expect(total, lessThan(160 * 60));
  });

  test('round-trips through JSON, which is how a preset actually launches',
      () {
    // The picker serialises into the text field and the run launches from
    // the PARSED text, not the object.
    final again = FieldPlan.fromJson(p.toJson());
    expect(again.steps.length, p.steps.length);
    expect(again.steps, p.steps);
    expect(again.resetLinks, p.resetLinks);
    expect(again.resetSessions, p.resetSessions);
    expect(again.drainSec, p.drainSec);
    expect(again.scriptedRadio, p.scriptedRadio);
    expect(again.traceEveryAdvertisement, p.traceEveryAdvertisement);
  });

  test('is reachable from the dropdown', () {
    expect(FieldPlanPresets.presets.containsKey(
        FieldPlanPresets.linkChurnPresetName), isTrue);
    expect(FieldPlanPresets.linkChurnPresetName, contains('N=8'));
  });

  test('first step waits for the operator; the rest run hands-free', () {
    expect(p.steps.first.autoAdvance, isFalse);
    expect(p.steps.skip(1).every((s) => s.autoAdvance), isTrue);
  });

  test('refuses to launch without a full session table', () {
    // The plan never forms a session --- it keeps them across every step and
    // has no clique growth --- so a phone that launches short stays short for
    // the whole run. The send path gates on `hasSession`, so the pairs it is
    // missing produce nothing at all, and nothing says so until the
    // reduction. N-1 sessions at N=8 is seven.
    expect(p.resetSessions, isFalse);
    expect(p.minSessionsToLaunch, 7);
    expect(p.steps.every((s) => s.cliqueN == 8), isTrue,
        reason: 'the gate is only right while every step is N=8');
  });
}
