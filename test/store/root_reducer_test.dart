import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:bitchat_transport/src/store/app_state.dart';
import 'package:bitchat_transport/src/store/actions.dart';
import 'package:bitchat_transport/src/store/reducers.dart';
import 'package:bitchat_transport/src/store/peers_actions.dart';
import 'package:bitchat_transport/src/store/messages_actions.dart';
import 'package:bitchat_transport/src/store/friendships_actions.dart';
import 'package:bitchat_transport/src/store/settings_actions.dart';
import 'package:bitchat_transport/src/store/peers_state.dart';

void main() {
  group('appReducer', () {
    // =========================================================
    // 1. Routing to sub-reducers
    // =========================================================
    group('routes actions to sub-reducers', () {
      test('PeerAction routes to peersReducer', () {
        const initial = AppState.initial;
        final action = BleDeviceDiscoveredAction(
          deviceId: 'dev1',
          rssi: -50,
          serviceUuid: 'uuid1',
        );

        final result = appReducer(initial, action);

        // The peers state should have changed (device added to discoveredBlePeers)
        expect(result.peers, isNot(equals(initial.peers)));
        expect(result.peers.discoveredBlePeers.containsKey('dev1'), isTrue);
        final discovered = result.peers.discoveredBlePeers['dev1']!;
        expect(discovered.transportId, 'dev1');
        expect(discovered.rssi, -50);
        expect(discovered.serviceUuid, 'uuid1');

        // Other state sections remain unchanged
        expect(result.messages, equals(initial.messages));
        expect(result.friendships, equals(initial.friendships));
        expect(result.settings, equals(initial.settings));
        expect(result.connectionStatus, equals(initial.connectionStatus));
      });

      test('MessageAction routes to messagesReducer', () {
        const initial = AppState.initial;
        final action = MessageSentAction(
          messageId: 'msg1',
          transport: MessageTransport.ble,
          recipientPubkey: Uint8List(32),
          payloadSize: 100,
        );

        final result = appReducer(initial, action);

        // The messages state should have changed (outgoing message recorded)
        expect(result.messages, isNot(equals(initial.messages)));
        expect(result.messages.outgoingMessages.containsKey('msg1'), isTrue);
        final msg = result.messages.outgoingMessages['msg1']!;
        expect(msg.transport, MessageTransport.ble);
        expect(msg.payloadSize, 100);

        // Other state sections remain unchanged
        expect(result.peers, equals(initial.peers));
        expect(result.friendships, equals(initial.friendships));
        expect(result.settings, equals(initial.settings));
        expect(result.connectionStatus, equals(initial.connectionStatus));
      });

      test('FriendshipAction routes to friendshipsReducer', () {
        const initial = AppState.initial;
        final action = CreateFriendRequestAction(
          peerPubkeyHex: 'abc123',
          message: 'hi',
        );

        final result = appReducer(initial, action);

        // The friendships state should have changed (pending request added)
        expect(result.friendships, isNot(equals(initial.friendships)));
        expect(
          result.friendships.friendships.containsKey('abc123'),
          isTrue,
        );

        // Other state sections remain unchanged
        expect(result.peers, equals(initial.peers));
        expect(result.messages, equals(initial.messages));
        expect(result.settings, equals(initial.settings));
        expect(result.connectionStatus, equals(initial.connectionStatus));
      });

      test('SettingsAction routes to settingsReducer', () {
        const initial = AppState.initial;
        // Default bluetoothEnabled is true, so setting it to false should change state
        final action = SetBluetoothEnabledAction(false);

        final result = appReducer(initial, action);

        // The settings state should have changed
        expect(result.settings, isNot(equals(initial.settings)));
        expect(result.settings.bluetoothEnabled, isFalse);

        // Other state sections remain unchanged
        expect(result.peers, equals(initial.peers));
        expect(result.messages, equals(initial.messages));
        expect(result.friendships, equals(initial.friendships));
        expect(result.connectionStatus, equals(initial.connectionStatus));
      });
    });

    // =========================================================
    // 2. Connection status actions
    // =========================================================
    group('connection status actions', () {
      test('SetInitializingAction sets status to initializing', () {
        const initial = AppState.initial;
        expect(
          initial.connectionStatus,
          TransportConnectionStatus.uninitialized,
        );

        final result = appReducer(initial, SetInitializingAction());

        expect(
          result.connectionStatus,
          TransportConnectionStatus.initializing,
        );
      });

      test('SetOnlineAction sets status to online', () {
        final state = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.initializing,
        );

        final result = appReducer(state, SetOnlineAction());

        expect(result.connectionStatus, TransportConnectionStatus.online);
      });

      test('SetErrorAction sets status to error with message', () {
        final state = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.online,
        );

        final result = appReducer(state, SetErrorAction('BLE unavailable'));

        expect(result.connectionStatus, TransportConnectionStatus.error);
        expect(result.errorMessage, 'BLE unavailable');
      });
    });

    // =========================================================
    // 3. Scan actions
    // =========================================================
    group('scan actions', () {
      test('ScanStartedAction changes online to scanning', () {
        final state = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.online,
        );

        final result = appReducer(state, ScanStartedAction());

        expect(result.connectionStatus, TransportConnectionStatus.scanning);
      });

      test('ScanStartedAction does NOT change non-online states', () {
        // initializing should stay initializing
        final initializingState = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.initializing,
        );
        final result1 = appReducer(initializingState, ScanStartedAction());
        expect(
          result1.connectionStatus,
          TransportConnectionStatus.initializing,
        );

        // error should stay error
        final errorState = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.error,
          errorMessage: 'some error',
        );
        final result2 = appReducer(errorState, ScanStartedAction());
        expect(result2.connectionStatus, TransportConnectionStatus.error);

        // uninitialized should stay uninitialized
        const uninitializedState = AppState.initial;
        final result3 = appReducer(uninitializedState, ScanStartedAction());
        expect(
          result3.connectionStatus,
          TransportConnectionStatus.uninitialized,
        );

        // scanning should stay scanning (already scanning)
        final scanningState = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.scanning,
        );
        final result4 = appReducer(scanningState, ScanStartedAction());
        expect(result4.connectionStatus, TransportConnectionStatus.scanning);
      });

      test('ScanCompletedAction changes scanning to online', () {
        final state = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.scanning,
        );

        final result = appReducer(state, ScanCompletedAction());

        expect(result.connectionStatus, TransportConnectionStatus.online);
      });

      test('ScanCompletedAction does NOT change non-scanning states', () {
        // online should stay online
        final onlineState = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.online,
        );
        final result1 = appReducer(onlineState, ScanCompletedAction());
        expect(result1.connectionStatus, TransportConnectionStatus.online);

        // initializing should stay initializing
        final initializingState = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.initializing,
        );
        final result2 = appReducer(initializingState, ScanCompletedAction());
        expect(
          result2.connectionStatus,
          TransportConnectionStatus.initializing,
        );

        // error should stay error
        final errorState = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.error,
          errorMessage: 'oops',
        );
        final result3 = appReducer(errorState, ScanCompletedAction());
        expect(result3.connectionStatus, TransportConnectionStatus.error);
      });
    });

    // =========================================================
    // 4. Unknown action returns same state
    // =========================================================
    group('unknown actions', () {
      test('unknown action returns the same state unchanged', () {
        final state = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.online,
        );

        final result = appReducer(state, 'some_unknown_action');

        expect(result, equals(state));
        expect(identical(result, state), isTrue);
      });

      test('null action returns the same state unchanged', () {
        const state = AppState.initial;

        final result = appReducer(state, null);

        expect(result, equals(state));
        expect(identical(result, state), isTrue);
      });
    });

    // =========================================================
    // 5. Actions preserve unrelated state sections
    // =========================================================
    group('actions preserve unrelated state sections', () {
      test('SetOnlineAction preserves peers, messages, friendships, settings',
          () {
        // Build a state with non-default sub-states
        final now = DateTime.now();
        final stateWithData = AppState(
          connectionStatus: TransportConnectionStatus.initializing,
          peers: PeersState(
            discoveredBlePeers: {
              'dev1': DiscoveredPeerState(
                transportId: 'dev1',
                rssi: -60,
                discoveredAt: now,
                lastSeen: now,
              ),
            },
          ),
        );

        final result = appReducer(stateWithData, SetOnlineAction());

        // Connection status changed
        expect(result.connectionStatus, TransportConnectionStatus.online);

        // Peers preserved exactly
        expect(result.peers, equals(stateWithData.peers));
        expect(
          result.peers.discoveredBlePeers.containsKey('dev1'),
          isTrue,
        );

        // Messages, friendships, settings preserved
        expect(result.messages, equals(stateWithData.messages));
        expect(result.friendships, equals(stateWithData.friendships));
        expect(result.settings, equals(stateWithData.settings));
      });

      test('SetErrorAction preserves all sub-states', () {
        final state = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.online,
        );

        final result = appReducer(state, SetErrorAction('failure'));

        expect(result.connectionStatus, TransportConnectionStatus.error);
        expect(result.errorMessage, 'failure');
        expect(result.peers, equals(state.peers));
        expect(result.messages, equals(state.messages));
        expect(result.friendships, equals(state.friendships));
        expect(result.settings, equals(state.settings));
      });

      test('SetInitializingAction preserves all sub-states', () {
        const state = AppState.initial;

        final result = appReducer(state, SetInitializingAction());

        expect(
          result.connectionStatus,
          TransportConnectionStatus.initializing,
        );
        expect(result.peers, equals(state.peers));
        expect(result.messages, equals(state.messages));
        expect(result.friendships, equals(state.friendships));
        expect(result.settings, equals(state.settings));
      });

      test('ScanStartedAction preserves all sub-states', () {
        final state = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.online,
        );

        final result = appReducer(state, ScanStartedAction());

        expect(result.connectionStatus, TransportConnectionStatus.scanning);
        expect(result.peers, equals(state.peers));
        expect(result.messages, equals(state.messages));
        expect(result.friendships, equals(state.friendships));
        expect(result.settings, equals(state.settings));
      });

      test('ScanCompletedAction preserves all sub-states', () {
        final state = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.scanning,
        );

        final result = appReducer(state, ScanCompletedAction());

        expect(result.connectionStatus, TransportConnectionStatus.online);
        expect(result.peers, equals(state.peers));
        expect(result.messages, equals(state.messages));
        expect(result.friendships, equals(state.friendships));
        expect(result.settings, equals(state.settings));
      });

      test('PeerAction preserves connectionStatus and other sub-states', () {
        final state = AppState.initial.copyWith(
          connectionStatus: TransportConnectionStatus.online,
        );

        final action = BleDeviceDiscoveredAction(
          deviceId: 'dev2',
          rssi: -70,
        );
        final result = appReducer(state, action);

        // Peers changed
        expect(result.peers.discoveredBlePeers.containsKey('dev2'), isTrue);

        // Everything else preserved
        expect(result.connectionStatus, TransportConnectionStatus.online);
        expect(result.messages, equals(state.messages));
        expect(result.friendships, equals(state.friendships));
        expect(result.settings, equals(state.settings));
      });
    });
  });
}
