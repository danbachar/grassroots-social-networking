import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redux/redux.dart';
import 'package:grassroots_networking/src/grassroots_network.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/store/store.dart';

import 'helpers/sodium_test_bootstrap.dart';

/// A PACKET MAY NOT EXIST BEFORE A SESSION WITH ITS TARGET DOES.
///
/// The rule is enforced by ordering inside the send path — the session is
/// checked before `createMessagePacket` is reached — which means nothing fails
/// if someone later hoists the creation back above the check. These tests are
/// that guard. They assert on observable state rather than on call order, so
/// they survive refactoring of the send path but not a violation of the rule.
///
/// `bufferSnapshot()` is the witness: `dtnPackets` counts sealed packets in the
/// DTN memory buffer, `ackIndex` counts messageId -> packetId entries, and
/// `sealedContentIds` counts sealed bodies we can attribute. A packet that was
/// created and sealed shows up in all three. One that was never created shows
/// up in none.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<GrassrootsNetwork> buildNetwork(Store<AppState> store) async {
    final sodium = await initTestSodium();
    final keyPair = await Ed25519().newKeyPair();
    final identity = await GrassrootsIdentity.create(
      keyPair: keyPair,
      nickname: 'me',
    );
    return GrassrootsNetwork(
      identity: identity,
      store: store,
      sodium: sodium,
    );
  }

  test('a send to a peer we hold no session with creates no packet', () async {
    final store = Store<AppState>(appReducer, initialState: const AppState());
    final grassroots = await buildNetwork(store);
    addTearDown(grassroots.dispose);

    // Never announced, never handshaked, no peer record: a stranger.
    final stranger = Uint8List.fromList(List.generate(32, (i) => i + 1));

    final messageId = await grassroots.send(
      stranger,
      Uint8List.fromList([1, 2, 3, 4]),
    );

    expect(messageId, isNotNull,
        reason: 'the caller still gets an id so the UI can show the failure');

    final buffers = grassroots.bufferSnapshot();
    expect(buffers['dtnPackets'], 0,
        reason: 'no sealed packet may enter the DTN buffer without a session');
    expect(buffers['ackIndex'], 0,
        reason: 'no packetId may be minted for a sessionless recipient');
    expect(buffers['sealedContentIds'], 0,
        reason: 'nothing may be sealed for a peer we have never met');
  });

  test('the sessionless send fails rather than being held anywhere', () async {
    final store = Store<AppState>(appReducer, initialState: const AppState());
    final grassroots = await buildNetwork(store);
    addTearDown(grassroots.dispose);

    final stranger = Uint8List.fromList(List.generate(32, (i) => 200 - i));
    final messageId = await grassroots.send(
      stranger,
      Uint8List.fromList([9, 9, 9]),
    );

    // There is no pre-seal hold and no retry queue: the one honest outcome is
    // a visible failure. A 'queued'/'sending' status here would mean the
    // plaintext is parked somewhere waiting for a first pairing, which is the
    // design this replaced.
    final outgoing = store.state.messages.outgoingMessages[messageId];
    expect(outgoing, isNotNull);
    expect(outgoing!.status, MessageStatus.failed,
        reason: 'a message to a peer we never met fails immediately');
  });

  test('the send path does not establish the session itself', () async {
    final store = Store<AppState>(appReducer, initialState: const AppState());
    final grassroots = await buildNetwork(store);
    addTearDown(grassroots.dispose);

    final stranger = Uint8List.fromList(List.generate(32, (i) => i + 40));
    await grassroots.send(stranger, Uint8List.fromList([7]));

    // Pairing is eager and belongs to the ANNOUNCE path: every accepted
    // ANNOUNCE drives a handshake, any sessionless side initiates. Sending
    // must not be the thing that decides who we have met, so a failed send
    // leaves the session table exactly as it found it.
    expect(grassroots.bufferSnapshot()['sessions'], 0,
        reason: 'a send must not start a handshake or create a session');
  });
}
