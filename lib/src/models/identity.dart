import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Identity provided by GSG layer to Bitchat transport.
/// 
/// GSG is responsible for:
/// - Generating and persisting the Ed25519 keypair
/// - Passing it to Bitchat at initialization
/// 
/// Bitchat uses this for:
/// - Deriving BLE Service UUID (Grassroots prefix + last 64 bits of pubkey)
/// - Signing packets
/// - Peer identification via ANNOUNCE
class BitchatIdentity {
  /// Ed25519 public key (32 bytes)
  late final Uint8List publicKey;
  
  /// Ed25519 private key (64 bytes - seed + public key)
  /// This is kept private and used only for signing
  late final Uint8List privateKey;

  final SimpleKeyPair keyPair;
  
  /// Optional human-readable nickname for ANNOUNCE (mutable)
  String nickname;
  
  // Private constructor - use create() factory method instead
  BitchatIdentity._internal({
    required this.keyPair,
    required this.nickname,
    required this.publicKey,
    required this.privateKey,
  });
  
  /// Create identity from a keypair (use this instead of constructor)
  static Future<BitchatIdentity> create({
    required SimpleKeyPair keyPair,
    required String nickname,
  }) async {
    final pk = await keyPair.extractPublicKey();
    final publicKey = Uint8List.fromList(pk.bytes);
    if (publicKey.length != 32) {
      throw ArgumentError('Public key must be 32 bytes (Ed25519)');
    }
    
    final seed = await keyPair.extractPrivateKeyBytes();
    final privateKey = Uint8List.fromList([...seed, ...pk.bytes]);
    if (privateKey.length != 64) {
      throw ArgumentError('Private key must be 64 bytes (Ed25519 seed + pubkey)');
    }
    
    return BitchatIdentity._internal(
      keyPair: keyPair,
      publicKey: publicKey,
      privateKey: privateKey,
      nickname: nickname,
    );
  }
  
  /// Static 8-byte prefix identifying Grassroots devices on BLE.
  /// First 8 bytes of SHA-256("grassroots").
  static const String grassrootsUuidPrefix = '84c403160871e5ad';

  /// Derive BLE Service UUID from a public key.
  /// Format: Grassroots prefix (8 bytes) + last 8 bytes of public key.
  static String deriveServiceUuid(Uint8List pubkey) {
    if (pubkey.length < 32) {
      throw ArgumentError('Public key must be at least 32 bytes');
    }
    final suffixBytes = pubkey.sublist(24, 32);
    final suffix =
        suffixBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final hex = '$grassrootsUuidPrefix$suffix';
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  /// BLE Service UUID for this identity.
  String get bleServiceUuid => deriveServiceUuid(publicKey);

  /// Get fingerprint (first 8 bytes of SHA-256 hash of public key) for display
  /// Full verification uses the complete public key
  String get shortFingerprint {
    // TODO: Implement SHA-256 hash and take first 8 bytes
    // For now, use first 8 bytes of pubkey as placeholder
    return publicKey.sublist(0, 8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(':')
        .toUpperCase();
  }
  
  @override
  String toString() => 'BitchatIdentity($nickname)';

  static BitchatIdentity fromMap(Map<String, dynamic> map) {
    final pk = Uint8List.fromList(List<int>.from(map['publicKey']));
    final privatek = Uint8List.fromList(List<int>.from(map['privateKey']));
    final keyPair = SimpleKeyPairData(
      privatek.sublist(0, 32),
      publicKey: SimplePublicKey(pk, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    );
    // Use internal constructor since we already have validated keys from storage
    return BitchatIdentity._internal(
      keyPair: keyPair,
      publicKey: pk,
      privateKey: privatek,
      nickname: map['nickname'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'publicKey': publicKey,
      'privateKey': privateKey,
      'nickname': nickname,
    };
  }
}
