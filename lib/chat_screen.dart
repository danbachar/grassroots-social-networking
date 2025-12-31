import 'dart:typed_data';
import 'package:flutter/material.dart';
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
                return _MessageBubble(message: message);
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

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: message.isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: message.isOutgoing
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          message.content,
          style: TextStyle(
            color: message.isOutgoing ? Colors.white : null,
          ),
        ),
      ),
    );
  }
}
