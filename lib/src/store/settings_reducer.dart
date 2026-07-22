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
    // Turning cold-call closed also withdraws the introduce-strangers
    // opt-in, since introducing is a strictly more-open stance (the
    // effective willingness is AND-gated, but keeping the stored flag in
    // sync avoids a surprise re-enable when cold-call reopens).
    if (action.level == ColdCallTrustLevel.closed) {
      return state.copyWith(
        coldCallTrustLevel: action.level,
        facilitateInvites: false,
      );
    }
    return state.copyWith(coldCallTrustLevel: action.level);
  }

  if (action is SetFacilitateInvitesAction) {
    return state.copyWith(facilitateInvites: action.enabled);
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
