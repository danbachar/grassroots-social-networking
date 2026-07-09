import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/protocol/fragment_handler.dart';
import 'package:grassroots_networking/src/models/secure_frame.dart';
import 'package:uuid/uuid.dart';

void main() {
  group('FragmentHandler', () {
    late FragmentHandler handler;
    const uuid = Uuid();

    setUp(() {
      handler = FragmentHandler();
    });

    tearDown(() {
      handler.dispose();
    });

    group('needsFragmentation', () {
      test('returns false for small payload', () {
        final small = Uint8List(100);
        expect(handler.needsFragmentation(small), isFalse);
      });

      test('returns false for payload at threshold', () {
        final atThreshold = Uint8List(FragmentHandler.fragmentThreshold);
        expect(handler.needsFragmentation(atThreshold), isFalse);
      });

      test('returns true for payload above threshold', () {
        final large = Uint8List(FragmentHandler.fragmentThreshold + 1);
        expect(handler.needsFragmentation(large), isTrue);
      });
    });

    group('framesFor', () {
      test('yields a single frame for payload that need not fragment', () {
        final small = Uint8List(100);
        final id = uuid.v4();
        final frames = handler.framesFor(payload: small, messageId: id);

        expect(frames.length, equals(1));
        expect(frames.single.isFragmented, isFalse);
        expect(frames.single.fragCount, equals(1));
        expect(frames.single.fragIndex, equals(0));
        expect(frames.single.messageId, equals(id));
        expect(frames.single.chunk, equals(small));
      });

      test('creates correct number of fragments for large payload', () {
        final payload = Uint8List(1000);
        for (var i = 0; i < payload.length; i++) {
          payload[i] = i % 256;
        }

        final id = uuid.v4();
        final frames = handler.framesFor(payload: payload, messageId: id);

        final expectedFragments =
            (1000 / FragmentHandler.maxFragmentPayload).ceil();
        expect(frames.length, equals(expectedFragments));
        expect(id, isNotEmpty);
      });

      test('first fragment has fragIndex 0', () {
        final payload = Uint8List(1000);
        final frames = handler.framesFor(payload: payload, messageId: uuid.v4());

        expect(frames.first.fragIndex, equals(0));
        expect(frames.first.isFragmented, isTrue);
      });

      test('last fragment has fragIndex fragCount-1', () {
        final payload = Uint8List(1000);
        final frames = handler.framesFor(payload: payload, messageId: uuid.v4());

        expect(frames.last.fragIndex, equals(frames.last.fragCount - 1));
        expect(frames.last.fragIndex, equals(frames.length - 1));
      });

      test('middle fragments have contiguous fragIndex values', () {
        // Need at least 3 fragments: payload > 2 * maxFragmentPayload
        final payload = Uint8List(FragmentHandler.maxFragmentPayload * 3);
        final frames = handler.framesFor(payload: payload, messageId: uuid.v4());

        expect(frames.length, greaterThanOrEqualTo(3));
        for (var i = 1; i < frames.length - 1; i++) {
          expect(frames[i].fragIndex, equals(i));
          expect(frames[i].fragCount, equals(frames.length));
          expect(frames[i].isFragmented, isTrue);
        }
      });

      test('all fragments carry the same messageId and contentType', () {
        final payload = Uint8List(1000);
        final id = uuid.v4();
        final frames = handler.framesFor(
          payload: payload,
          messageId: id,
          contentType: ContentType.message,
        );

        for (final frame in frames) {
          expect(frame.messageId, equals(id));
          expect(frame.contentType, equals(ContentType.message));
          expect(frame.fragCount, equals(frames.length));
        }
      });

      test('honors the requested contentType', () {
        // A large signaling payload still fragments, tagged as signaling.
        final payload = Uint8List(1000);
        final frames = handler.framesFor(
          payload: payload,
          messageId: uuid.v4(),
          contentType: ContentType.signaling,
        );

        for (final frame in frames) {
          expect(frame.contentType, equals(ContentType.signaling));
        }
      });

      test('distinct caller message IDs produce distinct frame streams', () {
        final payload = Uint8List(1000);
        final id1 = uuid.v4();
        final id2 = uuid.v4();
        final frames1 = handler.framesFor(payload: payload, messageId: id1);
        final frames2 = handler.framesFor(payload: payload, messageId: id2);

        expect(id1, isNot(equals(id2)));
        expect(frames1.first.messageId, isNot(equals(frames2.first.messageId)));
      });
    });

    group('accept - reassembly', () {
      test('returns chunk immediately for a single-fragment frame', () {
        final payload = Uint8List(100);
        for (var i = 0; i < payload.length; i++) {
          payload[i] = i % 256;
        }
        final frames =
            handler.framesFor(payload: payload, messageId: uuid.v4());

        final result = handler.accept(frames.single);
        expect(result, isNotNull);
        expect(result, equals(payload));
      });

      test('reassembles complete message from in-order fragments', () {
        final payload = Uint8List(1000);
        for (var i = 0; i < payload.length; i++) {
          payload[i] = i % 256;
        }

        final frames =
            handler.framesFor(payload: payload, messageId: uuid.v4());

        // Feed fragments to a separate handler (simulating the receiver)
        final receiver = FragmentHandler();
        addTearDown(receiver.dispose);

        Uint8List? result;
        for (final frame in frames) {
          result = receiver.accept(frame);
        }

        expect(result, isNotNull);
        expect(result, equals(payload));
      });

      test('reassembles complete message from out-of-order fragments', () {
        final payload = Uint8List(1500);
        for (var i = 0; i < payload.length; i++) {
          payload[i] = i % 256;
        }

        final frames =
            handler.framesFor(payload: payload, messageId: uuid.v4());

        final receiver = FragmentHandler();
        addTearDown(receiver.dispose);

        // Send first fragment
        expect(receiver.accept(frames.first), isNull);

        final lastFragment = frames.last;

        // Send middle fragments before the last one
        for (var i = 1; i < frames.length - 1; i++) {
          final result = receiver.accept(frames[i]);
          expect(result, isNull);
        }

        // Send last fragment - should trigger reassembly
        final result = receiver.accept(lastFragment);
        expect(result, isNotNull);
        expect(result, equals(payload));
      });

      test('handles duplicate fragments idempotently', () {
        final payload = Uint8List(1000);
        for (var i = 0; i < payload.length; i++) {
          payload[i] = i % 256;
        }

        final frames =
            handler.framesFor(payload: payload, messageId: uuid.v4());

        final receiver = FragmentHandler();
        addTearDown(receiver.dispose);

        // Send first fragment twice
        receiver.accept(frames.first);
        receiver.accept(frames.first);

        // Send remaining fragments
        Uint8List? result;
        for (var i = 1; i < frames.length; i++) {
          result = receiver.accept(frames[i]);
        }

        expect(result, isNotNull);
        expect(result, equals(payload));
      });

      test('returns null for incomplete fragments', () {
        final payload = Uint8List(1000);
        final frames =
            handler.framesFor(payload: payload, messageId: uuid.v4());

        final receiver = FragmentHandler();
        addTearDown(receiver.dispose);

        // Only send first fragment
        final result = receiver.accept(frames.first);
        expect(result, isNull);
      });

      test('returns null for a middle fragment received first', () {
        final payload = Uint8List(1500);
        final frames =
            handler.framesFor(payload: payload, messageId: uuid.v4());

        final receiver = FragmentHandler();
        addTearDown(receiver.dispose);

        // Send a middle fragment before any other - still incomplete
        expect(frames.length, greaterThan(2));
        final result = receiver.accept(frames[1]);
        expect(result, isNull);
      });

      test('returns null for the final fragment received first', () {
        final payload = Uint8List(1000);
        final frames =
            handler.framesFor(payload: payload, messageId: uuid.v4());

        final receiver = FragmentHandler();
        addTearDown(receiver.dispose);

        // Only send last fragment (rest outstanding)
        final result = receiver.accept(frames.last);
        expect(result, isNull);
      });
    });

    group('round-trip', () {
      test('fragment and reassemble preserves payload exactly', () {
        // Test with various payload sizes above threshold
        for (final size in [501, 900, 1000, 2000, 5000]) {
          final payload = Uint8List(size);
          for (var i = 0; i < size; i++) {
            payload[i] = i % 256;
          }

          final frames =
              handler.framesFor(payload: payload, messageId: uuid.v4());

          final receiver = FragmentHandler();
          Uint8List? result;
          for (final frame in frames) {
            result = receiver.accept(frame);
          }
          receiver.dispose();

          expect(result, isNotNull, reason: 'Failed for size=$size');
          expect(result!.length, equals(size),
              reason: 'Length mismatch for size=$size');
          expect(result, equals(payload),
              reason: 'Content mismatch for size=$size');
        }
      });

      test('single-fragment payload round-trips via encode/decode', () {
        // A payload that need not fragment still survives the SecureFrame
        // wire encoding untouched.
        for (final size in [1, 100, FragmentHandler.fragmentThreshold]) {
          final payload = Uint8List(size);
          for (var i = 0; i < size; i++) {
            payload[i] = i % 256;
          }
          final frame = handler
              .framesFor(payload: payload, messageId: uuid.v4())
              .single;

          final decoded = SecureFrame.decode(frame.encode());
          expect(decoded.isFragmented, isFalse, reason: 'size=$size');

          final receiver = FragmentHandler();
          final result = receiver.accept(decoded);
          receiver.dispose();

          expect(result, equals(payload), reason: 'size=$size');
        }
      });

      test('multiple concurrent reassemblies', () {
        final receiver = FragmentHandler();
        addTearDown(receiver.dispose);

        // Fragment two different messages
        final payload1 = Uint8List(1000);
        for (var i = 0; i < 1000; i++) {
          payload1[i] = i % 256;
        }

        final payload2 = Uint8List(1200);
        for (var i = 0; i < 1200; i++) {
          payload2[i] = (i * 7) % 256;
        }

        final frames1 =
            handler.framesFor(payload: payload1, messageId: uuid.v4());
        final frames2 =
            handler.framesFor(payload: payload2, messageId: uuid.v4());

        // Interleave fragments across the two logical messages.
        receiver.accept(frames1[0]);
        receiver.accept(frames2[0]);

        // Send middle fragments of both
        for (var i = 1; i < frames1.length - 1; i++) {
          receiver.accept(frames1[i]);
        }
        for (var i = 1; i < frames2.length - 1; i++) {
          receiver.accept(frames2[i]);
        }

        // Final fragments
        final result1 = receiver.accept(frames1.last);
        final result2 = receiver.accept(frames2.last);

        expect(result1, equals(payload1));
        expect(result2, equals(payload2));
      });
    });

    group('dispose', () {
      test('cleans up without errors', () {
        final h = FragmentHandler();
        // Populate internal reassembly state with an outstanding fragment.
        final payload = Uint8List(1000);
        final frames = h.framesFor(payload: payload, messageId: uuid.v4());
        h.accept(frames.first);
        expect(() => h.dispose(), returnsNormally);
      });

      test('double dispose is safe', () {
        final h = FragmentHandler();
        h.dispose();
        expect(() => h.dispose(), returnsNormally);
      });
    });
  });
}
