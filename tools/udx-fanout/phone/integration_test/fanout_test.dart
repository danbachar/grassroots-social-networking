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
///
/// ISOLATES (throughput mode only, CHUNK_BYTES>0) splits PEERS as evenly as
/// possible across that many worker isolates, each with its own bound UDP
/// socket, UDXMultiplexer and write loop. This tests whether the single
/// event loop scheduling every stream's write is itself the fan-out cost.
/// The default, 1, is the original single-isolate path, left untouched so
/// existing sweep numbers stay comparable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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
/// Bytes per write in throughput mode. 0 instead holds the streams idle
/// and keepalives them, which is the mapping-lifetime run, not this one.
const _chunkBytes = int.fromEnvironment('CHUNK_BYTES', defaultValue: 0);
const _reportS = int.fromEnvironment('REPORT_S', defaultValue: 10);
const _isolates = int.fromEnvironment('ISOLATES', defaultValue: 1);

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
      if (_isolates > 1 && _chunkBytes > 0) {
        await runMultiIsolate();
        return;
      }
      await runSingleIsolate();
    });
  }, timeout: Timeout(Duration(seconds: _holdS + 300)));
}

Future<void> runSingleIsolate() async {
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

  final deadline = DateTime.now().add(Duration(seconds: _holdS));
  if (_chunkBytes > 0) {
    await pushLoad(streams, rtts, deadline);
  } else {
    await keepaliveLoad(streams, echoes, probes, rtts, deadline);
  }

  emit('run_end', {
    'opened': streams.length,
    'requested': _peers,
    'echoTotal': echoes.values.fold<int>(0, (a, b) => a + b),
    'probeTotal': probes.values.fold<int>(0, (a, b) => a + b),
    'peersEchoing': echoes.length,
    'peersProbed': probes.length,
  });

  // Tear the whole thing down explicitly, and give the close packets
  // time to leave before the process exits. A repeat that starts while
  // the responder still holds the previous run's sockets is not an
  // independent run — it inherits their state and their flow control.
  for (final s in streams.values) {
    try {
      await s.close();
    } catch (_) {
      // already gone; the point is that nothing is left open
    }
  }
  mux.close();
  raw.close();
  await Future<void>.delayed(const Duration(seconds: 2));
  emit('closed', {'streams': streams.length});
}

/// Writes continuously on every stream at once and reports what moved.
///
/// UDX flow control paces each write, so the loop needs no rate limiter of
/// its own: what it measures is what the transport allowed. The spread
/// across streams is the point rather than the sum — a fan-out whose
/// aggregate holds up while its slowest stream goes to zero has not kept
/// working, it has starved a peer, and the total hides that.
Future<void> pushLoad(
    Map<int, UDXStream> streams, List<int> rtts, DateTime deadline) async {
  final chunk = Uint8List(_chunkBytes);
  for (var i = 0; i < chunk.length; i++) {
    chunk[i] = i & 0xff;
  }
  final written = <int, int>{for (final p in streams.keys) p: 0};
  final last = <int, int>{for (final p in streams.keys) p: 0};
  final errors = <int, int>{for (final p in streams.keys) p: 0};

  final writers = <Future<void>>[];
  streams.forEach((port, stream) {
    writers.add(Future(() async {
      while (DateTime.now().isBefore(deadline)) {
        try {
          await stream.add(chunk);
          written[port] = written[port]! + chunk.length;
        } catch (e) {
          errors[port] = errors[port]! + 1;
          if (errors[port]! > 20) return; // this stream is gone
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    }));
  });

  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(Duration(seconds: _reportS));
    final rates = <int>[];
    streams.forEach((port, _) {
      rates.add((written[port]! - last[port]!) ~/ _reportS);
      last[port] = written[port]!;
    });
    rates.sort();
    int at(double q) =>
        rates.isEmpty ? 0 : rates[(q * (rates.length - 1)).round()];
    emit('throughput', {
      'streams': streams.length,
      'windowS': _reportS,
      'aggregateBps': rates.fold<int>(0, (a, b) => a + b),
      'perStreamMinBps': rates.isEmpty ? 0 : rates.first,
      'perStreamP50Bps': at(0.5),
      'perStreamP90Bps': at(0.9),
      'perStreamMaxBps': rates.isEmpty ? 0 : rates.last,
      'stalled': rates.where((r) => r == 0).length,
      'writeErrors': errors.values.fold<int>(0, (a, b) => a + b),
    });
  }
  await Future.wait(writers);

  final total = written.values.fold<int>(0, (a, b) => a + b);
  emit('load_end', {
    'streams': streams.length,
    'totalBytes': total,
    'aggregateBps': total ~/ _holdS,
    'meanBpsPerStream': total ~/ (_holdS * streams.length),
    'writeErrors': errors.values.fold<int>(0, (a, b) => a + b),
    'starvedStreams': written.values.where((b) => b == 0).length,
  });
}

/// Idle hold: one small keepalive per stream per tick, timed. This is the
/// mapping-lifetime and latency run, not the throughput one.
Future<void> keepaliveLoad(Map<int, UDXStream> streams, Map<int, int> echoes,
    Map<int, int> probes, List<int> rtts, DateTime deadline) async {
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
    await Future<void>.delayed(const Duration(seconds: 3));
    final sample = List<int>.from(rtts)..sort();
    int pct(double q) =>
        sample.isEmpty ? -1 : sample[(q * (sample.length - 1)).round()] ~/ 1000;
    emit('keepalive', {
      'tick': tick,
      'sent': sent,
      'failed': failed,
      'fanOutMs': DateTime.now().difference(fanStart).inMilliseconds,
      'rttSamples': sample.length,
      'rttP50Ms': pct(0.5),
      'rttP90Ms': pct(0.9),
      'rttMaxMs': pct(1.0),
      'echoes': echoes.values.fold<int>(0, (a, b) => a + b),
      'probes': probes.values.fold<int>(0, (a, b) => a + b),
    });
  }
}

