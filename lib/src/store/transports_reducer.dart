import 'transports_state.dart';
import 'transports_actions.dart';

TransportsState transportsReducer(TransportsState state, TransportAction action) {
  if (action is BleTransportStateChangedAction) {
    return state.copyWith(
      bleState: action.state,
      bleError: action.error,
    );
  }

  if (action is LibP2PTransportStateChangedAction) {
    return state.copyWith(
      libp2pState: action.state,
      libp2pError: action.error,
    );
  }

  if (action is BleScanningChangedAction) {
    return state.copyWith(bleScanning: action.scanning);
  }

  return state;
}
