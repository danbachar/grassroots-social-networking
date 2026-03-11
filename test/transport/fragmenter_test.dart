import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bitchat_transport/src/transport/fragmenter.dart';

void main() {
  group('Fragmenter', () {
    late Fragmenter fragmenter;

    setUp(() {
      fragmenter = Fragmenter(maxPayloadSize: 512);
    });

    tearDown(() {
      fragmenter.dispose();
    });

    group('split', () {
      test('returns data unchanged when it fits', () {
        final data = Uint8List(512);
        final chunks = fragmenter.split(data);
        expect(chunks.length, 1);
        expect(chunks[0], same(data));
      });

      test('returns data unchanged for small payload', () {
        final data = Uint8List(100);
        final chunks = fragmenter.split(data);
        expect(chunks.length, 1);
        expect(chunks[0], same(data));
      });

      test('fragments data larger than maxPayloadSize', () {
        final data = Uint8List(1000);
        final chunks = fragmenter.split(data);
        expect(chunks.length, 2); // 507 + 493 = 1000
        for (final chunk in chunks) {
          expect(chunk.length, lessThanOrEqualTo(512));
          expect(chunk[0], Fragmenter.fragmentMarker);
        }
      });

      test('fragment header has correct format', () {
        final data = Uint8List(1000);
        final chunks = fragmenter.split(data);

        // Check first chunk header
        expect(chunks[0][0], Fragmenter.fragmentMarker);
        expect(chunks[0][3], 0); // index 0
        expect(chunks[0][4], 2); // total 2

        // Check second chunk header
        expect(chunks[1][0], Fragmenter.fragmentMarker);
        expect(chunks[1][3], 1); // index 1
        expect(chunks[1][4], 2); // total 2
      });

      test('messageId increments between calls', () {
        final data = Uint8List(1000);
        final chunks1 = fragmenter.split(data);
        final chunks2 = fragmenter.split(data);

        final msgId1 = (chunks1[0][1] << 8) | chunks1[0][2];
        final msgId2 = (chunks2[0][1] << 8) | chunks2[0][2];
        expect(msgId2, msgId1 + 1);
      });

      test('handles exact boundary size', () {
        final data = Uint8List(513); // just over limit
        final chunks = fragmenter.split(data);
        expect(chunks.length, 2);
      });

      test('handles large payloads with many fragments', () {
        final data = Uint8List(5000);
        final chunks = fragmenter.split(data);
        // 5000 / 507 = 9.86 → 10 fragments
        expect(chunks.length, 10);
        for (var i = 0; i < chunks.length; i++) {
          expect(chunks[i][0], Fragmenter.fragmentMarker);
          expect(chunks[i][3], i); // index
          expect(chunks[i][4], 10); // total
        }
      });
    });

    group('receive', () {
      test('reassembles in-order fragments', () {
        final data = Uint8List.fromList(List.generate(1000, (i) => i % 256));
        final chunks = fragmenter.split(data);

        Uint8List? result;
        for (final chunk in chunks) {
          result = fragmenter.receive('device1', chunk);
        }

        expect(result, isNotNull);
        expect(result, equals(data));
      });

      test('reassembles out-of-order fragments', () {
        final data = Uint8List.fromList(List.generate(1500, (i) => i % 256));
        final chunks = fragmenter.split(data);

        // Send in reverse order
        for (var i = chunks.length - 1; i > 0; i--) {
          final result = fragmenter.receive('device1', chunks[i]);
          expect(result, isNull);
        }
        // Last one (index 0) completes it
        final result = fragmenter.receive('device1', chunks[0]);
        expect(result, isNotNull);
        expect(result, equals(data));
      });

      test('returns null for incomplete fragments', () {
        final data = Uint8List(1000);
        final chunks = fragmenter.split(data);

        // Only send first chunk
        final result = fragmenter.receive('device1', chunks[0]);
        expect(result, isNull);
      });

      test('handles concurrent reassemblies from different devices', () {
        final data1 = Uint8List.fromList(List.generate(1000, (i) => i % 256));
        final data2 =
            Uint8List.fromList(List.generate(1000, (i) => (i + 50) % 256));

        final chunks1 = fragmenter.split(data1);
        final chunks2 = fragmenter.split(data2);

        // Interleave chunks from different devices
        fragmenter.receive('device1', chunks1[0]);
        fragmenter.receive('device2', chunks2[0]);

        final result1 = fragmenter.receive('device1', chunks1[1]);
        final result2 = fragmenter.receive('device2', chunks2[1]);

        expect(result1, equals(data1));
        expect(result2, equals(data2));
      });

      test('ignores non-fragment data', () {
        final data = Uint8List.fromList([0x01, 0x02, 0x03]);
        final result = fragmenter.receive('device1', data);
        expect(result, isNull);
      });

      test('handles duplicate fragments', () {
        final data = Uint8List.fromList(List.generate(1000, (i) => i % 256));
        final chunks = fragmenter.split(data);

        // Send first chunk twice
        fragmenter.receive('device1', chunks[0]);
        fragmenter.receive('device1', chunks[0]);

        // Complete with second chunk
        final result = fragmenter.receive('device1', chunks[1]);
        expect(result, isNotNull);
        expect(result, equals(data));
      });
    });

    group('round-trip', () {
      for (final size in [513, 1000, 1500, 3000, 5000]) {
        test('preserves data for $size bytes', () {
          final data = Uint8List.fromList(List.generate(size, (i) => i % 256));
          final chunks = fragmenter.split(data);

          Uint8List? result;
          for (final chunk in chunks) {
            result = fragmenter.receive('device1', chunk);
          }

          expect(result, isNotNull);
          expect(result!.length, data.length);
          expect(result, equals(data));
        });
      }
    });

    group('edge cases', () {
      test('returns empty list item for empty data', () {
        final data = Uint8List(0);
        final chunks = fragmenter.split(data);
        expect(chunks.length, 1);
        expect(chunks[0], same(data));
      });

      test('rejects corrupted header with totalFragments=0', () {
        final chunk = Uint8List.fromList([
          Fragmenter.fragmentMarker, 0x00, 0x01, // msgId=1
          0x00, // index=0
          0x00, // total=0 (invalid)
          0x41, 0x42, // data
        ]);
        final result = fragmenter.receive('device1', chunk);
        expect(result, isNull);
      });

      test('rejects corrupted header with fragmentIndex >= totalFragments', () {
        final chunk = Uint8List.fromList([
          Fragmenter.fragmentMarker, 0x00, 0x01, // msgId=1
          0x05, // index=5
          0x02, // total=2 (index >= total)
          0x41, 0x42, // data
        ]);
        final result = fragmenter.receive('device1', chunk);
        expect(result, isNull);
      });

      test('rejects chunk shorter than header size', () {
        final chunk = Uint8List.fromList([Fragmenter.fragmentMarker, 0x00]);
        final result = fragmenter.receive('device1', chunk);
        expect(result, isNull);
      });

      test('constructor throws for maxPayloadSize <= headerSize', () {
        expect(
          () => Fragmenter(maxPayloadSize: Fragmenter.headerSize),
          throwsArgumentError,
        );
        expect(
          () => Fragmenter(maxPayloadSize: 3),
          throwsArgumentError,
        );
      });

      test('handles single-byte chunks that need fragmentation', () {
        // maxPayloadSize=6 means maxChunkSize=1, so each fragment carries 1 byte
        final tiny = Fragmenter(maxPayloadSize: 6);
        addTearDown(tiny.dispose);

        final data = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11]);
        final chunks = tiny.split(data);
        expect(chunks.length, 7);

        Uint8List? result;
        for (final chunk in chunks) {
          result = tiny.receive('dev', chunk);
        }
        expect(result, equals(data));
      });
    });

    group('configurable max size', () {
      test('respects custom maxPayloadSize', () {
        final small = Fragmenter(maxPayloadSize: 100);
        addTearDown(small.dispose);

        final data = Uint8List(200);
        final chunks = small.split(data);
        // maxChunkSize = 100 - 5 = 95, so 200/95 = 3 chunks
        expect(chunks.length, 3);
        for (final chunk in chunks) {
          expect(chunk.length, lessThanOrEqualTo(100));
        }
      });

      test('round-trips with custom maxPayloadSize', () {
        final small = Fragmenter(maxPayloadSize: 50);
        addTearDown(small.dispose);

        final data = Uint8List.fromList(List.generate(200, (i) => i % 256));
        final chunks = small.split(data);

        Uint8List? result;
        for (final chunk in chunks) {
          result = small.receive('dev', chunk);
        }
        expect(result, equals(data));
      });
    });
  });
}
