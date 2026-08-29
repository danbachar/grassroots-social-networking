/// Opens PEERS UDX streams from this handset to the responders and holds
/// them for HOLD_S seconds, keepaliving each one every KEEPALIVE_S.
///
/// Everything it learns goes to stdout as JSON lines, which `flutter test`
/// carries back to the host. The host samples power in parallel; this side
/// deliberately measures nothing about the battery, so that the two records
/// stay independent and can be lined up by timestamp.
///
/// The line worth reading is `probe_recv`: unsolicited data from a
/// responder that had gone silent, which is proof the NAT mapping outlived
/// that silence. Its absence is the finding — a mapping that expired.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_dart_udx/grassroots_dart_udx.dart';
import 'package:integration_test/integration_test.dart';

const _host = String.fromEnvironment('HOST', defaultValue: '127.0.0.1');
const _basePort = int.fromEnvironment('BASE_PORT', defaultValue: 41000);
const _peers = int.fromEnvironment('PEERS', defaultValue: 8);
const _holdS = int.fromEnvironment('HOLD_S', defaultValue: 600);
const _keepaliveS = int.fromEnvironment('KEEPALIVE_S', defaultValue: 20);
const _connectTimeoutS =
    int.fromEnvironment('CONNECT_TIMEOUT_S', defaultValue: 10);

void emit(String event, [Map<String, Object?> fields = const {}]) {
  // ignore: avoid_print
  print(jsonEncode({
    'ts': DateTime.now().toUtc().toIso8601String(),
    'ev': event,
    ...fields,
  }));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('hold $_peers UDX streams', (tester) async {
    await tester.runAsync(() async {
      emit('run_start', {
        'host': _host,
        'basePort': _basePort,
        'peers': _peers,
        'holdS': _holdS,
        'keepaliveS': _keepaliveS,
      });

      final raw = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final udx = UDX();
      final mux = UDXMultiplexer(raw);
      emit('bound', {'localPort': raw.port});

      final streams = <int, UDXStream>{};
      final echoes = <int, int>{};
      final probes = <int, int>{};
      // Round trips, microseconds, cleared each tick. Failures alone give
      // the cliff; these give the slope leading up to it.
      final rtts = <int>[];

      for (var i = 0; i < _peers; i++) {
        final port = _basePort + i;
        final started = DateTime.now();
        try {
          final socket = mux.createSocket(udx, _host, port);
          final stream = await UDXStream.createOutgoing(
              udx, socket, 5000 + i, 5000 + i, _host, port);
          await socket.handshakeComplete
              .timeout(Duration(seconds: _connectTimeoutS));

          stream.data.listen((bytes) {
            final text = utf8.decode(bytes, allowMalformed: true);
            if (text.startsWith('probe ')) {
              probes[port] = (probes[port] ?? 0) + 1;
              emit('probe_recv', {'port': port, 'bytes': bytes.length});
              return;
            }
            echoes[port] = (echoes[port] ?? 0) + 1;
            // Keepalives carry the microsecond they were sent, so the echo
            // dates itself and no send-time table has to be kept.
            final parts = text.split(' ');
            if (parts.length == 3 && parts[0] == 'ka') {
              final sentAt = int.tryParse(parts[2]);
              if (sentAt != null) {
                rtts.add(DateTime.now().microsecondsSinceEpoch - sentAt);
              }
            }
          }, onError: (Object e) => emit('stream_error', {
                'port': port,
                'error': '$e',
              }));

          streams[port] = stream;
          emit('open_ok', {
            'port': port,
            'ms': DateTime.now().difference(started).inMilliseconds,
          });
        } catch (e) {
          emit('open_fail', {
            'port': port,
            'ms': DateTime.now().difference(started).inMilliseconds,
            'error': '$e',
          });
        }
      }

      emit('opened', {'ok': streams.length, 'requested': _peers});
      if (streams.isEmpty) {
        emit('run_end', {'reason': 'no streams opened'});
        return;
      }

      // Hold. Each tick keepalives every live stream, which is exactly the
      // per-peer cost the deployment exists to price: N packets per
      // interval, and on cellular N wakeups the radio pays for.
      final deadline = DateTime.now().add(Duration(seconds: _holdS));
      var tick = 0;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(Duration(seconds: _keepaliveS));
        tick++;
        var sent = 0, failed = 0;
        rtts.clear();
        final fanStart = DateTime.now();
        for (final entry in streams.entries) {
          try {
            final stamp = DateTime.now().microsecondsSinceEpoch;
            await entry.value
                .add(Uint8List.fromList(utf8.encode('ka $tick $stamp')));
            sent++;
          } catch (e) {
            failed++;
          }
        }
        // Let the echoes come back before reading the round trips off.
        await Future<void>.delayed(const Duration(seconds: 3));
        final sample = List<int>.from(rtts)..sort();
        int pct(double q) => sample.isEmpty
            ? -1
            : sample[(q * (sample.length - 1)).round()] ~/ 1000;
        emit('keepalive', {
          'tick': tick,
          'sent': sent,
          'failed': failed,
          // How long one pass over every stream took: the cost of a
          // keepalive round grows with fan-out even when nothing fails.
          'fanOutMs': DateTime.now().difference(fanStart).inMilliseconds,
          'rttSamples': sample.length,
          'rttP50Ms': pct(0.5),
          'rttP90Ms': pct(0.9),
          'rttMaxMs': pct(1.0),
          'echoes': echoes.values.fold<int>(0, (a, b) => a + b),
          'probes': probes.values.fold<int>(0, (a, b) => a + b),
        });
      }

      emit('run_end', {
        'opened': streams.length,
        'requested': _peers,
        'echoTotal': echoes.values.fold<int>(0, (a, b) => a + b),
        'probeTotal': probes.values.fold<int>(0, (a, b) => a + b),
        'peersEchoing': echoes.length,
        'peersProbed': probes.length,
      });

      for (final s in streams.values) {
        await s.close();
      }
      mux.close();
    });
  }, timeout: Timeout(Duration(seconds: _holdS + 300)));
}
