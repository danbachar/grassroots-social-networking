/// One UDX peer, on one UDP port.
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

late final String label;

void emit(String event, [Map<String, Object?> fields = const {}]) {
  stdout.writeln(jsonEncode({
    'ts': DateTime.now().toUtc().toIso8601String(),
    'peer': label,
    'ev': event,
    ...fields,
  }));
}

int _env(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

Future<void> main(List<String> args) async {
  final port = _env('UDX_PORT', 41000);
  final silenceProbe = _env('SILENCE_PROBE_S', 0);
  final echo = (Platform.environment['ECHO'] ?? 'true') != 'false';
  label = Platform.environment['PEER_LABEL'] ?? 'peer-$port';

  final raw = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
  final mux = UDXMultiplexer(raw);

  emit('listening', {'port': port, 'silenceProbeS': silenceProbe, 'echo': echo});

  // Anything that is not UDX still tells us the peer reached us at all —
  // a punch packet, or a stray retransmit after the stream is gone.
  mux.onRawPacket = (data, address, from) => emit('raw', {
        'src': '${address.address}:$from',
        'bytes': data.length,
      });

  mux.connections.listen((socket) {
    final src = '${socket.remoteAddress.address}:${socket.remotePort}';
    emit('open', {'src': src});

    socket.on('stream').listen((UDXEvent event) {
      final stream = event.data as UDXStream;
      emit('stream', {'src': src, 'streamId': stream.id});

      Timer? probe;
      var received = 0;

      void armProbe() {
        if (silenceProbe <= 0) return;
        probe?.cancel();
        probe = Timer(Duration(seconds: silenceProbe), () async {
          // Unsolicited: nothing was sent to us for silenceProbe seconds, so
          // this only lands if the mapping outlived that silence.
          final payload = utf8.encode('probe $label $silenceProbe');
          emit('probe_send', {'src': src, 'afterS': silenceProbe});
          try {
            await stream.add(Uint8List.fromList(payload));
          } catch (e) {
            emit('probe_error', {'src': src, 'error': '$e'});
          }
        });
      }

      stream.data.listen((bytes) async {
        received += bytes.length;
        emit('data', {'src': src, 'bytes': bytes.length, 'total': received});
        armProbe();
        if (echo) {
          try {
            await stream.add(Uint8List.fromList(bytes));
          } catch (e) {
            emit('echo_error', {'src': src, 'error': '$e'});
          }
        }
      }, onError: (Object e) {
        emit('stream_error', {'src': src, 'error': '$e'});
      }, onDone: () {
        probe?.cancel();
        emit('stream_close', {'src': src, 'total': received});
      });

      armProbe();
    });

    // Streams that arrived before this listener was attached.
    socket.flushStreamBuffer();
  });

  // Held open by the socket; nothing to wait on.
  await Completer<void>().future;
}
