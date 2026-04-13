import 'transports_state.dart';
import 'transports_actions.dart';

TransportsState transportsReducer(TransportsState state, TransportAction action) {
  if (action is BleTransportStateChangedAction) {
    return state.copyWith(
      bleState: action.state,
      bleError: action.error,
    );
  }

  if (action is UdpTransportStateChangedAction) {
    return state.copyWith(
      udpState: action.state,
      udpError: action.error,
    );
  }

  if (action is BleScanningChangedAction) {
    return state.copyWith(bleScanning: action.scanning);
  }

  if (action is PublicAddressUpdatedAction) {
    if (action.publicAddress == null) {
      return state.clearPublicAddress();
    }
    return state.copyWith(publicAddress: action.publicAddress);
  }

  if (action is PublicIpUpdatedAction) {
    return state.copyWith(publicIp: action.publicIp);
  }

  return state;
}
