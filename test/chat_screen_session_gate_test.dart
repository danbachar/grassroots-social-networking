import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redux/redux.dart';
import 'package:grassroots_networking/chat_screen.dart';
import 'package:grassroots_networking/theme/grasslink_theme.dart';
import 'package:grassroots_networking/src/grassroots_network.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/models/peer.dart';
import 'package:grassroots_networking/src/store/store.dart';

import 'helpers/sodium_test_bootstrap.dart';

/// Composing is gated on holding a Noise session with the peer, because no
/// packet may exist without one — so no chat bubble may either.
///
/// The gate is deliberately NOT reachability. A session outlives the link that
/// formed it, so a peer who has walked out of range stays composable and the
/// message is sealed into the DTN buffer and carried. These tests pin both
/// halves: no session disables the composer, and a session enables it even
/// with the peer disconnected.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Widget> buildChat(
    Store<AppState> store,
    PeerState peer,
    GrassrootsIdentity identity,
    GrassrootsNetwork grassroots,
  ) async =>
      MaterialApp(
        theme: grasslinkTheme(),
        home: ChatScreen(
          grassroots: grassroots,
          peer: peer,
          myPubkey: identity.publicKey,
          store: store,
        ),
      );

  Future<(Store<AppState>, GrassrootsIdentity, GrassrootsNetwork)> setUpChat(
    PeerState peer,
  ) async {
    final sodium = await initTestSodium();
    final keyPair = await Ed25519().newKeyPair();
    final identity = await GrassrootsIdentity.create(
      keyPair: keyPair,
      nickname: 'me',
    );
    final store = Store<AppState>(
      appReducer,
      initialState: AppState(
        peers: PeersState.initial.copyWith(peers: {peer.pubkeyHex: peer}),
      ),
    );
    final grassroots = GrassrootsNetwork(
      identity: identity,
      store: store,
      sodium: sodium,
    );
    return (store, identity, grassroots);
  }

  PeerState peerWith({
    required bool hasNoiseSession,
    required PeerConnectionState connectionState,
  }) =>
      PeerState(
        publicKey: Uint8List.fromList(List.generate(32, (i) => i + 1)),
        nickname: 'peer',
        connectionState: connectionState,
        transport: PeerTransport.bleDirect,
        hasNoiseSession: hasNoiseSession,
      );

  testWidgets('without a session the composer is disabled and says why',
      (tester) async {
    final peer = peerWith(
      hasNoiseSession: false,
      connectionState: PeerConnectionState.connected,
    );
    final (store, identity, grassroots) = await setUpChat(peer);
    await tester.pumpWidget(await buildChat(store, peer, identity, grassroots));
    await tester.pump();

    expect(find.text('No session yet — waiting for this peer'), findsOneWidget,
        reason: 'a disabled composer must say why, not just look broken');

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);

    // The send button is present but inert: onPressed null is what makes it
    // impossible to save a bubble for a message that can never become a packet.
    final send = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded),
    );
    expect(send.onPressed, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    grassroots.dispose();
    await tester.pump();
  });

  testWidgets('a session enables the composer even when out of range',
      (tester) async {
    // The store-carry-forward case: session held, peer gone. Sealing needs the
    // session, not a live path, so this must stay composable.
    final peer = peerWith(
      hasNoiseSession: true,
      connectionState: PeerConnectionState.disconnected,
    );
    final (store, identity, grassroots) = await setUpChat(peer);
    await tester.pumpWidget(await buildChat(store, peer, identity, grassroots));
    await tester.pump();

    expect(find.text('Write a message…'), findsOneWidget);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isTrue,
        reason: 'a session outlives the link; an absent peer is still sendable');

    final send = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded),
    );
    expect(send.onPressed, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    grassroots.dispose();
    await tester.pump();
  });
}
