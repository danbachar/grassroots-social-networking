import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/grassroots_network.dart'
    show bleRadioUp;
import 'package:grassroots_networking/src/store/store.dart';
import 'package:grassroots_networking/src/transport/transport_service.dart';

/// `bleUsable` is what stamps the `bt-on` marker every establishment
/// measurement is anchored on, so it must mean the radio is participating —
/// not merely that the transport got far enough to scan.
void main() {
  bool radioUp({
    bool hasService = true,
    TransportState bleState = TransportState.active,
    BleRoleMode roleMode = BleRoleMode.auto,
    bool advertising = true,
  }) =>
      bleRadioUp(
        hasService: hasService,
        bleState: bleState,
        roleMode: roleMode,
        advertising: advertising,
      );

  test('an active transport that is not advertising is not radio-up', () {
    // The scan alone carried it to active. Peers cannot see this phone, so
    // its inbound leg can never form and it is not participating.
    expect(radioUp(advertising: false), isFalse);
    expect(radioUp(advertising: true), isTrue);
  });

  test('central-only is radio-up without advertising', () {
    // A mode that never asks to advertise is not undiscoverable by fault.
    expect(radioUp(roleMode: BleRoleMode.centralOnly, advertising: false),
        isTrue);
  });

  test('peripheral-only still requires the advertisement', () {
    expect(radioUp(roleMode: BleRoleMode.peripheralOnly, advertising: false),
        isFalse);
    expect(radioUp(roleMode: BleRoleMode.peripheralOnly, advertising: true),
        isTrue);
  });

  test('advertising does not make a parked transport radio-up', () {
    // `ready` is where the transport parks with the adapter off — a stale
    // advertising flag must not resurrect it.
    expect(radioUp(bleState: TransportState.ready, advertising: true), isFalse);
    expect(radioUp(bleState: TransportState.error, advertising: true), isFalse);
  });

  test('no transport at all is never radio-up', () {
    expect(radioUp(hasService: false), isFalse);
  });
}
