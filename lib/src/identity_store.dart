import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models/identity.dart';

/// Persists the device's [GrassrootsIdentity] across sessions.
///
/// Internal to the networking layer: the app reaches the identity lifecycle
/// through `GrassrootsNetwork.putIdentity` / `GrassrootsNetwork.getIdentity`
/// (spec `docs/GLP_Networking_API/sections/api.tex` §Identity), which are this
/// store's only callers. The Ed25519 key pair lives in the platform secure
/// keystore (iOS Keychain / Android Keystore) via flutter_secure_storage.
class IdentityStore {
  IdentityStore._();

  /// Secure-storage key holding the JSON-encoded identity.
  static const String _storageKey = 'identity';

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  /// Persist [identity] to the secure keystore, replacing any existing one.
  ///
  /// Called by `GrassrootsNetwork.putIdentity` with a freshly generated
  /// identity, and by `updateNickname` to write back an edited nickname.
  static Future<void> putIdentity(GrassrootsIdentity identity) async {
    await _storage.write(
      key: _storageKey,
      value: jsonEncode(identity.toJson()),
    );
  }

  /// Load the persisted identity, or null if none has been stored yet.
  ///
  /// Backs `GrassrootsNetwork.getIdentity`, which is where the spec's
  /// `getIdentity() -> PubKey` contract is documented.
  static Future<GrassrootsIdentity?> getIdentity() async {
    final stored = await _storage.read(key: _storageKey);
    if (stored == null) return null;
    return GrassrootsIdentity.fromMap(
      jsonDecode(stored) as Map<String, dynamic>,
    );
  }
}
