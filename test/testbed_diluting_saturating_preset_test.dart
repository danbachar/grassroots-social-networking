import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/testbed/field_plan_presets.dart';

void main() {
  test('saturating arm differs from moderate in exactly the named fields', () {
    final mod = FieldPlanPresets.dilutingLineLoads();
    final sat = FieldPlanPresets.dilutingSaturating();
    expect(sat.steps.length, mod.steps.length);
    expect(sat.steps.first.label, 'N=2 L=sat t1');
    expect(sat.steps.last.label, 'N=7 L=sat t10');
    expect(sat.drainSec, 60);
    expect(mod.drainSec, isNull);
    for (var i = 0; i < sat.steps.length; i++) {
      final a = mod.steps[i], b = sat.steps[i];
      expect(b.saturate, isTrue);
      expect(b.sendLanes, 1);
      // everything else identical
      expect(b.dwellSec, a.dwellSec);
      expect(b.cliqueN, a.cliqueN);
      expect(b.sendTo, a.sendTo);
      expect(b.sendBytes, a.sendBytes);
      expect(b.sendCount, a.sendCount);
      expect(b.autoAdvance, a.autoAdvance);
      expect(b.resetSessions, a.resetSessions);
      expect(b.resetLinks, a.resetLinks);
      expect(b.label.replaceAll('L=sat', 'L=moderate'), a.label);
    }
    // N=2..7, ten trials each
    expect(sat.steps.where((s) => s.cliqueN == 7).length, 10);
    expect(sat.steps.map((s) => s.cliqueN).toSet(), {2, 3, 4, 5, 6, 7});
    // plan-level settings preserved
    expect(sat.joinGapSec, mod.joinGapSec);
    expect(sat.alignSec, mod.alignSec);
    expect(sat.scriptedRadio, mod.scriptedRadio);
    expect(sat.traceEveryAdvertisement, isTrue);
    expect(sat.expId, 'clique-sat-1');
  });
}
