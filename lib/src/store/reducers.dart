import 'app_state.dart';
import 'actions.dart';
import 'peers_actions.dart';
import 'peers_reducer.dart';
import 'messages_actions.dart';
import 'messages_reducer.dart';
import 'friendships_actions.dart';
import 'friendships_reducer.dart';
import 'settings_actions.dart';
import 'settings_reducer.dart';

/// Root reducer that handles all actions
AppState appReducer(AppState state, dynamic action) {
  // Handle peer actions via peersReducer
  if (action is PeerAction) {
    return state.copyWith(
      peers: peersReducer(state.peers, action),
    );
  }

  // Handle message actions via messagesReducer
  if (action is MessageAction) {
    return state.copyWith(
      messages: messagesReducer(state.messages, action),
    );
  }

  // Handle friendship actions via friendshipsReducer
  if (action is FriendshipAction) {
    return state.copyWith(
      friendships: friendshipsReducer(state.friendships, action),
    );
  }

  // Handle settings actions via settingsReducer
  if (action is SettingsAction) {
    return state.copyWith(
      settings: settingsReducer(state.settings, action),
    );
  }

  if (action is SetInitializingAction) {
    return state.copyWith(
      connectionStatus: TransportConnectionStatus.initializing,
    );
  }

  if (action is SetOnlineAction) {
    return state.copyWith(
      connectionStatus: TransportConnectionStatus.online,
    );
  }

  if (action is SetErrorAction) {
    return state.copyWith(
      connectionStatus: TransportConnectionStatus.error,
      errorMessage: action.message,
    );
  }

  if (action is ScanStartedAction) {
    // Only change to scanning if we're currently online
    if (state.connectionStatus == TransportConnectionStatus.online) {
      return state.copyWith(
        connectionStatus: TransportConnectionStatus.scanning,
      );
    }
    return state;
  }

  if (action is ScanCompletedAction) {
    // Only change to online if we're currently scanning
    if (state.connectionStatus == TransportConnectionStatus.scanning) {
      return state.copyWith(
        connectionStatus: TransportConnectionStatus.online,
      );
    }
    return state;
  }

  return state;
}
