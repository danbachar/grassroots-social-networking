import 'settings_state.dart';

/// Base class for settings-related actions
abstract class SettingsAction {}

/// Set Bluetooth enabled state
class SetBluetoothEnabledAction extends SettingsAction {
  final bool enabled;

  SetBluetoothEnabledAction(this.enabled);
}

/// Set UDP enabled state
class SetUdpEnabledAction extends SettingsAction {
  final bool enabled;

  SetUdpEnabledAction(this.enabled);
}

/// Update both transport settings at once
class UpdateTransportSettingsAction extends SettingsAction {
  final bool? bluetoothEnabled;
  final bool? udpEnabled;
  final List<TransportProtocol>? transportPriority;

  UpdateTransportSettingsAction({
    this.bluetoothEnabled,
    this.udpEnabled,
    this.transportPriority,
  });
}

/// Hydrate settings from persistence
class HydrateSettingsAction extends SettingsAction {
  final SettingsState settings;

  HydrateSettingsAction(this.settings);
}

/// Set the BLE role mode (debug knob — see [BleRoleMode]).
class SetBleRoleModeAction extends SettingsAction {
  final BleRoleMode mode;

  SetBleRoleModeAction(this.mode);
}

/// Set whether this device volunteers to introduce strangers redeeming an
/// invite issued by one of our friends.
class SetFacilitateInvitesAction extends SettingsAction {
  final bool enabled;

  SetFacilitateInvitesAction(this.enabled);
}

/// Set whether nearby unknown peers may complete BLE first contact.
class SetColdCallTrustLevelAction extends SettingsAction {
  final ColdCallTrustLevel level;

  SetColdCallTrustLevelAction(this.level);
}

/// Debug: toggle the BLE link (ACL) count overlay in the UI.
class SetShowLinkDiagnosticsAction extends SettingsAction {
  final bool enabled;

  SetShowLinkDiagnosticsAction(this.enabled);
}

/// DEBUG/TESTBED ONLY. Arm or disarm the ring-radius link gate.
///
/// A null [radius] disarms it, which is the production state and the state the
/// operator warms the mesh up in — every pair must be able to handshake before
/// the topology is constrained, because a packet may not exist before a session
/// with its target does and sessions form only over a direct link.
///
/// The roster is normalised into ring order by the reducer, not here: ring
/// order has to be a property of the state rather than of the caller, or two
/// phones handed the same roster in different orders would derive different
/// neighbours and the topology would not be a ring.
class SetRingGateAction extends SettingsAction {
  final List<String> rosterHex;
  final int? radius;

  SetRingGateAction({required this.rosterHex, this.radius});
}

/// Testbed: refuse every ANNOUNCE, handshake and link from this phone and
/// leave it out of the session table (see [SettingsState.ignoredPeerHexes]).
class IgnorePeerAction extends SettingsAction {
  final String pubkeyHex;

  IgnorePeerAction(this.pubkeyHex);
}

/// Testbed: lift an [IgnorePeerAction]. The phone pairs again on its next
/// ANNOUNCE.
class UnignorePeerAction extends SettingsAction {
  final String pubkeyHex;

  UnignorePeerAction(this.pubkeyHex);
}
