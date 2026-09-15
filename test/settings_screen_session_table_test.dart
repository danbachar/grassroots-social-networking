import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redux/redux.dart';
import 'package:grassroots_networking/settings_screen.dart';
import 'package:grassroots_networking/theme/grasslink_theme.dart';
import 'package:grassroots_networking/src/models/peer.dart';
import 'package:grassroots_networking/src/store/store.dart';

/// The settings session table is driven by the SESSIONS slice, never by the
/// peer list, and this is the case that proves it: the stale sweep deletes a
/// quiet non-friend from `peersList` after ten silent announce cycles while
/// its Noise session survives untouched. That peer is still perfectly
/// sendable — `hasSession` short-circuits the establish and the message seals
/// into the DTN buffer — so a table that only listed peers with records would
/// hide precisely the sessions nothing else in the UI reveals, and its
/// "clear all" would then be destroying entries the operator never saw.
///
/// The row must therefore render from the pubkey alone, and the destructive
/// controls must both go through a confirmation, because a purge is not a
/// round trip the next send quietly pays: no packet is created without a
/// session, and under a link gate a non-neighbour can never re-handshake.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String hexOf(Uint8List key) =>
      key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  final swept = Uint8List.fromList(List.filled(32, 0xab));
  final known = Uint8List.fromList(List.filled(32, 0xcd));

  PeerState peerRecord(Uint8List key, String nickname) => PeerState(
        publicKey: key,
        nickname: nickname,
        connectionState: PeerConnectionState.connected,
        transport: PeerTransport.bleDirect,
      );

  /// A store holding sessions with both peers but a peer RECORD only for
  /// [known] — exactly the post-sweep shape described above.
  Store<AppState> storeWithSweptPeer() => Store<AppState>(
        appReducer,
        initialState: AppState(
          peers: PeersState.initial
              .copyWith(peers: {hexOf(known): peerRecord(known, 'nearby')}),
          sessions: SessionsState(establishedAtMs: {
            hexOf(swept): DateTime.now().millisecondsSinceEpoch - 90 * 1000,
            hexOf(known): DateTime.now().millisecondsSinceEpoch - 5 * 1000,
          }),
        ),
      );

  Future<void> pumpSettings(
    WidgetTester tester,
    Store<AppState> store, {
    void Function(Uint8List peer)? onResetSessionWith,
    VoidCallback? onResetSessions,
    void Function(Uint8List peer)? onIgnorePeer,
    void Function(String pubkeyHex)? onUnignorePeer,
  }) async {
    // A tall surface so the whole ListView is laid out and no assertion
    // depends on scroll position.
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: grasslinkTheme(),
      home: SettingsScreen(
        store: store,
        onResetSessionWith: onResetSessionWith,
        onResetSessions: onResetSessions,
        onIgnorePeer: onIgnorePeer,
        onUnignorePeer: onUnignorePeer,
      ),
    ));
    await tester.pump();
  }

  testWidgets('renders a session whose peer record is gone, by pubkey prefix',
      (tester) async {
    await pumpSettings(tester, storeWithSweptPeer());

    expect(find.text('Noise sessions (debug)'), findsOneWidget);
    expect(find.text('2 sessions'), findsOneWidget);

    // The swept peer has no nickname to show, so the row is titled with its
    // pubkey prefix and says why there is no name — not an error, a fact.
    expect(find.text(hexOf(swept).substring(0, 16)), findsOneWidget);
    expect(
      find.textContaining('no peer record'),
      findsOneWidget,
      reason: 'a session without a peer record must still be listed',
    );

    // The peer that still has a record is named, with its prefix underneath.
    expect(find.text('nearby'), findsOneWidget);
    expect(find.text(hexOf(known).substring(0, 16)), findsOneWidget);

    // Establishment age is rendered per row.
    expect(find.textContaining('established 1m ago'), findsOneWidget);
    expect(find.textContaining('established 5s ago'), findsOneWidget);
  });

  testWidgets('a swept peer\'s session can be dropped from its own row',
      (tester) async {
    final purged = <Uint8List>[];
    await pumpSettings(tester, storeWithSweptPeer(),
        onResetSessionWith: purged.add);

    // Rows are ordered by pubkey hex, so 0xab... sorts before 0xcd... and the
    // first delete button is the swept peer's. That ordering is deliberate:
    // a recency sort would move a destructive button under the finger.
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();

    expect(find.text('Drop this session?'), findsOneWidget);
    expect(find.textContaining('FAILS at creation'), findsOneWidget);

    await tester.tap(find.text('Drop'));
    await tester.pumpAndSettle();

    expect(purged, hasLength(1));
    expect(purged.single, equals(swept),
        reason: 'the hex key must round-trip back to the peer pubkey bytes');
  });

  testWidgets('cancelling the per-row confirmation purges nothing',
      (tester) async {
    final purged = <Uint8List>[];
    await pumpSettings(tester, storeWithSweptPeer(),
        onResetSessionWith: purged.add);

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(purged, isEmpty);
  });

  testWidgets('clear-all confirms, and says the run will be ruined',
      (tester) async {
    var cleared = 0;
    await pumpSettings(tester, storeWithSweptPeer(),
        onResetSessions: () => cleared++);

    await tester.tap(find.text('Clear all sessions'));
    await tester.pumpAndSettle();

    expect(find.text('Clear ALL sessions?'), findsOneWidget);
    expect(find.textContaining('ruins the run'), findsOneWidget);
    expect(cleared, 0, reason: 'nothing fires before the operator confirms');

    await tester.tap(find.text('Clear all'));
    await tester.pumpAndSettle();

    expect(cleared, 1);
  });

  testWidgets('a session row can ignore its phone, no confirmation',
      (tester) async {
    // Ignoring is in memory only and is undone from the ignored-phones panel,
    // so unlike a session drop it does not need a confirmation.
    final ignored = <Uint8List>[];
    await pumpSettings(tester, storeWithSweptPeer(), onIgnorePeer: ignored.add);

    await tester.tap(find.byTooltip('Ignore this phone').first);
    await tester.pumpAndSettle();

    expect(ignored, hasLength(1));
    expect(ignored.single, equals(swept));
  });

  testWidgets('ignored phones are listed and can be un-ignored',
      (tester) async {
    final store = storeWithSweptPeer();
    store.dispatch(IgnorePeerAction(hexOf(known)));
    final lifted = <String>[];
    await pumpSettings(tester, store, onUnignorePeer: lifted.add);

    expect(find.text('Ignored phones (debug)'), findsOneWidget);
    expect(find.textContaining(hexOf(known).substring(0, 8)), findsWidgets);

    await tester.tap(find.text('Stop ignoring'));
    await tester.pumpAndSettle();

    expect(lifted, [hexOf(known)]);
  });

  testWidgets('an empty session table says nothing can be messaged',
      (tester) async {
    final store = Store<AppState>(appReducer,
        initialState: const AppState(sessions: SessionsState()));
    await pumpSettings(tester, store);

    expect(
      find.text('No sessions — nothing can be messaged from this device.'),
      findsOneWidget,
    );
    // No table, so no destructive control to mis-tap.
    expect(find.text('Clear all sessions'), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });
}
