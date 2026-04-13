import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Server-side identity derived from the owner's seed.
///
/// The anchor server does not have its own independent keypair. Instead,
/// the owner's device derives a subkey:
///
///   anchorSeed = SHA-256(ownerSeed || "bitchat-anchor")
///
/// The owner exports this 32-byte seed once and deploys it to the server.
/// The server reconstructs its Ed25519 keypair from that seed on startup.
///
/// This means:
/// - The anchor's pubkey is deterministic — the owner always knows it.
/// - The seed is the only secret the server needs.
/// - Compromising the anchor seed does not reveal the owner's key.
class AnchorIdentity {
  final Uint8List publicKey;
  final Uint8List privateKey;
  final SimpleKeyPair keyPair;
  String nickname;

  AnchorIdentity._({
    required this.publicKey,
    required this.privateKey,
    required this.keyPair,
    required this.nickname,
  });

  String get pubkeyHex =>
      publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Create identity from a 32-byte Ed25519 seed (the derived anchor seed).
  static Future<AnchorIdentity> fromSeed({
    required Uint8List seed,
    required String nickname,
  }) async {
    if (seed.length != 32) {
      throw ArgumentError('Seed must be 32 bytes, got ${seed.length}');
    }
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(seed);
    return _fromKeyPair(keyPair, nickname);
  }

  /// Create identity from a hex-encoded seed string.
  static Future<AnchorIdentity> fromSeedHex({
    required String seedHex,
    required String nickname,
  }) async {
    final seed = _hexDecode(seedHex);
    return fromSeed(seed: seed, nickname: nickname);
  }

  static Future<AnchorIdentity> _fromKeyPair(
    SimpleKeyPair keyPair,
    String nickname,
  ) async {
    final pk = await keyPair.extractPublicKey();
    final publicKey = Uint8List.fromList(pk.bytes);
    final seed = await keyPair.extractPrivateKeyBytes();
    final privateKey = Uint8List.fromList([...seed, ...pk.bytes]);

    return AnchorIdentity._(
      publicKey: publicKey,
      privateKey: privateKey,
      keyPair: keyPair,
      nickname: nickname,
    );
  }

  static Uint8List _hexDecode(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }
}
