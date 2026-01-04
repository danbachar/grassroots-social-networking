import 'dart:typed_data';

abstract class EncryptionLayer {

  /// Initialize objects using constructors
  init();
  
  /// Encrypts the given payload for the peer identified by their public key.
  ///
  /// Returns the encrypted payload.
  Future<Uint8List> encryptForPeer(Uint8List peerPubkey, Uint8List payload);

  /// Decrypts the given payload that was sent by the peer identified by their public key.
  /// 
  /// Returns the decrypted payload.
  Future<Uint8List> decryptFromPeer(Uint8List encryptedPayload);

  Uint8List verify(Uint8List pubKey, Uint8List data, Uint8List sig);
}