import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/field_runner_screen.dart';
import 'package:grassroots_networking/src/testbed/field_runner.dart';
import 'package:grassroots_networking/src/testbed/testbed_config.dart';
import 'package:grassroots_networking/src/trace/experiment_recorder.dart';

/// In-memory stand-in: the screen starts the runner on init, and disk I/O in
/// a widget test never resolves.
class _FakeRecorder extends ExperimentRecorder {
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
  }

  @override
  Future<void> logMarker(String label,
          {Map<String, dynamic>? extra, DateTime? at}) async =>
      {};
}

void main() {
  const plan = FieldPlan(
    // Not named for the thing under test: the expId is rendered in the app
    // bar, so a match there would stand in for the readout.
    expId: 'sweep-1',
    placementSec: 60,
    alignSec: 60,
    steps: [FieldStep(label: 'r=5 t1', dwellSec: 30)],
  );

  Future<void> pump(WidgetTester tester, FieldRunner runner) async {
    await tester.pumpWidget(MaterialApp(
      home: FieldRunnerScreen(runner: runner, plan: plan),
    ));
    await tester.pump();
  }

  testWidgets('the running screen shows how many legs the phone holds',
      (tester) async {
    // The sweep's whole feasibility question is whether the mesh HOLDS its
    // legs once traffic starts — a fleet that builds twelve and sheds them to
    // four measures a topology nobody chose. Reading that off the phone is
    // what turns a three-and-a-half hour run into one you can abandon at
    // minute forty.
    final runner = FieldRunner(
      recorder: _FakeRecorder(),
      myNickname: '1',
      legsReady: () => 7,
    );
    addTearDown(runner.dispose);

    await pump(tester, runner);

    expect(find.textContaining('7'), findsWidgets);
    expect(find.textContaining('legs'), findsOneWidget);
  });

  // A radius PERMITS a leg count; the radio delivers what it can hold. Two
  // legs is the whole ring at r=1 and a collapsed mesh at r=5, so the verdict
  // is only ever relative to what the step asked for.
  Future<Color?> legColour(WidgetTester tester, {required int r, required int legs}) async {
    final runner = FieldRunner(
      recorder: _FakeRecorder(),
      myNickname: '1',
      legsReady: () => legs,
    );
    addTearDown(runner.dispose);
    await tester.pumpWidget(MaterialApp(
      home: FieldRunnerScreen(
        runner: runner,
        plan: FieldPlan(
          expId: 'sweep-1',
          ringSize: 10,
          placementSec: 60,
          alignSec: 60,
          steps: [FieldStep(label: 'r=$r t1', dwellSec: 30, ringRadius: r)],
        ),
      ),
    ));
    await tester.pump();
    return tester.widget<Text>(find.text('$legs')).style?.color;
  }

  /// The BAND's colour, not the digits'. At the distance this screen is read
  /// from, a filled area is the only thing that carries: a logical pixel is
  /// 1/160 inch, so even the countdown's fontSize 120 is a 13 mm digit, and
  /// signage wants 25 mm at ten metres. Colour is the signal; the number is
  /// for when you walk up to the phone.
  Future<Color?> bandColour(WidgetTester tester,
      {required int r, required int legs}) async {
    await legColour(tester, r: r, legs: legs);
    return tester
        .widget<Container>(find.byKey(const ValueKey('legsStrip')))
        .color;
  }

  testWidgets('a full complement of legs reads as normal', (tester) async {
    // r=5 on a 10-ring permits nine peers; eleven legs is a converged mesh.
    expect(await bandColour(tester, r: 5, legs: 11), Colors.white10);
  });

  testWidgets('short of what the radius permits reads as suspect',
      (tester) async {
    // Six of nine. The topology under test is not the one the radius asked
    // for, but it has not collapsed either.
    expect(await bandColour(tester, r: 5, legs: 6), Colors.amber);
  });

  testWidgets('less than half the permitted legs reads as wrong',
      (tester) async {
    // The measured collapse: nine permitted, four held. Every trial run in
    // this state measures the same graph whatever radius it claims.
    expect(await bandColour(tester, r: 5, legs: 4), Colors.red);
  });

  testWidgets('the same count is normal at a radius that permits it',
      (tester) async {
    // Two legs is the whole ring at r=1 — the identical number that is a
    // collapse at r=5.
    expect(await bandColour(tester, r: 1, legs: 2), Colors.white10);
  });

  testWidgets('an alarm fills the band with solid colour, readable at range',
      (tester) async {
    // Ten phones watched from ten metres away. A tinted strip is invisible at
    // that distance and no digit on a phone is legible there, so the alarm
    // has to be a saturated area of colour or it is not an alarm.
    expect((await bandColour(tester, r: 5, legs: 4))!.a, 1.0,
        reason: 'Solid, not a tint over black — a tint vanishes at range.');
    expect((await bandColour(tester, r: 5, legs: 11))!.a, lessThan(1.0),
        reason: 'Normal stays a dark strip, so any colour means something.');
  });

  testWidgets('a healthy mesh does not shout', (tester) async {
    // Normal is the state ten phones sit in for three hours. It stays quiet
    // so that any colour in the room means something.
    expect(await bandColour(tester, r: 5, legs: 11), isNot(Colors.red));
    expect(await bandColour(tester, r: 5, legs: 11), isNot(Colors.amber));
  });

  testWidgets('the alarm number is the biggest thing on the screen',
      (tester) async {
    // 96 is what this screen already uses for text meant to be read across a
    // room; the count earns the same, since walking closer is the only way
    // to read it at all.
    await legColour(tester, r: 5, legs: 4);
    expect(tester.widget<Text>(find.text('4')).style?.fontSize,
        greaterThanOrEqualTo(96));
  });

  testWidgets('with no leg source the screen says nothing about legs',
      (tester) async {
    // The count is a testbed affordance, not a promise every host can keep.
    final runner = FieldRunner(recorder: _FakeRecorder(), myNickname: '1');
    addTearDown(runner.dispose);

    await pump(tester, runner);

    expect(find.textContaining('legs'), findsNothing);
  });
}
