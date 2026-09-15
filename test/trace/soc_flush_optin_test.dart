import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/trace/experiment_recorder.dart';
import 'package:grassroots_networking/src/testbed/testbed_config.dart';
import 'package:grassroots_networking/src/testbed/field_plan_presets.dart';

void main() {
  test('the state-of-charge flush is OFF by default', () {
    // It writes to disk inside a measurement window. Only a discharge run,
    // which has no clean stop, should pay for that.
    expect(ExperimentRecorder().flushEverySocDrop, 0);
  });

  test('a plan carries it, and null means off', () {
    const off = FieldPlan(expId: 'x', steps: []);
    expect(off.flushEverySocDrop, isNull);
    const on = FieldPlan(expId: 'x', steps: [], flushEverySocDrop: 5);
    expect(on.flushEverySocDrop, 5);
    expect(FieldPlan.fromJson(on.toJson()).flushEverySocDrop, 5);
    expect(FieldPlan.fromJson(off.toJson()).flushEverySocDrop, isNull);
  });

  test('the field-run presets leave it off', () {
    expect(FieldPlanPresets.linkChurn().flushEverySocDrop, isNull);
    expect(FieldPlanPresets.dilutingLineLoads().flushEverySocDrop, isNull);
    expect(FieldPlanPresets.lineSweepUpTo().flushEverySocDrop, isNull);
  });
}
