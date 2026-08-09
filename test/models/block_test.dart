import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/models/block.dart';

void main() {
  group('FileSayBlock', () {
    test('round-trips name, mime, and bytes through serialize/deserialize', () {
      final bytes = Uint8List.fromList(List.generate(5000, (i) => i % 256));
      final block = FileSayBlock(
        fileName: 'report final (v2).pdf',
        mime: 'application/pdf',
        bytes: bytes,
      );

      final decoded = Block.deserialize(block.serialize());

      expect(decoded, isA<FileSayBlock>());
      final file = decoded as FileSayBlock;
      expect(file.fileName, equals('report final (v2).pdf'));
      expect(file.mime, equals('application/pdf'));
      expect(file.bytes, equals(bytes));
    });

    test('handles a unicode name and empty bytes', () {
      final block = FileSayBlock(
        fileName: 'סקר_2026.txt',
        mime: 'text/plain',
        bytes: Uint8List(0),
      );
      final file = Block.deserialize(block.serialize()) as FileSayBlock;
      expect(file.fileName, equals('סקר_2026.txt'));
      expect(file.bytes, isEmpty);
    });

    test('a truncated body throws rather than mis-parsing', () {
      final full = FileSayBlock(
        fileName: 'a.bin',
        mime: 'application/octet-stream',
        bytes: Uint8List.fromList([1, 2, 3]),
      ).serialize();
      // Keep the say+subtype header + a couple of body bytes, then cut.
      final truncated = Uint8List.sublistView(full, 0, 4);
      expect(() => Block.deserialize(truncated), throwsFormatException);
    });
  });
}
