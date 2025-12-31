import 'package:bitchat_transport/bitchat_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'package:cryptography/cryptography.dart';
import 'chat_screen.dart';
import 'chat_models.dart';

// Global notification plugin instance
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// Global key for navigation from notification
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Pending chat to open from notification
String? _pendingChatPeerHex;

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
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize notifications
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);
  
  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      // Handle notification tap - store the peer to open chat with
      if (response.payload != null) {
        _pendingChatPeerHex = response.payload;
      }
    },
  );
  
  // Request notification permission (Android 13+)
  await Permission.notification.request();
  
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      theme: ThemeData.dark(),
      home: const BitchatHome(),
    );
  }
}

class BitchatHome extends StatefulWidget {
  const BitchatHome({super.key});

  @override
  State<BitchatHome> createState() => _BitchatHomeState();
}

class _BitchatHomeState extends State<BitchatHome> {
  BitchatIdentity? _identity;
  Bitchat? _bitchat;
  String _status = 'Initializing...';
  final Map<String, Peer> _peers = {};
  Timer? _refreshTimer;
  final MessageStore _messageStore = MessageStore();

  @override
  void initState() {
    super.initState();
    _messageStore.addListener(_onMessagesChanged);
    _initialize();
    // Refresh UI every second to update "seconds ago" display
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
        // Check for pending chat from notification
        _checkPendingChat();
      }
    });
  }
  
  void _onMessagesChanged() {
    setState(() {});
  }
  
  void _checkPendingChat() {
    if (_pendingChatPeerHex != null && _bitchat != null && _identity != null) {
      final peerHex = _pendingChatPeerHex!;
      _pendingChatPeerHex = null;
      
      // Find the peer
      final peer = _peers.values.where((p) => 
        ChatMessage.pubkeyToHex(p.publicKey) == peerHex
      ).firstOrNull;
      
      if (peer != null) {
        _openChat(peer);
      }
    }
  }

  @override
  void dispose() {
    _messageStore.removeListener(_onMessagesChanged);
    _refreshTimer?.cancel();
    _bitchat?.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await _messageStore.initialize();
      final identity = await _initIdentity();
      final bitchat = Bitchat(identity: identity);

      bitchat.onMessageReceived = (senderPubkey, payload) {
        print('Received ${payload.length} bytes from $senderPubkey');
        _handleIncomingMessage(senderPubkey, payload);
      };

      bitchat.onPeerConnected = (peer) {
        print('Peer connected: ${peer.displayName}');
        setState(() {
          _peers[peer.id] = peer;
        });
      };

      bitchat.onPeerUpdated = (peer) {
        print('Peer updated: ${peer.displayName}');
        setState(() {
          _peers[peer.id] = peer;
        });
      };

      bitchat.onPeerDisconnected = (peer) {
        print('Peer disconnected: ${peer.displayName}');
        setState(() {
          _peers.remove(peer.id);
        });
      };

      setState(() {
        _identity = identity;
        _bitchat = bitchat;
        _status = 'Starting BLE...';
      });

      final success = await bitchat.initialize();
      if (!success) {
        setState(() {
          _status = 'Failed: ${bitchat.status}';
        });
        return;
      }

      setState(() {
        _status = 'Running';
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
    }
  }
  
  Future<void> _handleIncomingMessage(Uint8List senderPubkey, Uint8List payload) async {
    final senderHex = ChatMessage.pubkeyToHex(senderPubkey);
    final myHex = ChatMessage.pubkeyToHex(_identity!.publicKey);
    final content = String.fromCharCodes(payload);
    
    // Save message
    final chatMessage = ChatMessage(
      senderPubkeyHex: senderHex,
      recipientPubkeyHex: myHex,
      content: content,
      timestamp: DateTime.now(),
      isOutgoing: false,
    );
    await _messageStore.saveMessage(chatMessage);
    
    // Find sender name
    final peer = _peers.values.where((p) => 
      ChatMessage.pubkeyToHex(p.publicKey) == senderHex
    ).firstOrNull;
    final senderName = peer?.displayName ?? 'Unknown';
    
    // Show notification
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'bitchat_messages',
      'Messages',
      channelDescription: 'Bitchat message notifications',
      importance: Importance.high,
      priority: Priority.high,
    );
    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
    );
    
    await flutterLocalNotificationsPlugin.show(
      senderHex.hashCode,
      'Message from $senderName',
      content.length > 50 ? '${content.substring(0, 50)}...' : content,
      notificationDetails,
      payload: senderHex,
    );
  }
  
  void _openChat(Peer peer) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          peer: peer,
          bitchat: _bitchat!,
          myPubkey: _identity!.publicKey,
          messageStore: _messageStore,
        ),
      ),
    );
  }

  String _formatSecondsAgo(DateTime time) {
    final seconds = DateTime.now().difference(time).inSeconds;
    if (seconds < 60) {
      return '${seconds}s ago';
    } else if (seconds < 3600) {
      return '${seconds ~/ 60}m ago';
    } else {
      return '${seconds ~/ 3600}h ago';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bitchat Transport'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Identity section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'My Identity',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    if (_identity != null) ...[
                      Text('Nickname: ${_identity!.nickname}'),
                      Text('Fingerprint: ${_identity!.shortFingerprint}'),
                      Text('Service UUID: ${_identity!.bleServiceUuid}'),
                    ] else
                      const Text('Loading...'),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 8),
            
            // Status
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _status == 'Running' ? Colors.green : Colors.orange,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('Status: $_status'),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            
            // Peers section
            Text(
              'Connected Peers (${_peers.length})',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            
            Expanded(
              child: _peers.isEmpty
                  ? const Center(
                      child: Text(
                        'No peers connected\nSearching...',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _peers.length,
                      itemBuilder: (context, index) {
                        final peer = _peers.values.elementAt(index);
                        final peerHex = ChatMessage.pubkeyToHex(peer.publicKey);
                        final unreadCount = _messageStore.getUnreadCount(peerHex);
                        return Card(
                          child: ListTile(
                            leading: Stack(
                              children: [
                                CircleAvatar(
                                  backgroundColor: Colors.blueGrey,
                                  child: Text(
                                    peer.displayName.isNotEmpty 
                                        ? peer.displayName[0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                                if (unreadCount > 0)
                                  Positioned(
                                    right: 0,
                                    top: 0,
                                    child: Container(
                                      padding: const EdgeInsets.all(2),
                                      decoration: BoxDecoration(
                                        color: Colors.red,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      constraints: const BoxConstraints(
                                        minWidth: 16,
                                        minHeight: 16,
                                      ),
                                      child: Text(
                                        unreadCount > 99 ? '99+' : unreadCount.toString(),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            title: Row(
                              children: [
                                Expanded(child: Text(peer.displayName)),
                                // Transport icon
                                Tooltip(
                                  message: peer.transport.displayName,
                                  child: peer.transport.icon,
                                ),
                              ],
                            ),
                            subtitle: Text(
                              peer.lastSeen != null
                                  ? 'Last ANNOUNCE: ${_formatSecondsAgo(peer.lastSeen!)}'
                                  : 'Last ANNOUNCE: unknown',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (peer.rssi != null)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Text(
                                      '${peer.rssi} dBm',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                IconButton(
                                  icon: const Icon(Icons.chat_bubble_outline),
                                  color: Colors.blue,
                                  onPressed: () => _openChat(peer),
                                ),
                              ],
                            ),
                            onTap: () => _openChat(peer),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
