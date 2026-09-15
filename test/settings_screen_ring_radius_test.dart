import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redux/redux.dart';
import 'package:grassroots_networking/settings_screen.dart';
import 'package:grassroots_networking/theme/grasslink_theme.dart';
import 'package:grassroots_networking/src/store/app_state.dart';
import 'package:grassroots_networking/src/store/reducers.dart';
import 'package:grassroots_networking/src/store/settings_actions.dart';

/// Four roster hexes in ring order (the order IS the sort).
const _p0 = '07e47335';
const _p1 = '18130c0f';
const _p2 = '366dca50';
const _p3 = '44a266c4';

void main() {
  Store<AppState> armedAt(int? radius, {List<String>? roster}) {
    final store = Store<AppState>(appReducer, initialState: AppState.initial);
    store.dispatch(SetRingGateAction(
      rosterHex: roster ?? const [_p0, _p1, _p2, _p3],
      radius: radius,
    ));
    return store;
  }

  Future<List<(List<String>, int?)>> pump(
    WidgetTester tester,
    Store<AppState> store, {
    String? selfHex = _p1,
  }) async {
    final calls = <(List<String>, int?)>[];
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: grasslinkTheme(),
      home: SettingsScreen(
        store: store,
        myPubkeyHex: selfHex,
        onSetRingGate: (roster, radius) async {
          calls.add((roster, radius));
        },
      ),
    ));
    await tester.pump();
    return calls;
  }

  testWidgets('says what the radius means, and nothing about the roster',
      (tester) async {
    await pump(tester, armedAt(1), selfHex: _p1);

    expect(find.text('Ring radius (debug)'), findsOneWidget);
    final desc = tester.widget<Text>(find.textContaining('Armed at 1')).data!;
    // A radius is standing policy; the roster is whatever plan is loaded right
    // now. Describing one in terms of the other made this read as a live
    // topology view, which went stale the moment a different plan loaded.
    for (final leak in [_p0, _p1, _p2, _p3, '4', 'position']) {
      expect(desc, isNot(contains(leak)),
          reason: 'the panel must not describe the roster: $desc');
    }
    expect(desc, contains('hop'));
  });

  testWidgets('Off disarms through the coordinator, so the prune can run',
      (tester) async {
    final calls = await pump(tester, armedAt(1));

    await tester.tap(find.widgetWithText(TextButton, 'Off'));
    await tester.pumpAndSettle();

    // Radius null, roster preserved: the roster is hardware and arrives with a
    // plan; this screen only lifts the constraint.
    expect(calls, hasLength(1));
    expect(calls.single.$2, isNull);
    expect(calls.single.$1, [_p0, _p1, _p2, _p3]);
  });

  testWidgets('takes any radius as free numeric input', (tester) async {
    // Not a fixed set of choices: which radii mean anything depends on the
    // roster a plan brings, and a control built from whatever roster happens
    // to be loaded offers the wrong ones the moment that roster changes.
    final calls = await pump(tester, armedAt(null));

    await tester.enterText(find.byType(TextField), '4');
    await tester.tap(find.widgetWithText(TextButton, 'Apply'));
    await tester.pumpAndSettle();

    expect(calls.single.$2, 4);
  });

  testWidgets('blank, zero and nonsense all mean off', (tester) async {
    for (final entry in ['', '0', 'x']) {
      final calls = await pump(tester, armedAt(2));
      await tester.enterText(find.byType(TextField), entry);
      await tester.tap(find.widgetWithText(TextButton, 'Apply'));
      await tester.pumpAndSettle();
      expect(calls.single.$2, isNull, reason: 'entry ${entry.isEmpty ? "<blank>" : entry}');
    }
  });

  testWidgets('renders identically whether or not a roster is loaded',
      (tester) async {
    // The panel must not change shape with the roster: hiding the field is how
    // an armed radius became unclearable in the first place, and sizing the
    // control to the roster made it offer whatever radii that evening's phone
    // count happened to allow.
    await pump(tester, armedAt(2, roster: const []));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Off'), findsOneWidget);
    final withoutRoster =
        tester.widget<Text>(find.textContaining('Armed at 2')).data!;

    await pump(tester, armedAt(2));
    final withRoster =
        tester.widget<Text>(find.textContaining('Armed at 2')).data!;
    expect(withoutRoster, withRoster);
  });
}
