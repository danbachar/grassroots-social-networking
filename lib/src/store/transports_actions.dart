import '../transport/transport_service.dart';

/// Base class for transport state actions
abstract class TransportAction {}

/// Update BLE transport lifecycle state
class BleTransportStateChangedAction extends TransportAction {
  final TransportState state;
  final String? error;

  BleTransportStateChangedAction(this.state, {this.error});
}

/// Update libp2p transport lifecycle state
class LibP2PTransportStateChangedAction extends TransportAction {
  final TransportState state;
  final String? error;

  LibP2PTransportStateChangedAction(this.state, {this.error});
}

/// BLE scanning state changed
class BleScanningChangedAction extends TransportAction {
  final bool scanning;

  BleScanningChangedAction(this.scanning);
}
