import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/grassroots_network.dart'
    show bleUndiscoverableFrom;
import 'package:grassroots_networking/src/store/store.dart';
import 'package:grassroots_networking/src/transport/transport_service.dart';

/// The operator-facing half of the discoverability guard.
///
/// Refusing to call an undiscoverable phone radio-up keeps the trace honest,
/// but the trace is read after the run. A field sweep spent 95 minutes with
/// one phone never advertising and nothing on its screen said so.
void main() {
  bool undiscoverable({
    bool hasService = true,
    TransportState bleState = TransportState.active,
    BleRoleMode roleMode = BleRoleMode.auto,
    bool advertising = false,
  }) =>
      bleUndiscoverableFrom(
        hasService: hasService,
        bleState: bleState,
        roleMode: roleMode,
        advertising: advertising,
      );

  test('running, scanning, and invisible is the case worth warning about', () {
    expect(undiscoverable(advertising: false), isTrue);
    expect(undiscoverable(advertising: true), isFalse);
  });

  test('central-only never advertises by design, so it is not a fault', () {
    expect(undiscoverable(roleMode: BleRoleMode.centralOnly), isFalse);
  });

  test('a reset or a parked transport is not a fault either', () {
    // Warning through every per-step reset would train the operator to
    // ignore the banner by the third distance.
    expect(undiscoverable(hasService: false), isFalse);
    expect(undiscoverable(bleState: TransportState.ready), isFalse);
    expect(undiscoverable(bleState: TransportState.disposed), isFalse);
  });
}
