import 'settings_state.dart';
import 'settings_actions.dart';

/// Reducer for settings state
SettingsState settingsReducer(SettingsState state, SettingsAction action) {
  if (action is SetBluetoothEnabledAction) {
    return state.copyWith(bluetoothEnabled: action.enabled);
  }

  if (action is SetLibp2pEnabledAction) {
    return state.copyWith(libp2pEnabled: action.enabled);
  }

  if (action is UpdateTransportSettingsAction) {
    return state.copyWith(
      bluetoothEnabled: action.bluetoothEnabled,
      libp2pEnabled: action.libp2pEnabled,
      transportPriority: action.transportPriority,
    );
  }

  if (action is HydrateSettingsAction) {
    return action.settings;
  }

  return state;
}
