/// Opens one stream to each responder and holds them, so a run can be
/// verified without a phone. The phone-side driver does the same thing
/// against the deployed responders.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:grassroots_dart_udx/grassroots_dart_udx.dart';

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '127.0.0.1';
  final basePort = args.length > 1 ? int.parse(args[1]) : 41000;
  final peers = args.length > 2 ? int.parse(args[2]) : 4;
  final holdS = args.length > 3 ? int.parse(args[3]) : 5;

  final raw = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final udx = UDX();
  final mux = UDXMultiplexer(raw);
  var opened = 0, echoed = 0;

  for (var i = 0; i < peers; i++) {
    final port = basePort + i;
    try {
      final socket = mux.createSocket(udx, host, port);
      final stream = await UDXStream.createOutgoing(
          udx, socket, 1000 + i, 1000 + i, host, port);
      await socket.handshakeComplete.timeout(const Duration(seconds: 5));
      stream.data.listen((b) {
        echoed++;
        print('peer $port echoed ${b.length}B: ${utf8.decode(b, allowMalformed: true)}');
      });
      await stream.add(Uint8List.fromList(utf8.encode('hello from client $i')));
      opened++;
    } catch (e) {
      print('peer $port FAILED: $e');
    }
  }
  print('opened $opened/$peers streams; holding ${holdS}s');
  await Future<void>.delayed(Duration(seconds: holdS));
  print('done: $opened opened, $echoed echoes received');
  exit(opened == peers && echoed >= peers ? 0 : 1);
}
