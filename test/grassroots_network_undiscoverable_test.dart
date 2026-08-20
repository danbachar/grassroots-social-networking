import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/grassroots_network.dart'
    show bleUndiscoverableFrom;
import 'package:grassroots_networking/src/store/store.dart';

/// The half-booted phone: scanner confirmed, advertiser not, mode wants
/// both. It finds peers and dials outward while no peer can find it — and
/// since `active` requires every requested role, it never reads radio-up.
/// The banner names the state while the run is still salvageable.
void main() {
  bool undiscoverable({
    bool hasService = true,
    BleRoleMode roleMode = BleRoleMode.auto,
    bool scanning = true,
    bool advertising = false,
  }) =>
      bleUndiscoverableFrom(
        hasService: hasService,
        roleMode: roleMode,
        scanning: scanning,
        advertising: advertising,
      );

  test('scanning without advertising is the case worth warning about', () {
    expect(undiscoverable(scanning: true, advertising: false), isTrue);
    expect(undiscoverable(scanning: true, advertising: true), isFalse);
  });

  test('a radio with nothing confirmed is not half-booted, it is down', () {
    // Airplane mode, adapter off, stack restarting: the scanner is not
    // running either, and the TURN ON BLUETOOTH flow owns that state.
    expect(undiscoverable(scanning: false, advertising: false), isFalse);
  });

  test('central-only never advertises by design', () {
    expect(undiscoverable(roleMode: BleRoleMode.centralOnly), isFalse);
  });

  test('no transport, no warning', () {
    expect(undiscoverable(hasService: false), isFalse);
  });
}
