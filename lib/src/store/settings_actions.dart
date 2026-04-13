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

/// Configure the bootstrap anchor server address.
///
/// The anchor's public key is derived from the owner's identity —
/// only the address needs to be stored.
class SetAnchorServerAction extends SettingsAction {
  final String? anchorAddress;

  SetAnchorServerAction({this.anchorAddress});
}

/// Hydrate settings from persistence
class HydrateSettingsAction extends SettingsAction {
  final SettingsState settings;

  HydrateSettingsAction(this.settings);
}
