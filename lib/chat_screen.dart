import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bitchat_transport/bitchat_transport.dart';
import 'package:redux/redux.dart';
import 'chat_models.dart';
import 'package:logger/logger.dart';

/// Chat screen for a conversation with a specific peer
class ChatScreen extends StatefulWidget {
  final Bitchat bitchat;
  final PeerState peer;
  final Uint8List myPubkey;
  final Store<AppState> store;
  final VoidCallback? onSendFriendRequest;
  final VoidCallback? onAcceptFriendRequest;
  final VoidCallback? onUnfriend;
  final String? myLibp2pAddress;

  const ChatScreen({
    super.key,
    required this.bitchat,
    required this.peer,
    required this.myPubkey,
    required this.store,
    this.onSendFriendRequest,
    this.onAcceptFriendRequest,
    this.onUnfriend,
    this.myLibp2pAddress,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final Logger _log = Logger();

  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<AppState>? _storeSubscription;

  String get _peerHex => ChatMessage.pubkeyToHex(widget.peer.publicKey);
  String get _myHex => ChatMessage.pubkeyToHex(widget.myPubkey);

  FriendshipState? get _friendship =>
      widget.store.state.friendships.getFriendship(_peerHex);
  bool get _isFriend => _friendship?.isAccepted ?? false;
  bool get _hasPendingIncoming => _friendship?.isPendingIncoming ?? false;
  bool get _hasPendingOutgoing => _friendship?.isPendingOutgoing ?? false;

  @override
  void initState() {
    super.initState();
    // Listen to Redux store for all state updates
    _storeSubscription =
        widget.store.onChange.listen((_) => _onStoreChanged());
    // Mark messages as read and send read receipts when opening chat
    widget.store.dispatch(MarkMessagesReadAction(_peerHex));
    _sendReadReceipts();
  }

  /// Send read receipts for all unread incoming messages
  void _sendReadReceipts() {
    final messages = widget.store.state.messages.getConversation(_peerHex);
    final senderPubkey = widget.peer.publicKey;

    for (final message in messages) {
      // Only send read receipts for incoming messages with a messageId
      if (!message.isOutgoing && message.messageId != null) {
        widget.bitchat.sendReadReceipt(
          messageId: message.messageId!,
          senderPubkey: senderPubkey,
        );
      }
    }
  }

  @override
  void dispose() {
    _storeSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    // Rebuild to update messages, friendships, and status checkmarks
    if (mounted) {
      setState(() {});
      _scrollToBottom();
    }
  }

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();

    // Send via Bitchat using SayBlock - get messageId for tracking
    final block = SayBlock(content: text);
    _log.i("Sending '$text' to peer ${widget.peer.displayName}");
    final messageId =
        await widget.bitchat.send(widget.peer.publicKey, block.serialize());

    // Save outgoing message to Redux store with messageId for status tracking
    widget.store.dispatch(SaveChatMessageAction(
      senderPubkeyHex: _myHex,
      recipientPubkeyHex: _peerHex,
      content: text,
      isOutgoing: true,
      messageId: messageId,
    ));

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

  void _copyMessage(ChatMessageState message) {
    Clipboard.setData(ClipboardData(text: message.content));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Message copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _forwardMessage(ChatMessageState message) {
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

          // Also save to Redux store as outgoing
          widget.store.dispatch(SaveChatMessageAction(
            senderPubkeyHex: _myHex,
            recipientPubkeyHex: ChatMessage.pubkeyToHex(peer.publicKey),
            content: message.content,
            isOutgoing: true,
          ));

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

  void _showMessageOptions(ChatMessageState message, Offset tapPosition) {
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
        title: Row(
          children: [
            Expanded(
              child: Text(
                widget.peer.nickname.isNotEmpty
                    ? widget.peer.nickname
                    : 'Peer ${_peerHex.substring(0, 8)}...',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_isFriend)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.people, size: 18, color: Colors.blue),
              ),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: _buildAppBarActions(),
      ),
      body: Column(
        children: [
          // Friend request banner if pending incoming
          if (_hasPendingIncoming) _buildFriendRequestBanner(),
          Expanded(
            child: Builder(builder: (context) {
              final messages = widget.store.state.messages.getConversation(_peerHex);
              return ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[index];
                  return _buildMessageWidget(message);
                },
              );
            }),
          ),
          _buildMessageInput(),
        ],
      ),
    );
  }

  List<Widget> _buildAppBarActions() {
    final actions = <Widget>[];

    if (!_isFriend && !_hasPendingOutgoing && !_hasPendingIncoming) {
      // Can send friend request
      actions.add(
        IconButton(
          icon: const Icon(Icons.person_add),
          tooltip: 'Send friend request',
          onPressed: widget.onSendFriendRequest,
        ),
      );
    } else if (_hasPendingOutgoing) {
      // Waiting for response
      actions.add(
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hourglass_empty, size: 16),
              SizedBox(width: 4),
              Text('Pending', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
      );
    }

    // Menu
    actions.add(
      PopupMenuButton<String>(
        onSelected: (value) {
          switch (value) {
            case 'info':
              _showPeerInfo();
              break;
            case 'unfriend':
              _confirmUnfriend();
              break;
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'info',
            child: Row(
              children: [
                Icon(Icons.info_outline),
                SizedBox(width: 12),
                Text('Peer Info'),
              ],
            ),
          ),
          if (_isFriend)
            const PopupMenuItem(
              value: 'unfriend',
              child: Row(
                children: [
                  Icon(Icons.person_remove, color: Colors.red),
                  SizedBox(width: 12),
                  Text('Unfriend', style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
        ],
      ),
    );

    return actions;
  }

  void _confirmUnfriend() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unfriend'),
        content: Text(
          'Are you sure you want to remove ${widget.peer.displayName} from your friends?\n\n'
          'You will only be able to contact them via Bluetooth when they are nearby.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              widget.onUnfriend?.call();
              Navigator.pop(context); // Close chat screen
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Unfriend'),
          ),
        ],
      ),
    );
  }

  Widget _buildFriendRequestBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: const Color(0xFF1B3D2F),
      child: Row(
        children: [
          const Icon(Icons.person_add, color: Color(0xFFE8A33C)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${widget.peer.displayName} wants to be friends!',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          TextButton(
            onPressed: () {
              // Decline
              widget.store.dispatch(DeclineFriendRequestAction(_peerHex));
            },
            child: const Text('Decline'),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: widget.onAcceptFriendRequest,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE8A33C),
            ),
            child: const Text('Accept', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageWidget(ChatMessageState message) {
    if (message.isFriendshipMessage) {
      return _FriendshipMessageBubble(
        message: message,
        onAccept: message.canAccept ? widget.onAcceptFriendRequest : null,
      );
    }
    return _MessageBubble(
      message: message,
      onLongPress: (position) => _showMessageOptions(message, position),
      messagesState: widget.store.state.messages,
      onResend: message.isOutgoing ? () => _resendMessage(message) : null,
    );
  }

  Future<void> _resendMessage(ChatMessageState message) async {
    _log.i("Resending '${message.content}' to peer ${widget.peer.displayName}");

    // Send via Bitchat using SayBlock
    final block = SayBlock(content: message.content);
    final messageId =
        await widget.bitchat.send(widget.peer.publicKey, block.serialize());

    if (!mounted) return;

    if (messageId != null) {
      // Update the old message's status would be complex, so we just log success
      _log.i("Resend successful with new messageId: $messageId");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Message resent'),
          duration: Duration(seconds: 2),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to resend message'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _showPeerInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.peer.displayName),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoRow('Public Key', _peerHex),
            const SizedBox(height: 8),
            _buildInfoRow('Status', widget.peer.connectionState.name),
            if (_isFriend) ...[
              const SizedBox(height: 8),
              _buildInfoRow('Friendship', 'Friends ✓'),
              if (_friendship?.libp2pAddress != null) ...[
                const SizedBox(height: 8),
                _buildInfoRow('LibP2P', _friendship!.libp2pAddress!),
              ],
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _peerHex));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Public key copied')),
              );
            },
            child: const Text('Copy Key'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            '$label:',
            style: const TextStyle(color: Colors.grey),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ],
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
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
  final ChatMessageState message;
  final void Function(Offset position)? onLongPress;
  final MessagesState? messagesState;
  final VoidCallback? onResend;

  const _MessageBubble({
    required this.message,
    this.onLongPress,
    this.messagesState,
    this.onResend,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment:
          message.isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTime(message.timestamp),
                    style: TextStyle(
                      fontSize: 10,
                      color: message.isOutgoing
                          ? Colors.white70
                          : Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.5),
                    ),
                  ),
                  if (message.isOutgoing) ...[
                    const SizedBox(width: 4),
                    _buildStatusIcon(context),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIcon(BuildContext context) {
    // Get message status from store
    MessageStatus status = MessageStatus.sent;
    if (message.messageId != null && messagesState != null) {
      final outgoing = messagesState!.getOutgoingMessage(message.messageId!);
      status = outgoing?.status ?? MessageStatus.sent;
    }

    switch (status) {
      case MessageStatus.sending:
        // Clock icon (sending)
        return const Icon(
          Icons.access_time,
          size: 14,
          color: Colors.white70,
        );
      case MessageStatus.failed:
        // Red exclamation (failed) - clickable for resend
        return GestureDetector(
          onTap: onResend,
          child: const Icon(
            Icons.error_outline,
            size: 14,
            color: Colors.redAccent,
          ),
        );
      case MessageStatus.sent:
        // 1 check (sent)
        return const Icon(
          Icons.check,
          size: 14,
          color: Colors.white70,
        );
      case MessageStatus.delivered:
        // 2 checks (delivered)
        return const Icon(
          Icons.done_all,
          size: 14,
          color: Colors.white70,
        );
      case MessageStatus.read:
        // 2 blue checks (read)
        return const Icon(
          Icons.done_all,
          size: 14,
          color: Colors.blueAccent,
        );
    }
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

/// Bottom sheet for selecting a peer to forward message to
class _ForwardSheet extends StatelessWidget {
  final ChatMessageState message;
  final List<PeerState> peers;
  final void Function(PeerState peer) onForward;

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
                      color:
                          peer.connectionState == PeerConnectionState.connected
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

/// Special message bubble for friendship-related messages
class _FriendshipMessageBubble extends StatelessWidget {
  final ChatMessageState message;
  final VoidCallback? onAccept;

  const _FriendshipMessageBubble({
    required this.message,
    this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final isOutgoing = message.isOutgoing;

    IconData icon;
    Color iconColor;
    String title;

    switch (message.messageType) {
      case ChatMessageType.friendRequestSent:
        icon = Icons.person_add;
        iconColor = const Color(0xFFE8A33C);
        title = 'Friend Request Sent';
        break;
      case ChatMessageType.friendRequestReceived:
        icon = Icons.person_add;
        iconColor = const Color(0xFFE8A33C);
        title = 'Friend Request';
        break;
      case ChatMessageType.friendRequestAccepted:
        icon = Icons.check_circle;
        iconColor = Colors.green;
        title = 'Friend Request Accepted';
        break;
      case ChatMessageType.friendRequestAcceptedByUs:
        icon = Icons.check_circle;
        iconColor = Colors.green;
        title = 'You Accepted';
        break;
      default:
        icon = Icons.info;
        iconColor = Colors.grey;
        title = 'System Message';
    }

    return Align(
      alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF1B3D2F),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: iconColor.withOpacity(0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.1),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(15)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: iconColor, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: iconColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Content
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.content,
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  // Accept button for pending incoming requests
                  if (message.canAccept && onAccept != null) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: onAccept,
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('Accept Friend Request'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE8A33C),
                          foregroundColor: Colors.black,
                        ),
                      ),
                    ),
                  ],
                  // Timestamp
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Text(
                      _formatTime(message.timestamp),
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white.withOpacity(0.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
