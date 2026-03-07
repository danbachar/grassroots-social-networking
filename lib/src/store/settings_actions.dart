import 'settings_state.dart';

/// Base class for settings-related actions
abstract class SettingsAction {}

/// Set Bluetooth enabled state
class SetBluetoothEnabledAction extends SettingsAction {
  final bool enabled;

  SetBluetoothEnabledAction(this.enabled);
}

/// Set libp2p enabled state
class SetLibp2pEnabledAction extends SettingsAction {
  final bool enabled;

  SetLibp2pEnabledAction(this.enabled);
}

/// Update both transport settings at once
class UpdateTransportSettingsAction extends SettingsAction {
  final bool? bluetoothEnabled;
  final bool? libp2pEnabled;
  final List<TransportProtocol>? transportPriority;

  UpdateTransportSettingsAction({
    this.bluetoothEnabled,
    this.libp2pEnabled,
    this.transportPriority,
  });
}

/// Hydrate settings from persistence
class HydrateSettingsAction extends SettingsAction {
  final SettingsState settings;

  HydrateSettingsAction(this.settings);
}
