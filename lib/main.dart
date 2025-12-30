import 'package:bitchat_transport/bitchat_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert'; // Import dart:convert for JSON handling
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

Future<BitchatIdentity> _initIdentity() async {
  const storage = FlutterSecureStorage();
  var identityValue = await storage.read(key: 'identity');
  if (identityValue == null) {
    print('No identity found, generating new one.');
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes(); // 32-byte seed
    final publicKey = await keyPair.extractPublicKey();
    final publicKeyBytes = publicKey.bytes;
    
    // Ed25519 private key format: seed (32 bytes) + public key (32 bytes) = 64 bytes
    final privateKey64 = Uint8List.fromList([...seed, ...publicKeyBytes]);

    String nickname = 'User_${publicKeyBytes.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

    var id = BitchatIdentity(
      publicKey: Uint8List.fromList(publicKeyBytes), 
      privateKey: privateKey64,
      nickname: nickname,
    );

    identityValue = jsonEncode(id.toJson());
    await storage.write(key: 'identity', value: identityValue);
  } else {
    print('Identity found in secure storage.');
  }

  final BitchatIdentity identity = BitchatIdentity.fromMap(jsonDecode(identityValue));

  print('Private Key Bytes (Seed): ${identity.privateKey.length} bytes');
  print('Public Key Bytes: ${identity.publicKey.length} bytes');
  print('Nickname: ${identity.nickname}');
  return identity;
}

void main() async {
  runApp(const MainApp());
  final identity = await _initIdentity();
  final bitchat = Bitchat(identity: identity);

  bitchat.onMessageReceived = (senderPubkey, payload) {
  print('Received ${payload.length} bytes from ${senderPubkey}');
  // Handle GSG block
};

bitchat.onPeerConnected = (peer) {
  print('Peer connected: ${peer.displayName}');
  // Start cordial dissemination
};

bitchat.onPeerDisconnected = (peer) {
  print('Peer disconnected: ${peer.displayName}');
};

// Initialize (requests permissions, starts BLE)
final success = await bitchat.initialize();
if (!success) {
  print('Failed to initialize: ${bitchat.status}');
  return;
}

}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('Hello World!'),
        ),
      ),
    );
  }
}
