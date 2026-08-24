import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_bluetooth_layer/grassroots_bluetooth_layer.dart'
    as ble;
import 'package:grassroots_networking/src/transport/ble_transport_service.dart';

/// A flood must put each packet on the air ONCE per peer, not once per GATT
/// leg. These pin `selectBroadcastTargets`, the leg picker behind
/// `BleTransportService.broadcast`.

ble.BlePath _path(String pathId, ble.BleRole role, {int? rssi}) => ble.BlePath(
      pathId: pathId,
      role: role,
      state: ble.BlePathState.ready,
      mtu: 185,
      canSend: true,
      rssi: rssi,
    );

Uint8List _pubkey(int base) =>
    Uint8List.fromList(List.generate(32, (i) => (base + i) & 0xff));

/// pathId → identity, mimicking `getPubkeyForPeerId`. Anything absent is an
/// unidentified path (connected, no ANNOUNCE yet).
Uint8List? Function(String) _lookup(Map<String, Uint8List> map) =>
    (pathId) => map[pathId];

void main() {

  group('selectBroadcastTargets', () {
    test('a dual-leg pair is written once, on the peripheral (notify) leg',
        () {
      final targets = BleTransportService.selectBroadcastTargets(
        ready: [
          _path('central-A', ble.BleRole.central),
          _path('peripheral-A', ble.BleRole.peripheral),
        ],
        pubkeyFor: _lookup({
          'central-A': _pubkey(0),
          'peripheral-A': _pubkey(0), // same identity, other leg
        }),
      );
      expect(targets.map((p) => p.pathId), ['peripheral-A']);
    });

    test('leg order does not matter: peripheral still wins', () {
      final targets = BleTransportService.selectBroadcastTargets(
        ready: [
          _path('peripheral-A', ble.BleRole.peripheral),
          _path('central-A', ble.BleRole.central),
        ],
        pubkeyFor: _lookup(
            {'central-A': _pubkey(0), 'peripheral-A': _pubkey(0)}),
      );
      expect(targets.map((p) => p.pathId), ['peripheral-A']);
    });

    test('a single-leg pair is written on whichever leg exists', () {
      for (final role in [ble.BleRole.central, ble.BleRole.peripheral]) {
        final targets = BleTransportService.selectBroadcastTargets(
          ready: [_path('only', role)],
          pubkeyFor: _lookup({'only': _pubkey(0)}),
        );
        expect(targets.map((p) => p.pathId), ['only'], reason: '$role');
      }
    });

    test('distinct peers each get exactly one write', () {
      final targets = BleTransportService.selectBroadcastTargets(
        ready: [
          _path('central-A', ble.BleRole.central, rssi: -40),
          _path('peripheral-A', ble.BleRole.peripheral),
          _path('central-B', ble.BleRole.central, rssi: -70),
          _path('peripheral-B', ble.BleRole.peripheral),
        ],
        pubkeyFor: _lookup({
          'central-A': _pubkey(0),
          'peripheral-A': _pubkey(0),
          'central-B': _pubkey(100),
          'peripheral-B': _pubkey(100),
        }),
      );
      expect(targets.map((p) => p.pathId), ['peripheral-A', 'peripheral-B']);
    });

    test('unidentified paths are all kept — a pre-ANNOUNCE pair is not muted',
        () {
      final targets = BleTransportService.selectBroadcastTargets(
        ready: [
          _path('central-A', ble.BleRole.central),
          _path('peripheral-A', ble.BleRole.peripheral),
          _path('unknown-1', ble.BleRole.central),
          _path('unknown-2', ble.BleRole.peripheral),
        ],
        pubkeyFor: _lookup(
            {'central-A': _pubkey(0), 'peripheral-A': _pubkey(0)}),
      );
      expect(targets.map((p) => p.pathId),
          ['peripheral-A', 'unknown-1', 'unknown-2']);
    });

    test('excluding one leg excludes the whole peer, not just that leg', () {
      // The relay excludes the path a packet arrived on. Without identity
      // resolution the pair's OTHER leg echoed it back at the sender.
      final targets = BleTransportService.selectBroadcastTargets(
        ready: [
          _path('central-A', ble.BleRole.central),
          _path('peripheral-A', ble.BleRole.peripheral),
          _path('peripheral-B', ble.BleRole.peripheral),
        ],
        pubkeyFor: _lookup({
          'central-A': _pubkey(0),
          'peripheral-A': _pubkey(0),
          'peripheral-B': _pubkey(100),
        }),
        excludePeerIds: {'central-A'},
      );
      expect(targets.map((p) => p.pathId), ['peripheral-B']);
    });

    test('an unidentified path can still be excluded by pathId', () {
      final targets = BleTransportService.selectBroadcastTargets(
        ready: [
          _path('unknown-1', ble.BleRole.central),
          _path('unknown-2', ble.BleRole.peripheral),
        ],
        pubkeyFor: _lookup(const {}),
        excludePeerIds: {'unknown-1'},
      );
      expect(targets.map((p) => p.pathId), ['unknown-2']);
    });

    test('no ready paths yields no targets', () {
      expect(
        BleTransportService.selectBroadcastTargets(
            ready: const [], pubkeyFor: _lookup(const {})),
        isEmpty,
      );
    });
  });
}
