import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redux/redux.dart';
import 'package:grassroots_networking/src/grassroots_network.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/store/store.dart';

import 'helpers/sodium_test_bootstrap.dart';

/// The identity lifecycle is the coordinator's public API — spec
/// `putIdentity()` / `getIdentity()` (`docs/GLP_Networking_API/sections/api.tex`
/// §Identity). The app never touches the keystore itself, so these tests drive
/// the two statics and let the real `IdentityStore` write through to an
/// in-memory secure storage.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> keystore;

  setUp(() {
    keystore = <String, String>{};
    FlutterSecureStorage.setMockInitialValues(keystore);
  });

  test('getIdentity returns null on a device that has never launched',
      () async {
    expect(await GrassrootsNetwork.getIdentity(), isNull);
  });

  test('putIdentity generates an identity that getIdentity restores', () async {
    final created = await GrassrootsNetwork.putIdentity();

    final restored = await GrassrootsNetwork.getIdentity();

    expect(restored, isNotNull);
    expect(restored!.publicKey, created.publicKey,
        reason: 'the persisted key pair is the one putIdentity generated');
    expect(restored.privateKey, created.privateKey);
    expect(restored.nickname, created.nickname);
  });

  test('putIdentity replaces the identity already in the keystore', () async {
    final first = await GrassrootsNetwork.putIdentity();

    final second = await GrassrootsNetwork.putIdentity();

    expect(second.publicKey, isNot(first.publicKey),
        reason: 'a regenerate must produce a fresh key pair');
    final restored = await GrassrootsNetwork.getIdentity();
    expect(restored!.publicKey, second.publicKey,
        reason: 'the newest identity is the one that survives a restart');
  });

  test('putIdentity honours a caller-supplied nickname', () async {
    await GrassrootsNetwork.putIdentity(nickname: 'Alice');

    final restored = await GrassrootsNetwork.getIdentity();

    expect(restored!.nickname, 'Alice');
  });

  test('updateNickname persists the new nickname', () async {
    final sodium = await initTestSodium();
    final identity = await GrassrootsIdentity.create(
      keyPair: await Ed25519().newKeyPair(),
      nickname: 'before',
    );
    final grassroots = GrassrootsNetwork(
      identity: identity,
      store: Store<AppState>(appReducer, initialState: const AppState()),
      sodium: sodium,
    );
    addTearDown(grassroots.dispose);

    await grassroots.updateNickname('after');

    final restored = await GrassrootsNetwork.getIdentity();
    expect(restored, isNotNull,
        reason: 'the method that mutates the nickname is the one that must '
            'durably record it — no caller follow-up');
    expect(restored!.nickname, 'after');
    expect(restored.publicKey, identity.publicKey,
        reason: 'a nickname edit must not disturb the key pair');
  });

  test('updateNickname ignores an empty nickname', () async {
    final sodium = await initTestSodium();
    final identity = await GrassrootsIdentity.create(
      keyPair: await Ed25519().newKeyPair(),
      nickname: 'before',
    );
    final grassroots = GrassrootsNetwork(
      identity: identity,
      store: Store<AppState>(appReducer, initialState: const AppState()),
      sodium: sodium,
    );
    addTearDown(grassroots.dispose);

    await grassroots.updateNickname('');

    expect(identity.nickname, 'before');
    expect(keystore, isEmpty,
        reason: 'a rejected edit must not write to the keystore');
  });
}
