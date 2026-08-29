/// UDX peers, one per UDP port, all in one process.
///
/// The phone under test opens a stream to each responder and holds it. Every
/// responder writes one JSON object per line to stdout; the run's answer is
/// read off those lines, so nothing here interprets its own measurements.
///
/// The line that matters most is `open`. It carries the source address and
/// port this responder sees, which is the phone's mapping as its NAT
/// rewrote it. All responders seeing ONE source port means the NAT is
/// endpoint-independent and the whole fan-out costs a single mapping. Each
/// responder seeing a DIFFERENT source port means the NAT is
/// address-and-port-dependent and the fan-out costs N mappings, which is
/// what makes a large backbone expensive to hold open.
///
/// With SILENCE_PROBE_S set, a responder goes quiet for that many seconds
/// after the last byte it received, then sends unsolicited data. Whether the
/// phone ever sees it is the mapping's idle lifetime, which sets the
/// keepalive interval every peer has to pay.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:grassroots_dart_udx/grassroots_dart_udx.dart';

void emit(String label, String event,
    [Map<String, Object?> fields = const {}]) {
  stdout.writeln(jsonEncode({
    'ts': DateTime.now().toUtc().toIso8601String(),
    'peer': label,
    'ev': event,
    ...fields,
  }));
}

/// Accepts "41000", "41000-41127", or a comma-separated mix of both.
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

/// Bytes each port has taken in, for the throughput report.
final Map<int, int> _bytesIn = {};
final Map<int, int> _lastBytesIn = {};

Future<void> main(List<String> args) async {
  final spec = Platform.environment['UDX_PORTS'] ??
      Platform.environment['UDX_PORT'] ??
      '41000';
  final silenceProbe = _env('SILENCE_PROBE_S', 0);
  final echo = (Platform.environment['ECHO'] ?? 'true') != 'false';
  final prefix = Platform.environment['PEER_PREFIX'] ?? 'peer';

  final ports = parsePorts(spec);
  // A peer costs a UDP socket and a multiplexer, not a process. Running the
  // fan-out as one process per peer would need more memory than a small
  // host has, and the handset cannot tell the difference: its NAT keys on
  // the destination address and port, both of which are distinct here.
  var bound = 0;
  final unavailable = <int>[];
  for (final port in ports) {
    final label = '$prefix${port.toString().padLeft(5, '0')}';
    try {
      await serve(port, label, silenceProbe, echo);
      bound++;
    } catch (e) {
      // One taken port must not cost the other hundred. A peer that never
      // bound would otherwise look, from the phone, exactly like a peer the
      // phone failed to reach — so name it here, where the difference is
      // still knowable.
      unavailable.add(port);
      emit(label, 'bind_failed', {'port': port, 'error': '$e'});
    }
  }

  final reportS = _env('REPORT_S', 0);
  if (reportS > 0) {
    // Per-datagram lines would be the load, at throughput rates. Report
    // rates on a timer instead, and say how the slowest stream is doing
    // next to the fastest — an aggregate alone hides one peer starving.
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

Future<void> serve(
    int port, String label, int silenceProbe, bool echo) async {
  final raw = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
  final mux = UDXMultiplexer(raw);

  emit(label, 'listening',
      {'port': port, 'silenceProbeS': silenceProbe, 'echo': echo});

  // Anything that is not UDX still tells us the peer reached us at all —
  // a punch packet, or a stray retransmit after the stream is gone.
  mux.onRawPacket = (data, address, from) => emit(label, 'raw', {
        'src': '${address.address}:$from',
        'bytes': data.length,
      });

  _bytesIn[port] = 0;
  mux.connections.listen((socket) {
    final src = '${socket.remoteAddress.address}:${socket.remotePort}';
    emit(label, 'open', {'src': src, 'port': port});

    socket.on('stream').listen((UDXEvent event) {
      final stream = event.data as UDXStream;
      emit(label, 'stream', {'src': src, 'streamId': stream.id});

      Timer? probe;
      var received = 0;

      void armProbe() {
        if (silenceProbe <= 0) return;
        probe?.cancel();
        probe = Timer(Duration(seconds: silenceProbe), () async {
          // Unsolicited: nothing was sent to us for silenceProbe seconds, so
          // this only lands if the mapping outlived that silence.
          final payload = utf8.encode('probe $label $silenceProbe');
          emit(label, 'probe_send', {'src': src, 'afterS': silenceProbe});
          try {
            await stream.add(Uint8List.fromList(payload));
          } catch (e) {
            emit(label, 'probe_error', {'src': src, 'error': '$e'});
          }
        });
      }

      stream.data.listen((bytes) async {
        received += bytes.length;
        _bytesIn[port] = (_bytesIn[port] ?? 0) + bytes.length;
        if (silenceProbe > 0 || received == bytes.length) {
          // At throughput rates a line per datagram would BE the load, so
          // only the first datagram and the probe runs are logged; volume
          // is carried by the periodic report.
          emit(label, 'data', {'bytes': bytes.length, 'total': received});
        }
        armProbe();
        if (echo) {
          try {
            await stream.add(Uint8List.fromList(bytes));
          } catch (e) {
            emit(label, 'echo_error', {'error': '$e'});
          }
        }
      }, onError: (Object e) {
        emit(label, 'stream_error', {'error': '$e'});
      }, onDone: () {
        probe?.cancel();
        emit(label, 'stream_close', {'total': received});
      });

      armProbe();
    });

    // Streams that arrived before this listener was attached.
    socket.flushStreamBuffer();
  });
}
