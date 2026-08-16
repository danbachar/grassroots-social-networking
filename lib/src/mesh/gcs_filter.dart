import 'dart:typed_data';

/// Golomb-coded set over packetIds — the compact "here is what I already
/// hold" advertisement the sync exchange puts on the air.
///
/// It replaces an explicit id list. A packetId is a 16-byte UUID, so a list
/// cost 16 bytes each and fit 8 per sealed BLE write; advertising a buffer of
/// 17,116 packets (measured peak, scf-rearm-4) cost ~2,140 packets, and the
/// offer traffic was 46-51% of all sealed air across two runs while carrying
/// no payload at all. A GCS costs about `p + 2` bits per element, so the same
/// buffer fits in a few hundred bytes.
///
/// The cost is a false positive: the peer concludes we already hold a packet
/// we do not, and withholds it. That is bounded by [fprOneIn] and self-heals —
/// the next announce cycle builds a fresh filter, and a different membership
/// draw is not correlated with the last, so a packet cannot be permanently
/// invisible to a peer. It is the same class of miss the seen-set bloom
/// already makes on the request side.
///
/// Encoding (BIP-158 shaped, deliberately: it is the best-tested GCS wire
/// format there is):
///   * each id is hashed to a value in `[0, n * 2^p)`,
///   * the values are sorted and delta-encoded,
///   * each delta is Golomb-Rice coded — unary quotient, then `p` raw bits.
/// Deltas are geometrically distributed, which is exactly what Golomb-Rice is
/// optimal for; that is where the compression comes from.
class GcsFilter {
  /// Golomb-Rice parameter. False positive rate is `2^-p`, so 7 gives 1 in
  /// 128 (0.78%) at about 9 bits per element. Bitchat targets 1% for the same
  /// job; the nearest power of two is chosen here so the modulus is a shift.
  static const int p = 7;

  /// The false-positive rate as a denominator, for documentation and tests.
  static const int fprOneIn = 1 << p;

  /// A sealed sync frame must fit one BLE write, and the filter shares that
  /// budget with the frame header. Kept well inside it: a filter that does not
  /// fit is not a smaller filter, it is a truncated one.
  static const int maxPayloadBytes = 120;

  /// How many ids [maxPayloadBytes] holds, at `p + 2` bits each. A buffer
  /// larger than this advertises a SUBSET per round — the rest ride the next
  /// announce cycle rather than being silently dropped.
  static int get maxElements => (maxPayloadBytes * 8) ~/ (p + 2);

  /// Map a packetId to its filter value in `[0, m)`. FNV-1a over the id's
  /// bytes: both sides must agree exactly, so the hash is written out here
  /// rather than taken from a platform library whose implementation could
  /// differ across Dart versions or platforms.
  static int _hash(String packetId, int m) {
    var h = 0xcbf29ce484222325;
    for (final unit in packetId.codeUnits) {
      h ^= unit;
      // 64-bit FNV prime, kept inside Dart's signed 64-bit int by masking.
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    // Modulo bias is irrelevant here: the filter's job is a uniform-ish
    // spread, not a uniform distribution.
    return (h % m).abs();
  }

  /// Build a filter over [ids]. Returns the encoded payload; [n] (the element
  /// count the reader needs to reconstruct the modulus) rides the frame.
  ///
  /// Takes at most [maxElements] from the FRONT of what it is given. The
  /// caller passes one window of its buffer, oldest first, and carries that
  /// window's bounds beside the filter; the responder considers only packets
  /// inside those bounds, so anything outside is not re-sent — the scope, not
  /// the filter, is what suppresses duplicates.
  ///
  /// Oldest first, and the caller advances the window each round, because the
  /// alternative starves the case store-carry-forward exists for. A window
  /// pinned to the recent tail never reconciles anything older than its lower
  /// bound, and the packets below that bound are precisely the ones that have
  /// been waiting longest — a traveller's backlog would sit unreconciled
  /// until it aged out. Sweeping forward from the oldest covers the whole
  /// buffer over successive rounds and serves the longest waiters first.
  static ({Uint8List data, int n}) build(List<String> ids) {
    final take = ids.length > maxElements ? ids.sublist(0, maxElements) : ids;
    final n = take.length;
    if (n == 0) return (data: Uint8List(0), n: 0);
    final m = n << p;
    final values = [for (final id in take) _hash(id, m)]..sort();

    final out = _BitWriter();
    var last = 0;
    for (final v in values) {
      final delta = v - last;
      last = v;
      final quotient = delta >> p;
      for (var i = 0; i < quotient; i++) {
        out.writeBit(1);
      }
      out.writeBit(0);
      out.writeBits(delta & ((1 << p) - 1), p);
    }
    return (data: out.toBytes(), n: n);
  }

  /// Decode a filter to its sorted value set. Throws [FormatException] on a
  /// payload that runs out mid-symbol — a truncated filter is malformed, not
  /// a smaller one (clean-break rule: no tolerant decoding).
  static List<int> decode({required Uint8List data, required int n}) {
    if (n == 0) return const [];
    final reader = _BitReader(data);
    final values = <int>[];
    var last = 0;
    for (var i = 0; i < n; i++) {
      var quotient = 0;
      while (reader.readBit() == 1) {
        quotient++;
        if (quotient > 1 << 20) {
          throw const FormatException('GCS quotient runaway — corrupt filter');
        }
      }
      final remainder = reader.readBits(p);
      last += (quotient << p) + remainder;
      values.add(last);
    }
    return values;
  }

  /// Whether [packetId] is (probably) in the decoded [values]. False means
  /// DEFINITELY absent — which is the direction that matters: the peer sends
  /// us exactly the packets it can prove we lack.
  static bool mightContain(List<int> values, int n, String packetId) {
    if (n == 0 || values.isEmpty) return false;
    final target = _hash(packetId, n << p);
    var lo = 0, hi = values.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final v = values[mid];
      if (v == target) return true;
      if (v < target) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return false;
  }
}

class _BitWriter {
  final _bytes = <int>[];
  int _cur = 0;
  int _used = 0;

  void writeBit(int bit) {
    _cur = (_cur << 1) | (bit & 1);
    _used++;
    if (_used == 8) {
      _bytes.add(_cur);
      _cur = 0;
      _used = 0;
    }
  }

  void writeBits(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      writeBit((value >> i) & 1);
    }
  }

  Uint8List toBytes() {
    if (_used > 0) {
      // Pad the final byte with zeros. A reader is bounded by the element
      // count, never by the payload length, so padding is never mistaken for
      // another symbol.
      return Uint8List.fromList([..._bytes, _cur << (8 - _used)]);
    }
    return Uint8List.fromList(_bytes);
  }
}

class _BitReader {
  _BitReader(this._data);
  final Uint8List _data;
  int _pos = 0;

  int readBit() {
    final byte = _pos >> 3;
    if (byte >= _data.length) {
      throw const FormatException('GCS payload exhausted mid-symbol');
    }
    final bit = (_data[byte] >> (7 - (_pos & 7))) & 1;
    _pos++;
    return bit;
  }

  int readBits(int count) {
    var v = 0;
    for (var i = 0; i < count; i++) {
      v = (v << 1) | readBit();
    }
    return v;
  }
}