/// One worker's slice of the fan-out: the ports it owns and where to send
/// progress. Everything here must be safe to pass across an isolate
/// boundary — plain data only, no UDX objects.
class _WorkerInit {
  _WorkerInit(this.sendPort, this.workerIndex, this.ports, this.deadlineMs);
  final SendPort sendPort;
  final int workerIndex;
  final List<int> ports;
  final int deadlineMs;
}

/// A worker's tick: cumulative bytes written per port since the worker
/// started, so the coordinator can diff against its own previous snapshot
/// on its own clock rather than trying to line up N independent timers.
class _WorkerTick {
  _WorkerTick(this.workerIndex, this.written, this.errors);
  final int workerIndex;
  final Map<int, int> written;
  final Map<int, int> errors;
}

class _WorkerDone {
  _WorkerDone(this.workerIndex);
  final int workerIndex;
}

Future<void> runMultiIsolate() async {
  emit('run_start', {
    'host': _host,
    'basePort': _basePort,
    'peers': _peers,
    'holdS': _holdS,
    'isolates': _isolates,
  });

  final allPorts = List<int>.generate(_peers, (i) => _basePort + i);
  final workerCount = _isolates > _peers ? _peers : _isolates;
  final slices = <List<int>>[for (var i = 0; i < workerCount; i++) []];
  for (var i = 0; i < allPorts.length; i++) {
    slices[i % workerCount].add(allPorts[i]);
  }

  final deadline = DateTime.now().add(Duration(seconds: _holdS));
  final receive = ReceivePort();
  final done = <int>{};
  final isolates = <Isolate>[];

  // Live, merged view: port -> cumulative bytes / errors, kept current by
  // whichever worker last reported. The coordinator's own report timer
  // reads this on its own clock, so it never waits for workers to agree
  // on when a window ends.
  final written = <int, int>{for (final p in allPorts) p: 0};
  final errors = <int, int>{for (final p in allPorts) p: 0};
  final last = <int, int>{for (final p in allPorts) p: 0};
  var openedOk = 0;
  final openedWorkers = <int>{};

  final openedCompleter = Completer<void>();
  final allDoneCompleter = Completer<void>();

  receive.listen((message) {
    if (message is Map && message['ev'] == 'open_ok') {
      emit('open_ok', {
        'port': message['port'],
        'isolate': message['isolate'],
        'ms': message['ms'],
      });
    } else if (message is Map && message['ev'] == 'open_fail') {
      emit('open_fail', {
        'port': message['port'],
        'isolate': message['isolate'],
        'ms': message['ms'],
        'error': message['error'],
      });
    } else if (message is Map && message['ev'] == 'opened_worker') {
      openedOk += message['ok'] as int;
      openedWorkers.add(message['isolate'] as int);
      if (openedWorkers.length == workerCount && !openedCompleter.isCompleted) {
        openedCompleter.complete();
      }
    } else if (message is _WorkerTick) {
      written.addAll(message.written);
      errors.addAll(message.errors);
    } else if (message is _WorkerDone) {
      done.add(message.workerIndex);
      if (done.length == workerCount && !allDoneCompleter.isCompleted) {
        allDoneCompleter.complete();
      }
    }
  });

  for (var w = 0; w < workerCount; w++) {
    final iso = await Isolate.spawn(
      _pushWorkerMain,
      _WorkerInit(receive.sendPort, w, slices[w], deadline.millisecondsSinceEpoch),
    );
    isolates.add(iso);
  }

  // Workers open their streams concurrently; wait for every worker to
  // report in, capped so one wedged worker cannot hang the run.
  await openedCompleter.future
      .timeout(Duration(seconds: _connectTimeoutS + 15), onTimeout: () {});

  emit('opened', {'ok': openedOk, 'requested': _peers});
  if (openedOk == 0) {
    emit('run_end', {'reason': 'no streams opened'});
    for (final iso in isolates) {
      iso.kill(priority: Isolate.immediate);
    }
    receive.close();
    return;
  }

  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(Duration(seconds: _reportS));
    final rates = <int>[];
    for (final port in allPorts) {
      rates.add(((written[port] ?? 0) - (last[port] ?? 0)) ~/ _reportS);
      last[port] = written[port] ?? 0;
    }
    rates.sort();
    int at(double q) =>
        rates.isEmpty ? 0 : rates[(q * (rates.length - 1)).round()];
    emit('throughput', {
      'streams': allPorts.length,
      'windowS': _reportS,
      'aggregateBps': rates.fold<int>(0, (a, b) => a + b),
      'perStreamMinBps': rates.isEmpty ? 0 : rates.first,
      'perStreamP50Bps': at(0.5),
      'perStreamP90Bps': at(0.9),
      'perStreamMaxBps': rates.isEmpty ? 0 : rates.last,
      'stalled': rates.where((r) => r == 0).length,
      'writeErrors': errors.values.fold<int>(0, (a, b) => a + b),
    });
  }

  await allDoneCompleter.future.timeout(const Duration(seconds: 30),
      onTimeout: () {});

  final total = written.values.fold<int>(0, (a, b) => a + b);
  emit('load_end', {
    'streams': allPorts.length,
    'totalBytes': total,
    'aggregateBps': total ~/ _holdS,
    'meanBpsPerStream': total ~/ (_holdS * allPorts.length),
    'writeErrors': errors.values.fold<int>(0, (a, b) => a + b),
    'starvedStreams': written.values.where((b) => b == 0).length,
  });
  emit('run_end', {
    'opened': openedOk,
    'requested': _peers,
    'echoTotal': 0,
    'probeTotal': 0,
    'peersEchoing': 0,
    'peersProbed': 0,
  });

  for (final iso in isolates) {
    iso.kill(priority: Isolate.immediate);
  }
  receive.close();
  await Future<void>.delayed(const Duration(seconds: 2));
  emit('closed', {'streams': openedOk});
}

