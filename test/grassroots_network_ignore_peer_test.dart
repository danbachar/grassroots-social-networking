import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redux/redux.dart';
import 'package:grassroots_networking/src/grassroots_network.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/models/packet.dart';
import 'package:grassroots_networking/src/session/noise_session_manager.dart';
import 'package:grassroots_networking/src/store/store.dart';

import 'helpers/sodium_test_bootstrap.dart';

/// The testbed ignore list at the coordinator: ignoring a phone drops the
/// session we hold with it and refuses the one it will try to open next, so
/// the session table — which the ring roster is read from — stays clean for
/// as long as the phone is ignored.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String hexOf(Uint8List pubkey) =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  GrassrootsPacket handshakePacket(Uint8List payload) => GrassrootsPacket(
        type: PacketType.noiseHandshake,
        ttl: 0,
        payload: payload,
      );

  late Store<AppState> store;
  late GrassrootsNetwork grassroots;
  late GrassrootsIdentity stray;
  late NoiseSessionManager straySessions;

  /// The stray dials us: msg1 in, and whatever we answer with drives the rest
  /// of the exchange. Returns whether a session came out of it on our side.
  Future<bool> strayPairsWithUs() async {
    final m1 = await straySessions.startHandshake(grassroots.identity.publicKey);
    final r1 = await grassroots.noiseSessions.handleHandshakePacket(
      handshakePacket(m1!),
      remotePubkey: stray.publicKey,
    );
    if (r1.responsePayload == null) return false;
    final r2 = await straySessions.handleHandshakePacket(
      handshakePacket(r1.responsePayload!),
      remotePubkey: grassroots.identity.publicKey,
    );
    final finished = await grassroots.noiseSessions.handleHandshakePacket(
      handshakePacket(r2.responsePayload!),
      remotePubkey: stray.publicKey,
    );
    return finished.sessionEstablished;
  }

  setUp(() async {
    final sodium = await initTestSodium();
    store = Store<AppState>(appReducer, initialState: const AppState());
    grassroots = GrassrootsNetwork(
      identity: await GrassrootsIdentity.create(
        keyPair: await Ed25519().newKeyPair(),
        nickname: 'me',
      ),
      store: store,
      sodium: sodium,
    );
    addTearDown(grassroots.dispose);
    stray = await GrassrootsIdentity.create(
      keyPair: await Ed25519().newKeyPair(),
      nickname: 'stray',
    );
    straySessions = NoiseSessionManager(identity: stray, sodium: sodium);
    addTearDown(straySessions.dispose);
  });

  test('ignoring a phone drops the session we hold with it', () async {
    expect(await strayPairsWithUs(), isTrue);
    expect(grassroots.noiseSessionPeerHexes, contains(hexOf(stray.publicKey)));

    await grassroots.ignorePeerForTestbed(stray.publicKey);

    expect(grassroots.noiseSessionPeerHexes, isEmpty);
    expect(store.state.settings.ignoredPeerHexes, {hexOf(stray.publicKey)});
  });

  test('an ignored phone cannot pair its way back in', () async {
    await grassroots.ignorePeerForTestbed(stray.publicKey);
    straySessions.reset(grassroots.identity.publicKey);

    expect(await strayPairsWithUs(), isFalse);
    expect(grassroots.noiseSessionPeerHexes, isEmpty);
  });

  test('once no longer ignored the phone pairs again', () async {
    await grassroots.ignorePeerForTestbed(stray.publicKey);
    grassroots.unignorePeerForTestbed(hexOf(stray.publicKey));
    straySessions.reset(grassroots.identity.publicKey);

    expect(await strayPairsWithUs(), isTrue);
    expect(store.state.settings.ignoredPeerHexes, isEmpty);
  });
}
