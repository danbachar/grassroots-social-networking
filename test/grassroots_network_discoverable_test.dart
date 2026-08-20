import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/grassroots_network.dart'
    show bleRadioUp;
import 'package:grassroots_networking/src/transport/transport_service.dart';

/// `bleUsable` stamps the `bt-on` marker every establishment measurement is
/// anchored on. `active` means the service finished booting — every role the
/// mode asked for confirmed on the air — so the predicate is a plain state
/// read: the boot semantics live in the transport's own promotion, the same
/// for every test that will ever run, never in a per-test guard.
void main() {
  test('radio-up is exactly the booted state', () {
    expect(bleRadioUp(hasService: true, bleState: TransportState.active), isTrue);
    expect(bleRadioUp(hasService: true, bleState: TransportState.ready), isFalse,
        reason: 'ready = adapter off or a requested role not yet confirmed');
    expect(bleRadioUp(hasService: true, bleState: TransportState.error), isFalse);
    expect(bleRadioUp(hasService: false, bleState: TransportState.active),
        isFalse);
  });
}
