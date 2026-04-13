import 'settings_state.dart';
import 'settings_actions.dart';

/// Reducer for settings state
SettingsState settingsReducer(SettingsState state, SettingsAction action) {
  if (action is SetBluetoothEnabledAction) {
    return state.copyWith(bluetoothEnabled: action.enabled);
  }

  if (action is SetUdpEnabledAction) {
    return state.copyWith(udpEnabled: action.enabled);
  }

  if (action is UpdateTransportSettingsAction) {
    return state.copyWith(
      bluetoothEnabled: action.bluetoothEnabled,
      udpEnabled: action.udpEnabled,
      transportPriority: action.transportPriority,
    );
  }

  if (action is SetAnchorServerAction) {
    return state.copyWith(anchorAddress: action.anchorAddress);
  }

  if (action is HydrateSettingsAction) {
    return action.settings;
  }

  return state;
}
