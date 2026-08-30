/// Pure-UDP counterpart to fanout_test.dart. Fires CHUNK_BYTES worth of
/// data at PEERS remote ports as fast as the OS send buffer accepts it,
/// for HOLD_S seconds — no UDX, no stream, no flow control, no
/// encryption, no acks, no retransmission.
///
/// Same JSON schema as the UDX throughput run (`throughput`/`load_end`
/// with the same field names) so `summarize.py` reads either directory
/// unchanged. Same ISOLATES support too, so the two are compared at the
/// same isolate count rather than single-isolate UDP against
/// multi-isolate UDX.
///
/// CHUNK_BYTES is a *logical* write size, matching UDX's per-write
/// amount for comparability of the write-loop shape. It is NOT one wire
/// datagram: at 32768 bytes it would be silently IP-fragmented into ~23
/// pieces, and losing any ONE of them drops the whole 32KB with no way
/// for either side to know which piece went missing. Measured at N=2
/// with unfragmented 32KB sends: the responder received 9.4% fewer bytes
/// than the phone reported writing. So each logical write is split here
/// into MAX_DATAGRAM_BYTES-sized pieces (default 1400, safely under a
/// standard 1500-byte-MTU path's ~1472-byte IPv4 UDP payload ceiling) —
/// application-level fragmentation instead of relying on the IP layer's,
/// so loss is visible per wire packet instead of amplified per write.
/// This does not make UDP reliable — a dropped packet is still just
/// gone, which is the point of the comparison against UDX — it only
/// removes the self-inflicted loss from oversized datagrams.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _host = String.fromEnvironment('HOST', defaultValue: '127.0.0.1');
const _basePort = int.fromEnvironment('BASE_PORT', defaultValue: 42000);
const _peers = int.fromEnvironment('PEERS', defaultValue: 8);
const _holdS = int.fromEnvironment('HOLD_S', defaultValue: 600);
const _chunkBytes = int.fromEnvironment('CHUNK_BYTES', defaultValue: 32768);
const _maxDatagramBytes =
    int.fromEnvironment('MAX_DATAGRAM_BYTES', defaultValue: 1400);
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

  testWidgets('hold $_peers raw UDP flows', (tester) async {
    await tester.runAsync(() async {
      if (_isolates > 1) {
        await runMultiIsolate();
      } else {
        await runSingleIsolate();
      }
    });
  }, timeout: Timeout(Duration(seconds: _holdS + 300)));
}

/// Builds the fixed set of MTU-safe pieces one logical CHUNK_BYTES write
/// is split into, so the split cost is paid once, not on every write.
List<Uint8List> buildPieces() {
  final pieces = <Uint8List>[];
  var remaining = _chunkBytes;
  var offset = 0;
  while (remaining > 0) {
    final size = remaining < _maxDatagramBytes ? remaining : _maxDatagramBytes;
    final piece = Uint8List(size);
    for (var i = 0; i < size; i++) {
      piece[i] = (offset + i) & 0xff;
    }
    pieces.add(piece);
    offset += size;
    remaining -= size;
  }
  return pieces;
}

Future<void> runSingleIsolate() async {
  emit('run_start', {
    'host': _host,
    'basePort': _basePort,
    'peers': _peers,
    'holdS': _holdS,
    'maxDatagramBytes': _maxDatagramBytes,
  });

  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  emit('bound', {'localPort': socket.port});

  final ports = List<int>.generate(_peers, (i) => _basePort + i);
  emit('opened', {'ok': ports.length, 'requested': _peers});

  final deadline = DateTime.now().add(Duration(seconds: _holdS));
  await pushLoad(socket, ports, deadline);

  emit('run_end', {'opened': ports.length, 'requested': _peers});

  socket.close();
  await Future<void>.delayed(const Duration(seconds: 2));
  emit('closed', {'streams': ports.length});
}

