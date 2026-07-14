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

  if (action is HydrateSettingsAction) {
    return action.settings;
  }

  if (action is SetBleRoleModeAction) {
    return state.copyWith(bleRoleMode: action.mode);
  }

  if (action is SetColdCallTrustLevelAction) {
    return state.copyWith(coldCallTrustLevel: action.level);
  }

  if (action is SetTraceLoggingConsentAction) {
    return state.copyWith(
      traceLoggingConsent: action.consent,
      // Record the most recent decision time (grant OR decline). A non-null
      // consentTimestamp means the user has been asked, so we don't re-prompt.
      consentTimestamp: action.consentTimestamp ?? state.consentTimestamp,
    );
  }

  return state;
}
