import '../testbed/ring_topology.dart';
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

  if (action is SetShowLinkDiagnosticsAction) {
    return state.copyWith(showLinkDiagnostics: action.enabled);
  }

  if (action is SetRingGateAction) {
    // [ringOrder] is applied HERE rather than at the dispatch site: the sort IS
    // the ring, so it has to hold for every roster that reaches the state, from
    // whatever caller and in whatever order it arrived.
    return state.copyWith(
      ringRoster: ringOrder(action.rosterHex),
      ringRadius: action.radius,
    );
  }

  if (action is IgnorePeerAction) {
    return state.copyWith(ignoredPeerHexes: {
      ...state.ignoredPeerHexes,
      action.pubkeyHex.toLowerCase(),
    });
  }

  if (action is UnignorePeerAction) {
    return state.copyWith(
      ignoredPeerHexes: state.ignoredPeerHexes
          .where((h) => h != action.pubkeyHex.toLowerCase())
          .toSet(),
    );
  }

  return state;
}
