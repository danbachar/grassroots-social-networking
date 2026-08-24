import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/store/settings_state.dart';
import 'package:grassroots_networking/src/store/settings_actions.dart';
import 'package:grassroots_networking/src/store/settings_reducer.dart';

/// A non-settings action used to verify the reducer ignores unknown actions.
class _UnknownAction extends SettingsAction {}

void main() {
  group('settingsReducer', () {
    group('default state', () {
      test('initial state has bluetoothEnabled=true and udpEnabled=true', () {
        const state = SettingsState.initial;

        expect(state.bluetoothEnabled, isTrue);
        expect(state.udpEnabled, isTrue);
        expect(state.transportPriority, [
          TransportProtocol.bluetooth,
          TransportProtocol.udp,
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

      test('preserves udpEnabled and transportPriority', () {
        const state = SettingsState(
          bluetoothEnabled: true,
          udpEnabled: false,
          transportPriority: [TransportProtocol.udp],
        );
        final result = settingsReducer(
          state,
          SetBluetoothEnabledAction(false),
        );

        expect(result.bluetoothEnabled, isFalse);
        expect(result.udpEnabled, isFalse);
        expect(result.transportPriority, [TransportProtocol.udp]);
      });
    });

    group('SetUdpEnabledAction', () {
      test('sets udpEnabled to true', () {
        const state = SettingsState(udpEnabled: false);
        final result = settingsReducer(
          state,
          SetUdpEnabledAction(true),
        );

        expect(result.udpEnabled, isTrue);
      });

      test('sets udpEnabled to false', () {
        const state = SettingsState(udpEnabled: true);
        final result = settingsReducer(
          state,
          SetUdpEnabledAction(false),
        );

        expect(result.udpEnabled, isFalse);
      });

      test('preserves bluetoothEnabled and transportPriority', () {
        const state = SettingsState(
          bluetoothEnabled: false,
          udpEnabled: true,
          transportPriority: [
            TransportProtocol.udp,
            TransportProtocol.bluetooth,
          ],
        );
        final result = settingsReducer(
          state,
          SetUdpEnabledAction(false),
        );

        expect(result.udpEnabled, isFalse);
        expect(result.bluetoothEnabled, isFalse);
        expect(result.transportPriority, [
          TransportProtocol.udp,
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
            udpEnabled: false,
          ),
        );

        expect(result.bluetoothEnabled, isFalse);
        expect(result.udpEnabled, isFalse);
        // transportPriority not provided, so it should remain at default
        expect(result.transportPriority, [
          TransportProtocol.bluetooth,
          TransportProtocol.udp,
        ]);
      });

      test('can change transport priority order', () {
        const state = SettingsState.initial;
        final result = settingsReducer(
          state,
          UpdateTransportSettingsAction(
            transportPriority: [
              TransportProtocol.udp,
              TransportProtocol.bluetooth,
            ],
          ),
        );

        expect(result.transportPriority, [
          TransportProtocol.udp,
          TransportProtocol.bluetooth,
        ]);
        // Fields not provided in the action should remain unchanged
        expect(result.bluetoothEnabled, isTrue);
        expect(result.udpEnabled, isTrue);
      });

      test('updates all fields simultaneously', () {
        const state = SettingsState.initial;
        final result = settingsReducer(
          state,
          UpdateTransportSettingsAction(
            bluetoothEnabled: false,
            udpEnabled: true,
            transportPriority: [TransportProtocol.udp],
          ),
        );

        expect(result.bluetoothEnabled, isFalse);
        expect(result.udpEnabled, isTrue);
        expect(result.transportPriority, [TransportProtocol.udp]);
      });
    });

    group('SetColdCallTrustLevelAction', () {
      test('defaults to open until set (testbed default)', () {
        expect(
          SettingsState.initial.coldCallTrustLevel,
          ColdCallTrustLevel.open,
        );
      });

      test('updates cold-call trust level', () {
        const state = SettingsState.initial;
        final result = settingsReducer(
          state,
          SetColdCallTrustLevelAction(ColdCallTrustLevel.open),
        );

        expect(result.coldCallTrustLevel, ColdCallTrustLevel.open);
        expect(result.bluetoothEnabled, state.bluetoothEnabled);
        expect(result.udpEnabled, state.udpEnabled);
      });

      test('closing cold-call also withdraws the introduce opt-in', () {
        const state = SettingsState(
          coldCallTrustLevel: ColdCallTrustLevel.open,
          facilitateInvites: true,
        );
        final result = settingsReducer(
          state,
          SetColdCallTrustLevelAction(ColdCallTrustLevel.closed),
        );

        expect(result.coldCallTrustLevel, ColdCallTrustLevel.closed);
        expect(result.facilitateInvites, isFalse);
      });
    });

    group('SetFacilitateInvitesAction', () {
      test('sets the stored flag', () {
        const state = SettingsState.initial;
        final result =
            settingsReducer(state, SetFacilitateInvitesAction(true));
        expect(result.facilitateInvites, isTrue);
      });

      test('effective willingness is AND-gated by an open cold-call posture',
          () {
        // Flag on but cold-call closed → not willing.
        const closed = SettingsState(
          coldCallTrustLevel: ColdCallTrustLevel.closed,
          facilitateInvites: true,
        );
        expect(closed.willingToFacilitateInvites, isFalse);

        // Flag on and cold-call open → willing.
        const open = SettingsState(
          coldCallTrustLevel: ColdCallTrustLevel.open,
          facilitateInvites: true,
        );
        expect(open.willingToFacilitateInvites, isTrue);

        // Flag off → not willing regardless.
        const off = SettingsState(
          coldCallTrustLevel: ColdCallTrustLevel.open,
          facilitateInvites: false,
        );
        expect(off.willingToFacilitateInvites, isFalse);
      });
    });

    group('HydrateSettingsAction', () {
      test('replaces entire settings state', () {
        const state = SettingsState.initial;
        const hydratedState = SettingsState(
          bluetoothEnabled: false,
          udpEnabled: false,
        );
        final result = settingsReducer(
          state,
          HydrateSettingsAction(hydratedState),
        );

        expect(result, equals(hydratedState));
        expect(result.bluetoothEnabled, isFalse);
        expect(result.udpEnabled, isFalse);
      });

      test('handles custom transport priority', () {
        const state = SettingsState.initial;
        const hydratedState = SettingsState(
          bluetoothEnabled: true,
          udpEnabled: false,
          transportPriority: [
            TransportProtocol.udp,
            TransportProtocol.bluetooth,
          ],
        );
        final result = settingsReducer(
          state,
          HydrateSettingsAction(hydratedState),
        );

        expect(result.transportPriority, [
          TransportProtocol.udp,
          TransportProtocol.bluetooth,
        ]);
        expect(result.bluetoothEnabled, isTrue);
        expect(result.udpEnabled, isFalse);
      });

      test('completely discards previous state', () {
        const previousState = SettingsState(
          bluetoothEnabled: false,
          udpEnabled: false,
          transportPriority: [TransportProtocol.udp],
        );
        const hydratedState = SettingsState(
          bluetoothEnabled: true,
          udpEnabled: true,
          transportPriority: [
            TransportProtocol.bluetooth,
            TransportProtocol.udp,
          ],
        );
        final result = settingsReducer(
          previousState,
          HydrateSettingsAction(hydratedState),
        );

        expect(result, equals(hydratedState));
        expect(result.bluetoothEnabled, isTrue);
        expect(result.udpEnabled, isTrue);
        expect(result.transportPriority, [
          TransportProtocol.bluetooth,
          TransportProtocol.udp,
        ]);
      });
    });
  });
}
