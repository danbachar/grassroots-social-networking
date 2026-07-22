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

/// Regression: the link-diagnostics line ("N links to peer · M total") must
/// render in the chat screen's app bar when the toggle is on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chat app bar shows the link-diagnostics line', (tester) async {
    final sodium = await initTestSodium();
    final keyPair = await Ed25519().newKeyPair();
    final identity =
        await GrassrootsIdentity.create(keyPair: keyPair, nickname: 'me');

    final peerKey = Uint8List.fromList(List.generate(32, (i) => i + 1));
    final peer = PeerState(
      publicKey: peerKey,
      nickname: 'peer',
      connectionState: PeerConnectionState.connected,
      transport: PeerTransport.bleDirect,
      bleCentralDeviceId: 'central:AA:BB:CC:DD:EE:FF',
      blePeripheralDeviceId: 'peripheral:AA:BB:CC:DD:EE:FF',
      bleAuthenticated: true,
    );

    final store = Store<AppState>(
      appReducer,
      initialState: AppState(
        settings: const SettingsState(showLinkDiagnostics: true),
        peers: PeersState.initial.copyWith(peers: {peer.pubkeyHex: peer}),
        transports: const TransportsState(
          bleLinks: [
            // The peer's shared over-ACL link (both roles, one address).
            BleLinkDiagnostic(
                address: 'AA:BB:CC:DD:EE:FF',
                clientRole: true,
                serverRole: true),
            // An unrelated neighbor's link.
            BleLinkDiagnostic(
                address: '11:22:33:44:55:66',
                clientRole: true,
                serverRole: false),
          ],
        ),
      ),
    );

    final grassroots = GrassrootsNetwork(
      identity: identity,
      store: store,
      sodium: sodium,
    );

    await tester.pumpWidget(MaterialApp(
      // The real app theme: its app-bar titleTextStyle (display font, XL)
      // is what could overflow-clip a two-line title, so the regression test
      // must render under it, not under the Material default.
      theme: grasslinkTheme(),
      home: ChatScreen(
        grassroots: grassroots,
        peer: peer,
        myPubkey: identity.publicKey,
        store: store,
      ),
    ));
    await tester.pump();

    expect(find.text('1 link to peer · 2 total'), findsOneWidget);

    // Tear the screen down and cancel the network's periodic timers so the
    // test zone ends with no pending timers.
    await tester.pumpWidget(const SizedBox.shrink());
    grassroots.dispose();
    await tester.pump();
  });
}
