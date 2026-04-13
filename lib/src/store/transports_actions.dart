import '../transport/transport_service.dart';

/// Base class for transport state actions
abstract class TransportAction {}

/// Update BLE transport lifecycle state
class BleTransportStateChangedAction extends TransportAction {
  final TransportState state;
  final String? error;

  BleTransportStateChangedAction(this.state, {this.error});
}

/// Update UDP transport lifecycle state
class UdpTransportStateChangedAction extends TransportAction {
  final TransportState state;
  final String? error;

  UdpTransportStateChangedAction(this.state, {this.error});
}

/// BLE scanning state changed
class BleScanningChangedAction extends TransportAction {
  final bool scanning;

  BleScanningChangedAction(this.scanning);
}

/// Public address discovered or updated (null to clear)
class PublicAddressUpdatedAction extends TransportAction {
  final String? publicAddress;

  PublicAddressUpdatedAction(this.publicAddress);
}

/// Public IP (no port) discovered or reflected by a friend.
class PublicIpUpdatedAction extends TransportAction {
  final String publicIp;

  PublicIpUpdatedAction(this.publicIp);
}
