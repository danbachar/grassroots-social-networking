import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redux/redux.dart';
import 'package:grassroots_networking/testbed_screen.dart';
import 'package:grassroots_networking/src/store/app_state.dart';
import 'package:grassroots_networking/src/store/reducers.dart';
import 'package:grassroots_networking/src/testbed/field_plan_presets.dart';
import 'package:grassroots_networking/src/testbed/testbed_config.dart';
import 'package:grassroots_networking/src/trace/experiment_recorder.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String path;
  _FakePathProvider(this.path);

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// The screen listens to connectivity on init; without a platform behind the
/// channel the listen throws. A stream that never emits stands in for it.
void _stubConnectivity() {
  const status = EventChannel('dev.fluttercommunity.plus/connectivity_status');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(status, MockStreamHandler.inline(onListen: (_, __) {}));
  const method = MethodChannel('dev.fluttercommunity.plus/connectivity');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(method, (_) async => <String>['none']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The auto runner section only exists when the screen has a recorder, and
  // the recorder polls its files on disk.
  Future<void> pump(WidgetTester tester,
      {Iterable<String> Function()? sessionPeerHexes}) async {
    _stubConnectivity();
    final tempDir = Directory.systemTemp.createTempSync('testbed_screen_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = Store<AppState>(appReducer, initialState: AppState.initial);
    await tester.pumpWidget(MaterialApp(
      home: TestbedScreen(
        store: store,
        experimentRecorder: ExperimentRecorder(),
        sessionPeerHexes: sessionPeerHexes,
      ),
    ));
    await tester.pump();
  }

  Future<void> pickPreset(WidgetTester tester, String name) async {
    await tester.tap(find.text('Pick a preset…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> planJson(WidgetTester tester) {
    final field = tester.widget<TextField>(
        find.byWidgetPredicate((w) => w is TextField && w.maxLines == 10));
    return jsonDecode(field.controller!.text) as Map<String, dynamic>;
  }

  Future<void> typePhones(WidgetTester tester, String n) async {
    final phones = find.widgetWithText(TextField, 'Phones');
    expect(phones, findsOneWidget);
    await tester.enterText(phones, n);
    await tester.pump();
  }

  testWidgets('the smoke is sized by a phones field', (tester) async {
    await pump(tester);
    await pickPreset(tester, FieldPlanPresets.ringSmokePresetName);
    expect(planJson(tester)['ringSize'], 10);
    await typePhones(tester, '6');
    final json = planJson(tester);
    expect(json['ringSize'], 6);
    // The radii follow the size: ring and complete graph for a 6-ring.
    final radii = (json['steps'] as List)
        .map((s) => (s as Map)['ringRadius'])
        .whereType<int>()
        .toSet();
    expect(radii, {1, 3});
  });

  testWidgets('the sweep is sized by the same field', (tester) async {
    await pump(tester);
    await pickPreset(tester, FieldPlanPresets.ringSweepPresetName);
    expect(planJson(tester)['ringSize'], 11);
    await typePhones(tester, '7');
    final json = planJson(tester);
    expect(json['ringSize'], 7);
    final radii = (json['steps'] as List)
        .map((s) => (s as Map)['ringRadius'])
        .whereType<int>()
        .toSet();
    expect(radii, {1, 2, 3});
  });

  testWidgets('a ring preset opens at the size of the session table',
      (tester) async {
    // The room CAN say how many phones are in it: a Noise session is pairwise
    // and the warm-up gives every phone a full table, so self + sessions is
    // the fleet. Opening at a number compiled into the preset is how a
    // ten-phone room got a plan built for eleven.
    await pump(tester,
        sessionPeerHexes: () => [for (var i = 0; i < 9; i++) 'peer$i']);
    await pickPreset(tester, FieldPlanPresets.ringSweepPresetName);
    expect(planJson(tester)['ringSize'], 10);
    // The radii follow the derived size: diameter of a 10-ring is 5.
    final radii = (planJson(tester)['steps'] as List)
        .map((s) => (s as Map)['ringRadius'])
        .whereType<int>()
        .toSet();
    expect(radii, {1, 2, 3, 4, 5});
    // Still overridable by hand for a room that is not fully warmed.
    await typePhones(tester, '6');
    expect(planJson(tester)['ringSize'], 6);
  });

  testWidgets('a table too small for a ring keeps the preset size',
      (tester) async {
    // Two warmed phones is not a ring, and a plan built for three would be
    // refused at launch anyway. The preset's own size stays until the field
    // is typed.
    await pump(tester, sessionPeerHexes: () => ['peer0', 'peer1']);
    await pickPreset(tester, FieldPlanPresets.ringSmokePresetName);
    expect(planJson(tester)['ringSize'], 10);
  });

  group('the sweep is split into two sessions', () {
    // The four Nexus 5X drain 18-25%/h and reach 48 C in half an hour, so a
    // 3h36 sweep runs them flat and cooks the late trials. Two sessions of
    // whole sweeps keep the interleaving intact — every sweep still visits
    // every radius — and give the units a charge and a cool in between.
    int trialsAtRadius(FieldPlan p, int r) =>
        p.steps.where((s) => s.label.startsWith('r=$r t')).length;

    test('between them the two sessions make five sweeps', () {
      expect(trialsAtRadius(ringSweepSession(session: 1, n: 10), 1), 3);
      expect(trialsAtRadius(ringSweepSession(session: 2, n: 10), 1), 2);
    });

    test('every radius is visited in both sessions', () {
      for (final s in [1, 2]) {
        final plan = ringSweepSession(session: s, n: 10);
        for (var r = 1; r <= 5; r++) {
          expect(trialsAtRadius(plan, r), greaterThan(0),
              reason: 'Session $s must still sample radius $r — a session '
                  'that drops one turns the split into a blocked design.');
        }
      }
    });

    test('the sessions carry different experiment ids', () {
      // Same id would pool them in one database and force a split on a
      // timestamp afterwards, which is exactly what ring-smoke6 cost us.
      expect(ringSweepSession(session: 1, n: 10).expId,
          isNot(ringSweepSession(session: 2, n: 10).expId));
    });
  });

  testWidgets('a half-typed size keeps the last plan', (tester) async {
    await pump(tester);
    await pickPreset(tester, FieldPlanPresets.ringSmokePresetName);
    await typePhones(tester, '');
    expect(planJson(tester)['ringSize'], 10);
    // Three phones is not a ring; the plan is not rebuilt around it.
    await typePhones(tester, '3');
    expect(planJson(tester)['ringSize'], 10);
  });
}
