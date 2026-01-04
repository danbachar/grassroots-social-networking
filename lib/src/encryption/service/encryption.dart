import 'dart:typed_data';

import 'package:bitchat_transport/src/encryption/interface/encryption.dart';
import 'package:encrypt/encrypt.dart';
import 'package:pointycastle/asymmetric/api.dart';

// class EncryptionService extends EncryptionLayer {
//   @override
//   void init() {
//       // final encrypter = Encrypter(RSA(publicKey: publicKey, privateKey: privKey));
//   }

//   @override
//   Future<Uint8List> encryptForPeer(
//       Uint8List peerPubkey, Uint8List payload) async {
//       }
// }