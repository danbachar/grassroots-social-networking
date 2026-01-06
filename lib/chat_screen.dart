import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bitchat_transport/bitchat_transport.dart';
import 'chat_models.dart';

/// Chat screen for a conversation with a specific peer
class ChatScreen extends StatefulWidget {
  final Bitchat bitchat;
  final Peer peer;
  final Uint8List myPubkey;
  final MessageStore messageStore;

  const ChatScreen({
    super.key,
    required this.bitchat,
    required this.peer,
    required this.myPubkey,
    required this.messageStore,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  String get _peerHex => ChatMessage.pubkeyToHex(widget.peer.publicKey);
  String get _myHex => ChatMessage.pubkeyToHex(widget.myPubkey);

  @override
  void initState() {
    super.initState();
    widget.messageStore.addListener(_onMessagesChanged);
    // Mark messages as read when opening chat
    widget.messageStore.markAsRead(_peerHex);
  }

  @override
  void dispose() {
    widget.messageStore.removeListener(_onMessagesChanged);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onMessagesChanged() {
    setState(() {});
    _scrollToBottom();
  }

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();

    // Create outgoing message
    final message = ChatMessage(
      senderPubkeyHex: _myHex,
      recipientPubkeyHex: _peerHex,
      content: text,
      isOutgoing: true,
    );

    // Store locally and in message store
    await widget.messageStore.saveMessage(message);

    // Send via Bitchat
    await widget.bitchat.send(widget.peer.publicKey, Uint8List.fromList(text.codeUnits));

    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _copyMessage(ChatMessage message) {
    Clipboard.setData(ClipboardData(text: message.content));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Message copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _forwardMessage(ChatMessage message) {
    // Show dialog to select a peer to forward to
    final peers = widget.bitchat.connectedPeers;
    
    if (peers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No connected peers to forward to'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _ForwardSheet(
        message: message,
        peers: peers,
        onForward: (peer) async {
          Navigator.pop(context);
          await widget.bitchat.send(
            peer.publicKey,
            Uint8List.fromList(message.content.codeUnits),
          );
          
          // Also save to message store as outgoing
          final forwardedMessage = ChatMessage(
            senderPubkeyHex: _myHex,
            recipientPubkeyHex: ChatMessage.pubkeyToHex(peer.publicKey),
            content: message.content,
            isOutgoing: true,
          );
          await widget.messageStore.saveMessage(forwardedMessage);
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Message forwarded to ${peer.displayName}'),
                duration: const Duration(seconds: 2),
              ),
            );
          }
        },
      ),
    );
  }

  void _showMessageOptions(ChatMessage message, Offset tapPosition) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        tapPosition.dx,
        tapPosition.dy,
        tapPosition.dx + 1,
        tapPosition.dy + 1,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        PopupMenuItem(
          onTap: () => _copyMessage(message),
          child: const Row(
            children: [
              Icon(Icons.copy, size: 20),
              SizedBox(width: 12),
              Text('Copy'),
            ],
          ),
        ),
        PopupMenuItem(
          onTap: () => Future.delayed(
            const Duration(milliseconds: 10),
            () => _forwardMessage(message),
          ),
          child: const Row(
            children: [
              Icon(Icons.forward, size: 20),
              SizedBox(width: 12),
              Text('Forward'),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.peer.nickname.isNotEmpty
            ? widget.peer.nickname
            : 'Peer ${_peerHex.substring(0, 8)}...'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: widget.messageStore.getMessages(_peerHex).length,
              itemBuilder: (context, index) {
                final message = widget.messageStore.getMessages(_peerHex)[index];
                return _MessageBubble(
                  message: message,
                  onLongPress: (position) => _showMessageOptions(message, position),
                );
              },
            ),
          ),
          _buildMessageInput(),
        ],
      ),
    );
  }

  Widget _buildMessageInput() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _messageController,
              decoration: const InputDecoration(
                hintText: 'Type a message...',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.send),
            onPressed: _sendMessage,
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final void Function(Offset position)? onLongPress;

  const _MessageBubble({
    required this.message,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: message.isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPressStart: (details) {
          onLongPress?.call(details.globalPosition);
        },
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          decoration: BoxDecoration(
            color: message.isOutgoing
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                message.content,
                style: TextStyle(
                  color: message.isOutgoing ? Colors.white : null,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _formatTime(message.timestamp),
                style: TextStyle(
                  fontSize: 10,
                  color: message.isOutgoing 
                      ? Colors.white70 
                      : Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

/// Bottom sheet for selecting a peer to forward message to
class _ForwardSheet extends StatelessWidget {
  final ChatMessage message;
  final List<Peer> peers;
  final void Function(Peer peer) onForward;

  const _ForwardSheet({
    required this.message,
    required this.peers,
    required this.onForward,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle bar
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Text(
            'Forward to',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          // Message preview
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              message.content.length > 100 
                  ? '${message.content.substring(0, 100)}...' 
                  : message.content,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Select peer:',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 8),
          // Peer list
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.4,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: peers.length,
              itemBuilder: (context, index) {
                final peer = peers[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.blueGrey,
                    child: Text(
                      peer.displayName.isNotEmpty 
                          ? peer.displayName[0].toUpperCase() 
                          : '?',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  title: Text(peer.displayName),
                  subtitle: Text(
                    peer.connectionState == PeerConnectionState.connected
                        ? 'Online'
                        : 'Offline',
                    style: TextStyle(
                      color: peer.connectionState == PeerConnectionState.connected
                          ? Colors.green
                          : Colors.grey,
                      fontSize: 12,
                    ),
                  ),
                  trailing: const Icon(Icons.send, size: 20),
                  onTap: () => onForward(peer),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