/// Runs inside a worker isolate: opens this worker's slice of ports, then
/// writes flat out on all of them until the shared deadline, reporting
/// cumulative progress back to the coordinator every second.
Future<void> _pushWorkerMain(_WorkerInit init) async {
  final sendPort = init.sendPort;
  final deadline = DateTime.fromMillisecondsSinceEpoch(init.deadlineMs);

  final raw = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final udx = UDX();
  final mux = UDXMultiplexer(raw);

  final streams = <int, UDXStream>{};
  for (var i = 0; i < init.ports.length; i++) {
    final port = init.ports[i];
    final started = DateTime.now();
    try {
      final socket = mux.createSocket(udx, _host, port);
      final stream = await UDXStream.createOutgoing(
          udx, socket, 5000 + port, 5000 + port, _host, port);
      await socket.handshakeComplete
          .timeout(Duration(seconds: _connectTimeoutS));
      streams[port] = stream;
      sendPort.send({
        'ev': 'open_ok',
        'port': port,
        'isolate': init.workerIndex,
        'ms': DateTime.now().difference(started).inMilliseconds,
      });
    } catch (e) {
      sendPort.send({
        'ev': 'open_fail',
        'port': port,
        'isolate': init.workerIndex,
        'ms': DateTime.now().difference(started).inMilliseconds,
        'error': '$e',
      });
    }
  }
  sendPort.send({
    'ev': 'opened_worker',
    'isolate': init.workerIndex,
    'ok': streams.length,
    'requested': init.ports.length,
  });

  if (streams.isNotEmpty) {
    final chunk = Uint8List(_chunkBytes);
    for (var i = 0; i < chunk.length; i++) {
      chunk[i] = i & 0xff;
    }
    final written = <int, int>{for (final p in streams.keys) p: 0};
    final errors = <int, int>{for (final p in streams.keys) p: 0};

    final writers = <Future<void>>[];
    streams.forEach((port, stream) {
      writers.add(Future(() async {
        while (DateTime.now().isBefore(deadline)) {
          try {
            await stream.add(chunk);
            written[port] = written[port]! + chunk.length;
          } catch (e) {
            errors[port] = errors[port]! + 1;
            if (errors[port]! > 20) return;
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }
      }));
    });

    final ticker = Stream<void>.periodic(const Duration(seconds: 1))
        .takeWhile((_) => DateTime.now().isBefore(deadline))
        .listen((_) {
      sendPort.send(_WorkerTick(
          init.workerIndex, Map<int, int>.from(written), Map<int, int>.from(errors)));
    });

    await Future.wait(writers);
    ticker.cancel();
    sendPort.send(
        _WorkerTick(init.workerIndex, Map<int, int>.from(written), Map<int, int>.from(errors)));

    for (final s in streams.values) {
      try {
        await s.close();
      } catch (_) {
        // already gone
      }
    }
  }

  mux.close();
  raw.close();
  sendPort.send(_WorkerDone(init.workerIndex));
}
