import 'messages_state.dart';
import 'messages_actions.dart';

/// Reducer for messages state
MessagesState messagesReducer(MessagesState state, MessageAction action) {
  if (action is MessageSendingAction) {
    final message = OutgoingMessage(
      messageId: action.messageId,
      transport: action.transport,
      recipientPubkey: action.recipientPubkey,
      payloadSize: action.payloadSize,
      sentAt: action.timestamp,
      status: MessageStatus.sending,
    );

    final updated = Map<String, OutgoingMessage>.from(state.outgoingMessages);
    updated[action.messageId] = message;

    // Trim if exceeds max
    if (updated.length > MessagesState.maxMessages) {
      final sorted = updated.entries.toList()
        ..sort((a, b) => a.value.sentAt.compareTo(b.value.sentAt));
      final toRemove = sorted.take(updated.length - MessagesState.maxMessages);
      for (final entry in toRemove) {
        updated.remove(entry.key);
      }
    }

    return state.copyWith(outgoingMessages: updated);
  }

  if (action is MessageFailedAction) {
    final existing = state.outgoingMessages[action.messageId];
    if (existing == null) return state;

    final updated = Map<String, OutgoingMessage>.from(state.outgoingMessages);
    updated[action.messageId] = existing.copyWith(
      status: MessageStatus.failed,
    );

    return state.copyWith(outgoingMessages: updated);
  }

  if (action is MessageSentAction) {
    final updated = Map<String, OutgoingMessage>.from(state.outgoingMessages);
    final existing = state.outgoingMessages[action.messageId];

    if (existing != null) {
      // Update existing message (sending -> sent)
      updated[action.messageId] = existing.copyWith(
        status: MessageStatus.sent,
      );
    } else {
      // Create new message (for backwards compatibility)
      final message = OutgoingMessage(
        messageId: action.messageId,
        transport: action.transport,
        recipientPubkey: action.recipientPubkey,
        payloadSize: action.payloadSize,
        sentAt: action.timestamp,
        status: MessageStatus.sent,
      );
      updated[action.messageId] = message;

      // Trim if exceeds max
      if (updated.length > MessagesState.maxMessages) {
        final sorted = updated.entries.toList()
          ..sort((a, b) => a.value.sentAt.compareTo(b.value.sentAt));
        final toRemove = sorted.take(updated.length - MessagesState.maxMessages);
        for (final entry in toRemove) {
          updated.remove(entry.key);
        }
      }
    }

    return state.copyWith(outgoingMessages: updated);
  }

  if (action is MessageDeliveredAction) {
    final existing = state.outgoingMessages[action.messageId];
    if (existing == null) return state;

    final updated = Map<String, OutgoingMessage>.from(state.outgoingMessages);
    updated[action.messageId] = existing.copyWith(
      status: MessageStatus.delivered,
      deliveredAt: action.timestamp,
    );

    return state.copyWith(outgoingMessages: updated);
  }

  if (action is MessageReadAction) {
    final existing = state.outgoingMessages[action.messageId];
    if (existing == null) return state;

    final updated = Map<String, OutgoingMessage>.from(state.outgoingMessages);
    updated[action.messageId] = existing.copyWith(
      status: MessageStatus.read,
      readAt: action.timestamp,
    );

    return state.copyWith(outgoingMessages: updated);
  }

  if (action is MessageReceivedAction) {
    final message = IncomingMessage(
      messageId: action.messageId,
      transport: action.transport,
      senderPubkey: action.senderPubkey,
      payloadSize: action.payloadSize,
      receivedAt: action.timestamp,
    );

    final updated = Map<String, IncomingMessage>.from(state.incomingMessages);
    updated[action.messageId] = message;

    // Trim if exceeds max
    if (updated.length > MessagesState.maxMessages) {
      final sorted = updated.entries.toList()
        ..sort((a, b) => a.value.receivedAt.compareTo(b.value.receivedAt));
      final toRemove = sorted.take(updated.length - MessagesState.maxMessages);
      for (final entry in toRemove) {
        updated.remove(entry.key);
      }
    }

    return state.copyWith(incomingMessages: updated);
  }

  // ===== Conversation Actions =====

  if (action is SaveChatMessageAction) {
    final peerHex = action.isOutgoing
        ? action.recipientPubkeyHex
        : action.senderPubkeyHex;

    final chatMessage = ChatMessageState(
      senderPubkeyHex: action.senderPubkeyHex,
      recipientPubkeyHex: action.recipientPubkeyHex,
      content: action.content,
      timestamp: action.timestamp,
      isOutgoing: action.isOutgoing,
      messageType: ChatMessageType.values[action.messageType],
      udpAddress: action.udpAddress,
      messageId: action.messageId,
      mediaPath: action.mediaPath,
      mediaMime: action.mediaMime,
      viewOnce: action.viewOnce,
    );

    // Get existing conversation or create new
    final existingConv = state.conversations[peerHex] ?? [];
    final newConv = List<ChatMessageState>.from(existingConv)..add(chatMessage);

    // Trim if exceeds max per conversation
    while (newConv.length > MessagesState.maxMessagesPerConversation) {
      newConv.removeAt(0);
    }

    final updatedConversations = Map<String, List<ChatMessageState>>.from(
      state.conversations,
    )..[peerHex] = newConv;

    // Increment unread count for incoming messages
    Map<String, int> updatedUnreadCounts = state.unreadCounts;
    if (!action.isOutgoing) {
      updatedUnreadCounts = Map<String, int>.from(state.unreadCounts);
      updatedUnreadCounts[peerHex] = (updatedUnreadCounts[peerHex] ?? 0) + 1;
    }

    return state.copyWith(
      conversations: updatedConversations,
      unreadCounts: updatedUnreadCounts,
    );
  }

  if (action is MarkPictureViewedAction) {
    final conv = state.conversations[action.peerHex];
    if (conv == null) return state;

    final idx = conv.indexWhere((m) => m.messageId == action.messageId);
    if (idx < 0) return state;

    final updatedMessage = conv[idx].copyWith(
      viewed: true,
      clearMediaPath: true,
    );
    final newConv = List<ChatMessageState>.from(conv)..[idx] = updatedMessage;

    final updatedConversations = Map<String, List<ChatMessageState>>.from(
      state.conversations,
    )..[action.peerHex] = newConv;

    return state.copyWith(conversations: updatedConversations);
  }

  if (action is MarkMessagesReadAction) {
    final updatedUnreadCounts = Map<String, int>.from(state.unreadCounts);
    updatedUnreadCounts.remove(action.peerHex);
    return state.copyWith(unreadCounts: updatedUnreadCounts);
  }

  if (action is DeleteConversationAction) {
    // Drop the message thread + unread count. Outgoing/incoming delivery-status
    // records get pruned here too: with the chat history gone there is nothing
    // for those records to bind to, and they would otherwise leak forever.
    final messageIdsToDrop = <String>{
      for (final m
          in (state.conversations[action.peerHex] ?? const <ChatMessageState>[]))
        if (m.messageId != null) m.messageId!,
    };

    final newConversations = Map<String, List<ChatMessageState>>.from(
      state.conversations,
    )..remove(action.peerHex);

    final newUnreadCounts = Map<String, int>.from(state.unreadCounts)
      ..remove(action.peerHex);

    final newOutgoing = Map<String, OutgoingMessage>.from(state.outgoingMessages)
      ..removeWhere((id, _) => messageIdsToDrop.contains(id));
    final newIncoming = Map<String, IncomingMessage>.from(state.incomingMessages)
      ..removeWhere((id, _) => messageIdsToDrop.contains(id));

    return state.copyWith(
      conversations: newConversations,
      unreadCounts: newUnreadCounts,
      outgoingMessages: newOutgoing,
      incomingMessages: newIncoming,
    );
  }

  if (action is HydrateConversationsAction) {
    // Convert dynamic lists to ChatMessageState lists
    final conversations = <String, List<ChatMessageState>>{};
    for (final entry in action.conversations.entries) {
      conversations[entry.key] = entry.value
          .map((m) => m is ChatMessageState
              ? m
              : ChatMessageState.fromJson(m as Map<String, dynamic>))
          .toList();
    }
    return state.copyWith(
      conversations: conversations,
      unreadCounts: action.unreadCounts,
    );
  }

  return state;
}
