import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/store/transports_actions.dart';
import 'package:grassroots_networking/src/store/transports_reducer.dart';
import 'package:grassroots_networking/src/store/transports_state.dart';

/// A pair's connection is described by two different numbers, and the one that
/// says whether it converged is the LEGS. Both GATT directions normally ride a
/// single ACL under one remote address, so counting links attributes the same
/// figure to a converged dual-role pair and to a half-open one.
void main() {
  group('bleLinkTallyForPathIds', () {
    const peerPaths = [
      'central:AA:BB:CC:DD:EE:FF',
      'peripheral:AA:BB:CC:DD:EE:FF',
    ];

    test('a converged pair sharing one ACL reports two legs', () {
      final t = bleLinkTallyForPathIds(const [
        BleLinkDiagnostic(
            address: 'AA:BB:CC:DD:EE:FF', clientRole: true, serverRole: true),
      ], peerPaths);
      expect(t.legs, 2, reason: 'both GATT directions are live');
      expect(t.acls, 1, reason: 'they ride a single physical link');
      expect(t.isDualRole, isTrue);
    });

    test('a half-open pair on the same address is NOT dual-role', () {
      // The case a link count cannot express: same ACL figure as the converged
      // pair above, one leg instead of two.
      final t = bleLinkTallyForPathIds(const [
        BleLinkDiagnostic(
            address: 'AA:BB:CC:DD:EE:FF', clientRole: true, serverRole: false),
      ], peerPaths);
      expect(t.legs, 1);
      expect(t.acls, 1);
      expect(t.isDualRole, isFalse);
    });

    test('a pair holding two ACLs counts both legs and both links', () {
      // The peer presented a different address per direction, so the pair is
      // converged across two physical links rather than one.
      final t = bleLinkTallyForPathIds(const [
        BleLinkDiagnostic(
            address: 'AA:BB:CC:DD:EE:FF', clientRole: true, serverRole: false),
        BleLinkDiagnostic(
            address: '11:22:33:44:55:66', clientRole: false, serverRole: true),
      ], const [
        'central:AA:BB:CC:DD:EE:FF',
        'peripheral:11:22:33:44:55:66',
      ]);
      expect(t.legs, 2);
      expect(t.acls, 2);
      expect(t.isDualRole, isTrue);
    });

    test("another peer's links are not attributed to this one", () {
      final t = bleLinkTallyForPathIds(const [
        BleLinkDiagnostic(
            address: '99:99:99:99:99:99', clientRole: true, serverRole: true),
      ], peerPaths);
      expect(t.legs, 0);
      expect(t.acls, 0);
    });

    test('a peer with no live paths tallies nothing', () {
      final t = bleLinkTallyForPathIds(const [
        BleLinkDiagnostic(
            address: 'AA:BB:CC:DD:EE:FF', clientRole: true, serverRole: true),
      ], const [null, null]);
      expect(t.legs, 0);
      expect(t.acls, 0);
    });
  });

  group('systemBtOn — the OS toggle, projected not remembered', () {
    test('an emitted state is projected, and losing the source clears it', () {
      // Null has to stay REACHABLE. A screen that renders a remembered
      // value as a live status warns about a toggle the operator already
      // flipped, and an alarm that is wrong is one they learn to ignore —
      // including on the run where the adapter really is off.
      var s = transportsReducer(
          TransportsState.initial, SystemBtStateChangedAction(true));
      expect(s.systemBtOn, isTrue);

      s = transportsReducer(s, SystemBtStateChangedAction(false));
      expect(s.systemBtOn, isFalse);

      s = transportsReducer(s, SystemBtStateChangedAction(null));
      expect(s.systemBtOn, isNull,
          reason: 'the service that reported it went away; unknown, not '
              'the last thing it said');
    });

    test('an unrelated transport action leaves it alone', () {
      var s = transportsReducer(
          TransportsState.initial, SystemBtStateChangedAction(true));
      s = transportsReducer(s, BleScanningChangedAction(true));
      expect(s.systemBtOn, isTrue);
      expect(s.bleScanning, isTrue);
    });
  });
}
