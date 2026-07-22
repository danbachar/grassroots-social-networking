import '../testbed/testbed_config.dart';
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

/// Opt in/out of trace logging + upload. [consentTimestamp] is computed at the
/// dispatch site (reducers are pure) and stored only when opting in.
class SetTraceLoggingConsentAction extends SettingsAction {
  final bool consent;
  final String? consentTimestamp;

  SetTraceLoggingConsentAction(this.consent, {this.consentTimestamp});
}

/// DEBUG/TESTBED ONLY. Install (or clear, with null) the software-defined BLE
/// topology allowlist.
class SetNeighborAllowlistAction extends SettingsAction {
  final NeighborAllowlist? allowlist;

  SetNeighborAllowlistAction(this.allowlist);
}

/// DEBUG/TESTBED ONLY. Install (or clear, with null) the deterministic
/// offered-load workload config. Does NOT start the driver.
class SetWorkloadConfigAction extends SettingsAction {
  final WorkloadConfig? config;

  SetWorkloadConfigAction(this.config);
}

