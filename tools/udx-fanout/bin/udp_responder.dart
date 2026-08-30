/// N plain UDP sockets, one per port, all in one process. No UDX: no
/// stream, no handshake, no flow control, no encryption — just a bound
/// socket that counts or echoes whatever datagrams land on it.
///
/// This is the pure-UDP counterpart to responder.dart, used to separate
/// "cost of N concurrent UDX streams" from "cost of N concurrent sockets
/// on one Dart isolate": if the phone-side fan-out decline shows up here
/// too, it is not UDX-specific overhead (flow control, AEAD, multiplexer
/// demux) — it is the generic cost of driving that many I/O flows from a
/// single event loop.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

void emit(String label, String event,
    [Map<String, Object?> fields = const {}]) {
  stdout.writeln(jsonEncode({
    'ts': DateTime.now().toUtc().toIso8601String(),
    'peer': label,
    'ev': event,
    ...fields,
  }));
}

/// Accepts "42000", "42000-42127", or a comma-separated mix of both.
List<int> parsePorts(String spec) {
  final ports = <int>[];
  for (final part in spec.split(',')) {
    final piece = part.trim();
    if (piece.isEmpty) continue;
    final dash = piece.indexOf('-');
    if (dash < 0) {
      ports.add(int.parse(piece));
      continue;
    }
    final lo = int.parse(piece.substring(0, dash));
    final hi = int.parse(piece.substring(dash + 1));
    for (var p = lo; p <= hi; p++) {
      ports.add(p);
    }
  }
  return ports;
}

int _env(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

final Map<int, int> _bytesIn = {};
final Map<int, int> _lastBytesIn = {};

Future<void> main(List<String> args) async {
  final spec = Platform.environment['UDP_PORTS'] ??
      Platform.environment['UDP_PORT'] ??
      '42000';
  // Sink by default, matching the LAN sink-mode UDX runs this is meant to
  // be compared against.
  final echo = (Platform.environment['ECHO'] ?? 'false') != 'false';
  final prefix = Platform.environment['PEER_PREFIX'] ?? 'udp';

  final ports = parsePorts(spec);
  var bound = 0;
  final unavailable = <int>[];

  for (final port in ports) {
    final label = '$prefix${port.toString().padLeft(5, '0')}';
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
      // Default recvspace on this box is ~768KB (macOS) with an 8MB
      // ceiling (kern.ipc.maxsockbuf); a receive-side kernel buffer
      // overflow drops datagrams with zero signal on either end, which
      // is indistinguishable from real network loss unless ruled out.
      // SO_RCVBUF's numeric option code differs BSD/macOS vs Linux.
      final soRcvbuf = Platform.isLinux ? 8 : 0x1002;
      try {
        socket.setRawOption(
            RawSocketOption.fromInt(RawSocketOption.levelSocket, soRcvbuf, 4 << 20));
      } catch (e) {
        emit(label, 'rcvbuf_set_failed', {'error': '$e'});
      }
      _bytesIn[port] = 0;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? dg;
        while ((dg = socket.receive()) != null) {
          final d = dg!;
          _bytesIn[port] = (_bytesIn[port] ?? 0) + d.data.length;
          if (echo) {
            socket.send(d.data, d.address, d.port);
          }
        }
      }, onError: (Object e) => emit(label, 'socket_error', {'error': '$e'}));
      emit(label, 'listening', {'port': port, 'echo': echo});
      bound++;
    } catch (e) {
      unavailable.add(port);
      emit(label, 'bind_failed', {'port': port, 'error': '$e'});
    }
  }

  final reportS = _env('REPORT_S', 0);
  if (reportS > 0) {
    Timer.periodic(Duration(seconds: reportS), (_) {
      final rates = <int>[];
      var total = 0, active = 0;
      for (final e in _bytesIn.entries) {
        final delta = e.value - (_lastBytesIn[e.key] ?? 0);
        _lastBytesIn[e.key] = e.value;
        total += e.value;
        if (delta > 0) {
          active++;
          rates.add(delta ~/ reportS);
        }
      }
      rates.sort();
      int at(double q) =>
          rates.isEmpty ? 0 : rates[(q * (rates.length - 1)).round()];
      emit('all', 'throughput', {
        'windowS': reportS,
        'activeStreams': active,
        'aggregateBps': rates.fold<int>(0, (a, b) => a + b),
        'perStreamMinBps': rates.isEmpty ? 0 : rates.first,
        'perStreamP50Bps': at(0.5),
        'perStreamMaxBps': rates.isEmpty ? 0 : rates.last,
        'totalBytes': total,
      });
    });
  }

  emit('all', 'ready', {
    'bound': bound,
    'requested': ports.length,
    'unavailable': unavailable,
    'spec': spec,
  });
  if (bound == 0) {
    emit('all', 'fatal', {'reason': 'no ports bound'});
    exit(1);
  }
  await Completer<void>().future;
}
