import 'package:flutter_test/flutter_test.dart';
import 'package:bitchat_transport/src/store/settings_state.dart';
import 'package:bitchat_transport/src/store/settings_actions.dart';
import 'package:bitchat_transport/src/store/settings_reducer.dart';

/// A non-settings action used to verify the reducer ignores unknown actions.
class _UnknownAction extends SettingsAction {}

void main() {
  group('settingsReducer', () {
    group('default state', () {
      test('initial state has bluetoothEnabled=true and libp2pEnabled=true',
          () {
        const state = SettingsState.initial;

        expect(state.bluetoothEnabled, isTrue);
        expect(state.libp2pEnabled, isTrue);
        expect(state.transportPriority, [
          TransportProtocol.bluetooth,
          TransportProtocol.libp2p,
        ]);
      });

      test('unknown action returns the same state unchanged', () {
        const state = SettingsState.initial;
        final result = settingsReducer(state, _UnknownAction());

        expect(result, same(state));
      });
    });

    group('SetBluetoothEnabledAction', () {
      test('sets bluetoothEnabled to true', () {
        const state = SettingsState(bluetoothEnabled: false);
        final result = settingsReducer(
          state,
          SetBluetoothEnabledAction(true),
        );

        expect(result.bluetoothEnabled, isTrue);
      });

      test('sets bluetoothEnabled to false', () {
        const state = SettingsState(bluetoothEnabled: true);
        final result = settingsReducer(
          state,
          SetBluetoothEnabledAction(false),
        );

        expect(result.bluetoothEnabled, isFalse);
      });

      test('preserves libp2pEnabled and transportPriority', () {
        const state = SettingsState(
          bluetoothEnabled: true,
          libp2pEnabled: false,
          transportPriority: [TransportProtocol.libp2p],
        );
        final result = settingsReducer(
          state,
          SetBluetoothEnabledAction(false),
        );

        expect(result.bluetoothEnabled, isFalse);
        expect(result.libp2pEnabled, isFalse);
        expect(result.transportPriority, [TransportProtocol.libp2p]);
      });
    });

    group('SetLibp2pEnabledAction', () {
      test('sets libp2pEnabled to true', () {
        const state = SettingsState(libp2pEnabled: false);
        final result = settingsReducer(
          state,
          SetLibp2pEnabledAction(true),
        );

        expect(result.libp2pEnabled, isTrue);
      });

      test('sets libp2pEnabled to false', () {
        const state = SettingsState(libp2pEnabled: true);
        final result = settingsReducer(
          state,
          SetLibp2pEnabledAction(false),
        );

        expect(result.libp2pEnabled, isFalse);
      });

      test('preserves bluetoothEnabled and transportPriority', () {
        const state = SettingsState(
          bluetoothEnabled: false,
          libp2pEnabled: true,
          transportPriority: [
            TransportProtocol.libp2p,
            TransportProtocol.bluetooth,
          ],
        );
        final result = settingsReducer(
          state,
          SetLibp2pEnabledAction(false),
        );

        expect(result.libp2pEnabled, isFalse);
        expect(result.bluetoothEnabled, isFalse);
        expect(result.transportPriority, [
          TransportProtocol.libp2p,
          TransportProtocol.bluetooth,
        ]);
      });
    });

    group('UpdateTransportSettingsAction', () {
      test('updates multiple settings at once', () {
        const state = SettingsState.initial;
        final result = settingsReducer(
          state,
          UpdateTransportSettingsAction(
            bluetoothEnabled: false,
            libp2pEnabled: false,
          ),
        );

        expect(result.bluetoothEnabled, isFalse);
        expect(result.libp2pEnabled, isFalse);
        // transportPriority not provided, so it should remain at default
        expect(result.transportPriority, [
          TransportProtocol.bluetooth,
          TransportProtocol.libp2p,
        ]);
      });

      test('can change transport priority order', () {
        const state = SettingsState.initial;
        final result = settingsReducer(
          state,
          UpdateTransportSettingsAction(
            transportPriority: [
              TransportProtocol.libp2p,
              TransportProtocol.bluetooth,
            ],
          ),
        );

        expect(result.transportPriority, [
          TransportProtocol.libp2p,
          TransportProtocol.bluetooth,
        ]);
        // Fields not provided in the action should remain unchanged
        expect(result.bluetoothEnabled, isTrue);
        expect(result.libp2pEnabled, isTrue);
      });

      test('updates all fields simultaneously', () {
        const state = SettingsState.initial;
        final result = settingsReducer(
          state,
          UpdateTransportSettingsAction(
            bluetoothEnabled: false,
            libp2pEnabled: true,
            transportPriority: [TransportProtocol.libp2p],
          ),
        );

        expect(result.bluetoothEnabled, isFalse);
        expect(result.libp2pEnabled, isTrue);
        expect(result.transportPriority, [TransportProtocol.libp2p]);
      });
    });

    group('HydrateSettingsAction', () {
      test('replaces entire settings state', () {
        const state = SettingsState.initial;
        const hydratedState = SettingsState(
          bluetoothEnabled: false,
          libp2pEnabled: false,
        );
        final result = settingsReducer(
          state,
          HydrateSettingsAction(hydratedState),
        );

        expect(result, equals(hydratedState));
        expect(result.bluetoothEnabled, isFalse);
        expect(result.libp2pEnabled, isFalse);
      });

      test('handles custom transport priority', () {
        const state = SettingsState.initial;
        const hydratedState = SettingsState(
          bluetoothEnabled: true,
          libp2pEnabled: false,
          transportPriority: [
            TransportProtocol.libp2p,
            TransportProtocol.bluetooth,
          ],
        );
        final result = settingsReducer(
          state,
          HydrateSettingsAction(hydratedState),
        );

        expect(result.transportPriority, [
          TransportProtocol.libp2p,
          TransportProtocol.bluetooth,
        ]);
        expect(result.bluetoothEnabled, isTrue);
        expect(result.libp2pEnabled, isFalse);
      });

      test('completely discards previous state', () {
        const previousState = SettingsState(
          bluetoothEnabled: false,
          libp2pEnabled: false,
          transportPriority: [TransportProtocol.libp2p],
        );
        const hydratedState = SettingsState(
          bluetoothEnabled: true,
          libp2pEnabled: true,
          transportPriority: [
            TransportProtocol.bluetooth,
            TransportProtocol.libp2p,
          ],
        );
        final result = settingsReducer(
          previousState,
          HydrateSettingsAction(hydratedState),
        );

        expect(result, equals(hydratedState));
        expect(result.bluetoothEnabled, isTrue);
        expect(result.libp2pEnabled, isTrue);
        expect(result.transportPriority, [
          TransportProtocol.bluetooth,
          TransportProtocol.libp2p,
        ]);
      });
    });
  });
}