/// Fires MTU-safe pieces at every port at once and reports what actually
/// sent. `send` is fire-and-forget: a return short of the piece size
/// means the OS refused it (buffer full), which is this transport's only
/// form of backpressure and is counted as a write error, same as a
/// failed UDX write.
Future<void> pushLoad(
    RawDatagramSocket socket, List<int> ports, DateTime deadline) async {
  final pieces = buildPieces();
  final addr = InternetAddress(_host);
  final written = <int, int>{for (final p in ports) p: 0};
  final last = <int, int>{for (final p in ports) p: 0};
  final errors = <int, int>{for (final p in ports) p: 0};

  final writers = <Future<void>>[];
  for (final port in ports) {
    writers.add(Future(() async {
      while (DateTime.now().isBefore(deadline)) {
        for (final piece in pieces) {
          final sent = socket.send(piece, addr, port);
          if (sent == piece.length) {
            written[port] = written[port]! + sent;
          } else {
            errors[port] = errors[port]! + 1;
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          // Yield so the other ports' writers and the report timer get a
          // turn; without this a single port could run the event loop dry.
          await Future<void>.delayed(Duration.zero);
        }
      }
    }));
  }

  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(Duration(seconds: _reportS));
    final rates = <int>[];
    for (final port in ports) {
      rates.add((written[port]! - last[port]!) ~/ _reportS);
      last[port] = written[port]!;
    }
    rates.sort();
    int at(double q) =>
        rates.isEmpty ? 0 : rates[(q * (rates.length - 1)).round()];
    emit('throughput', {
      'streams': ports.length,
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
    'streams': ports.length,
    'totalBytes': total,
    'aggregateBps': total ~/ _holdS,
    'meanBpsPerStream': total ~/ (_holdS * ports.length),
    'writeErrors': errors.values.fold<int>(0, (a, b) => a + b),
    'starvedStreams': written.values.where((b) => b == 0).length,
  });
}

class _WorkerInit {
  _WorkerInit(this.sendPort, this.workerIndex, this.ports, this.deadlineMs);
  final SendPort sendPort;
  final int workerIndex;
  final List<int> ports;
  final int deadlineMs;
}

class _WorkerTick {
  _WorkerTick(this.written, this.errors);
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
    'maxDatagramBytes': _maxDatagramBytes,
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

  final written = <int, int>{for (final p in allPorts) p: 0};
  final errors = <int, int>{for (final p in allPorts) p: 0};
  final last = <int, int>{for (final p in allPorts) p: 0};

  final allDoneCompleter = Completer<void>();

  receive.listen((message) {
    if (message is _WorkerTick) {
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

  emit('opened', {'ok': allPorts.length, 'requested': _peers});

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
  emit('run_end', {'opened': allPorts.length, 'requested': _peers});

  for (final iso in isolates) {
    iso.kill(priority: Isolate.immediate);
  }
  receive.close();
  await Future<void>.delayed(const Duration(seconds: 2));
  emit('closed', {'streams': allPorts.length});
}

Future<void> _pushWorkerMain(_WorkerInit init) async {
  final sendPort = init.sendPort;
  final deadline = DateTime.fromMillisecondsSinceEpoch(init.deadlineMs);
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final addr = InternetAddress(_host);
  final pieces = buildPieces();

  final written = <int, int>{for (final p in init.ports) p: 0};
  final errors = <int, int>{for (final p in init.ports) p: 0};

  final writers = <Future<void>>[];
  for (final port in init.ports) {
    writers.add(Future(() async {
      while (DateTime.now().isBefore(deadline)) {
        for (final piece in pieces) {
          final sent = socket.send(piece, addr, port);
          if (sent == piece.length) {
            written[port] = written[port]! + sent;
          } else {
            errors[port] = errors[port]! + 1;
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          await Future<void>.delayed(Duration.zero);
        }
      }
    }));
  }

  final ticker = Stream<void>.periodic(const Duration(seconds: 1))
      .takeWhile((_) => DateTime.now().isBefore(deadline))
      .listen((_) {
    sendPort.send(
        _WorkerTick(Map<int, int>.from(written), Map<int, int>.from(errors)));
  });

  await Future.wait(writers);
  ticker.cancel();
  sendPort.send(
      _WorkerTick(Map<int, int>.from(written), Map<int, int>.from(errors)));

  socket.close();
  sendPort.send(_WorkerDone(init.workerIndex));
}
