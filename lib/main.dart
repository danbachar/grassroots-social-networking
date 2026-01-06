import 'package:bitchat_transport/bitchat_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

    var id = await BitchatIdentity.create(
      keyPair: keyPair,
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
  const DarwinInitializationSettings initializationSettingsDarwin =
      DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  const InitializationSettings initializationSettings =
      InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsDarwin,
  );
  
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

class _BitchatHomeState extends State<BitchatHome> with TickerProviderStateMixin {
  BitchatIdentity? _identity;
  Bitchat? _bitchat;
  String _status = 'Initializing...';
  final Map<String, Peer> _peers = {};
  Timer? _refreshTimer;
  final MessageStore _messageStore = MessageStore();
  int _currentIndex = 1; // Start on "Around" tab (center)
  
  // Track nickname changes for animation
  final Map<String, _NicknameChange> _nicknameChanges = {};

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
        
        // Check if nickname changed
        final oldPeer = _peers[peer.id];
        if (oldPeer != null && oldPeer.nickname != peer.nickname) {
          _showNicknameChangeAnimation(oldPeer.nickname, peer.nickname, peer.id);
        }
        
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
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
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
      body: SafeArea(
        child: IndexedStack(
          index: _currentIndex,
          children: [
            _buildChatsTab(),
            _buildAroundTab(),
            _buildProfileTab(),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomNavBar(),
    );
  }

  Widget _buildBottomNavBar() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1B3D2F), // Dark green background
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildNavItem(
                icon: Icons.chat_bubble_outline,
                label: 'Chats',
                index: 0,
                badge: _getTotalUnreadCount(),
              ),
              _buildNavItem(
                icon: Icons.radar,
                label: 'Around',
                index: 1,
                isCenter: true,
              ),
              _buildNavItem(
                icon: Icons.person_outline,
                label: 'Profile',
                index: 2,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    required int index,
    int badge = 0,
    bool isCenter = false,
  }) {
    final isSelected = _currentIndex == index;
    
    // Use orange highlight for selected item
    final Color bgColor = isSelected 
        ? const Color(0xFFE8A33C) 
        : Colors.transparent;
    final Color iconColor = isSelected 
        ? (isCenter ? Colors.black : Colors.black) 
        : Colors.white54;
    final Color textColor = isSelected 
        ? (isCenter ? Colors.black : Colors.black) 
        : Colors.white54;
    
    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(
          horizontal: isSelected ? 16 : 12,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: isSelected ? [
            BoxShadow(
              color: const Color(0xFFE8A33C).withOpacity(0.4),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ] : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  icon,
                  color: iconColor,
                  size: 24,
                ),
                if (badge > 0)
                  Positioned(
                    right: -8,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                      child: Text(
                        badge > 99 ? '99+' : badge.toString(),
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
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _getTotalUnreadCount() {
    int total = 0;
    for (final peer in _peers.values) {
      final peerHex = ChatMessage.pubkeyToHex(peer.publicKey);
      total += _messageStore.getUnreadCount(peerHex);
    }
    return total;
  }

  // ===== CHATS TAB =====
  Widget _buildChatsTab() {
    final chatsWithMessages = _getChatsWithMessages();
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Chats',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(
          child: chatsWithMessages.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                        'No chats yet',
                        style: TextStyle(color: Colors.grey, fontSize: 16),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Start a conversation from\nthe Around tab',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: chatsWithMessages.length,
                  itemBuilder: (context, index) {
                    final chat = chatsWithMessages[index];
                    return _buildChatListItem(chat);
                  },
                ),
        ),
      ],
    );
  }

  List<_ChatPreview> _getChatsWithMessages() {
    final chats = <_ChatPreview>[];
    final myHex = _identity != null ? ChatMessage.pubkeyToHex(_identity!.publicKey) : '';
    
    // Get all conversation partners from message store
    final conversations = _messageStore.getConversations(myHex);
    
    for (final peerHex in conversations) {
      final messages = _messageStore.getMessages(peerHex);
      if (messages.isEmpty) continue;
      
      final lastMessage = messages.last;
      final peer = _peers.values.where((p) => 
        ChatMessage.pubkeyToHex(p.publicKey) == peerHex
      ).firstOrNull;
      
      chats.add(_ChatPreview(
        peerHex: peerHex,
        peer: peer,
        lastMessage: lastMessage,
        unreadCount: _messageStore.getUnreadCount(peerHex),
      ));
    }
    
    // Sort by last message time (newest first)
    chats.sort((a, b) => b.lastMessage.timestamp.compareTo(a.lastMessage.timestamp));
    return chats;
  }

  Widget _buildChatListItem(_ChatPreview chat) {
    final displayName = chat.peer?.displayName ?? 'Peer ${chat.peerHex.substring(0, 8)}...';
    final isOnline = chat.peer != null && chat.peer!.connectionState == PeerConnectionState.connected;
    
    return ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: Colors.blueGrey,
            child: Text(
              displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
              style: const TextStyle(color: Colors.white),
            ),
          ),
          if (isOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black, width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(child: Text(displayName)),
          if (chat.unreadCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                chat.unreadCount.toString(),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
        ],
      ),
      subtitle: Text(
        chat.lastMessage.content,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: chat.unreadCount > 0 ? Colors.white : Colors.grey,
          fontWeight: chat.unreadCount > 0 ? FontWeight.w500 : FontWeight.normal,
        ),
      ),
      trailing: Text(
        _formatMessageTime(chat.lastMessage.timestamp),
        style: const TextStyle(color: Colors.grey, fontSize: 12),
      ),
      onTap: () {
        if (chat.peer != null) {
          _openChat(chat.peer!);
        }
      },
    );
  }

  String _formatMessageTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${time.day}/${time.month}';
  }

  // ===== AROUND TAB =====
  Widget _buildAroundTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Text(
                'Around',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: _showPeerLookupDialog,
                tooltip: 'Look up peer by public key',
              ),
            ],
          ),
        ),
        // Status bar
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _status == 'Running' ? Colors.green.withOpacity(0.2) : Colors.orange.withOpacity(0.2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _status == 'Running' ? Colors.green : Colors.orange,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _status == 'Running' ? 'Scanning for peers...' : _status,
                style: const TextStyle(fontSize: 13),
              ),
              const Spacer(),
              Text(
                '${_peers.length} nearby',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: _peers.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.radar, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                        'No peers nearby',
                        style: TextStyle(color: Colors.grey, fontSize: 16),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Make sure Bluetooth is enabled\non both devices',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _peers.length,
                  itemBuilder: (context, index) {
                    // Sort peers by RSSI (strongest first)
                    final sortedPeers = _peers.values.toList()
                      ..sort((a, b) => (b.rssi ?? -100).compareTo(a.rssi ?? -100));
                    final peer = sortedPeers[index];
                    return _buildPeerListItem(peer);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildPeerListItem(Peer peer) {
    final peerHex = ChatMessage.pubkeyToHex(peer.publicKey);
    final unreadCount = _messageStore.getUnreadCount(peerHex);
    
    // RSSI signal strength indicator
    IconData signalIcon;
    Color signalColor;
    if (peer.rssi == null || peer.rssi! < -80) {
      signalIcon = Icons.signal_cellular_alt_1_bar;
      signalColor = Colors.red;
    } else if (peer.rssi! < -60) {
      signalIcon = Icons.signal_cellular_alt_2_bar;
      signalColor = Colors.orange;
    } else {
      signalIcon = Icons.signal_cellular_alt;
      signalColor = Colors.green;
    }
    
    // Check if this peer has a recent nickname change
    final nicknameChange = _nicknameChanges[peer.id];
    final isChanging = nicknameChange != null;
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: isChanging ? Border.all(color: const Color(0xFFE8A33C), width: 2) : null,
        ),
        child: ListTile(
          leading: Stack(
            children: [
              CircleAvatar(
                backgroundColor: Colors.blueGrey,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    peer.displayName.isNotEmpty ? peer.displayName[0].toUpperCase() : '?',
                    key: ValueKey(peer.displayName),
                    style: const TextStyle(color: Colors.white),
                  ),
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
                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      unreadCount > 99 ? '99+' : unreadCount.toString(),
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          title: Row(
            children: [
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.5),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    );
                  },
                  child: Text(
                    peer.displayName,
                    key: ValueKey(peer.displayName),
                    style: TextStyle(
                      color: isChanging ? const Color(0xFFE8A33C) : null,
                      fontWeight: isChanging ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ),
              peer.transport.icon,
            ],
          ),
          subtitle: Text(
            peer.lastSeen != null
                ? 'Last seen: ${_formatSecondsAgo(peer.lastSeen!)}'
                : 'Connecting...',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(signalIcon, color: signalColor, size: 20),
                  Text(
                    peer.rssi != null ? '${peer.rssi} dBm' : '--',
                    style: TextStyle(fontSize: 10, color: signalColor),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.chat_bubble_outline),
                color: Colors.blue,
                onPressed: () => _openChat(peer),
              ),
            ],
          ),
          onTap: () => _openChat(peer),
        ),
      ),
    );
  }

  void _showPeerLookupDialog() {
    final controller = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Look up Peer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter public key (hex) to check if peer is reachable:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'Public key (64 hex chars)',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _lookupPeer(controller.text.trim());
            },
            child: const Text('Look up'),
          ),
        ],
      ),
    );
  }

  void _lookupPeer(String hexPubkey) {
    if (hexPubkey.isEmpty || _bitchat == null) return;
    
    try {
      // Convert hex to bytes
      final pubkeyBytes = Uint8List.fromList(
        List.generate(
          hexPubkey.length ~/ 2,
          (i) => int.parse(hexPubkey.substring(i * 2, i * 2 + 2), radix: 16),
        ),
      );
      
      final isReachable = _bitchat!.isPeerReachable(pubkeyBytes);
      final peer = _bitchat!.getPeer(pubkeyBytes);
      
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(isReachable ? '✅ Peer Reachable' : '❌ Peer Not Reachable'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (peer != null) ...[
                Text('Nickname: ${peer.displayName}'),
                Text('Status: ${peer.connectionState.name}'),
                if (peer.rssi != null) Text('Signal: ${peer.rssi} dBm'),
                if (peer.lastSeen != null) Text('Last seen: ${_formatSecondsAgo(peer.lastSeen!)}'),
              ] else
                const Text('Peer not found in known peers list.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
            if (peer != null)
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  _openChat(peer);
                },
                child: const Text('Open Chat'),
              ),
          ],
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid public key format: $e')),
      );
    }
  }

  // ===== PROFILE TAB =====
  Widget _buildProfileTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Profile',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          
          // Avatar
          Center(
            child: CircleAvatar(
              radius: 50,
              backgroundColor: Colors.blueGrey,
              child: Text(
                _identity?.nickname.isNotEmpty == true 
                    ? _identity!.nickname[0].toUpperCase() 
                    : '?',
                style: const TextStyle(fontSize: 40, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 16),
          
          // Nickname with edit button
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _identity?.nickname ?? 'Loading...',
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.edit, size: 20),
                  onPressed: _showEditNicknameDialog,
                  tooltip: 'Edit nickname',
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          
          // Info cards
          _buildInfoCard(
            title: 'Fingerprint',
            value: _identity?.shortFingerprint ?? '...',
            icon: Icons.fingerprint,
            onCopy: () => _copyToClipboard(_identity?.shortFingerprint ?? ''),
          ),
          const SizedBox(height: 12),
          
          _buildInfoCard(
            title: 'Service UUID',
            value: _identity?.bleServiceUuid ?? '...',
            icon: Icons.bluetooth,
            onCopy: () => _copyToClipboard(_identity?.bleServiceUuid ?? ''),
          ),
          const SizedBox(height: 12),
          
          _buildInfoCard(
            title: 'Public Key',
            value: _identity != null 
                ? ChatMessage.pubkeyToHex(_identity!.publicKey)
                : '...',
            icon: Icons.key,
            onCopy: () => _copyToClipboard(
              _identity != null ? ChatMessage.pubkeyToHex(_identity!.publicKey) : ''
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 12),
          
          // Transport status
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _status == 'Running' ? Icons.check_circle : Icons.error,
                        color: _status == 'Running' ? Colors.green : Colors.orange,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Transport Status',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(_status),
                  const SizedBox(height: 4),
                  Text(
                    '${_peers.length} connected peers',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard({
    required String title,
    required String value,
    required IconData icon,
    VoidCallback? onCopy,
    int maxLines = 1,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: Colors.grey),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const Spacer(),
                if (onCopy != null)
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: onCopy,
                    tooltip: 'Copy',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  void _showEditNicknameDialog() {
    if (_identity == null) return;
    
    final controller = TextEditingController(text: _identity!.nickname);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Nickname'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Enter new nickname',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          maxLength: 30,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newNickname = controller.text.trim();
              if (newNickname.isNotEmpty && _bitchat != null) {
                Navigator.pop(context);
                await _updateNickname(newNickname);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _updateNickname(String newNickname) async {
    if (_bitchat == null || _identity == null) return;
    
    // Update nickname via Bitchat (broadcasts ANNOUNCE)
    await _bitchat!.updateNickname(newNickname);
    
    // Persist to secure storage
    const storage = FlutterSecureStorage();
    await storage.write(
      key: 'identity',
      value: jsonEncode(_identity!.toJson()),
    );
    
    setState(() {});
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Nickname updated!')),
    );
  }

  void _showNicknameChangeAnimation(String oldName, String newName, String peerId) {
    // Store the nickname change for UI animation
    _nicknameChanges[peerId] = _NicknameChange(
      oldName: oldName,
      newName: newName,
      timestamp: DateTime.now(),
    );
    
    // Show a snackbar notification
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.person, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(color: Colors.white),
                  children: [
                    TextSpan(
                      text: oldName.isEmpty ? 'Unknown' : oldName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.lineThrough,
                        color: Colors.white70,
                      ),
                    ),
                    const TextSpan(text: ' → '),
                    TextSpan(
                      text: newName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF1B3D2F),
      ),
    );
    
    // Clear the animation after a delay
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _nicknameChanges.remove(peerId);
        });
      }
    });
  }
}

/// Helper class for tracking nickname changes
class _NicknameChange {
  final String oldName;
  final String newName;
  final DateTime timestamp;

  _NicknameChange({
    required this.oldName,
    required this.newName,
    required this.timestamp,
  });
}

/// Helper class for chat list preview
class _ChatPreview {
  final String peerHex;
  final Peer? peer;
  final ChatMessage lastMessage;
  final int unreadCount;

  _ChatPreview({
    required this.peerHex,
    required this.peer,
    required this.lastMessage,
    required this.unreadCount,
  });
}
