import 'dart:typed_data';

/// Golomb-coded set over packetIds — the compact "here is what I already
/// hold" advertisement the sync exchange puts on the air.
///
/// An explicit id list does not scale here. A packetId is a 16-byte UUID, so
/// a list costs 16 bytes each and fits 8 per sealed BLE write: advertising a
/// buffer of tens of thousands of packets costs thousands of packets of pure
/// overhead, carrying no payload at all. A GCS costs about `p + 2` bits per
/// element, so the same buffer fits in a few hundred bytes.
///
/// The cost is a false positive: the peer concludes we already hold a packet
/// we do not, and withholds it. That is bounded by [fprOneIn] and costs ONE
/// ROUND, because every round hashes under its own salt — see [_hash].
///
/// Membership alone cannot buy that. A sweep frame covers a historical
/// window, and a window that has passed does not gain ids, so an unsalted
/// filter over it is rebuilt byte for byte every time the cursor wraps and
/// withholds the SAME packet on every pass — a packet permanently invisible
/// to that peer rather than one delayed a cycle. The salt is what makes each
/// round an independent draw. It does not lower the rate: [fprOneIn] is
/// structural, n ids over `n * 2^p` slots, and no entropy in the hash input
/// moves it. It decides WHICH packet pays, freshly, each round.
///
/// Encoding (BIP-158 shaped, deliberately: it is the best-tested GCS wire
/// format there is):
///   * each id is hashed under the round's salt to a value in `[0, n * 2^p)`,
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

  /// What one sealed sync frame leaves for the filter: the floor-MTU write of
  /// 244 bytes, less the sealed packet's own 106 and the frame header's 19.
  /// It is exactly the budget and not a byte under, so a change to any of the
  /// three moves this one; `sync_on_connect_test` asserts the sum fits.
  ///
  /// A filter that does not fit is not a smaller filter, it is a truncated
  /// one: these are unacknowledged writes, so the stack cannot promote them
  /// to a GATT long write. It cuts at MTU − 3 and the peer gets an
  /// unparseable prefix.
  static const int maxPayloadBytes = 119;

  /// How many ids [maxPayloadBytes] holds, at `p + 2` bits each. A buffer
  /// larger than this advertises a SUBSET per round — the rest ride the next
  /// announce cycle rather than being silently dropped.
  static int get maxElements => maxElementsFor(maxPayloadBytes);

  /// How many ids [payloadBytes] holds, at `p + 2` bits each.
  ///
  /// The budget is a property of the LEG the frame will be written to, not of
  /// this class: legs negotiate their MTUs separately and one that settles
  /// below the floor cannot carry a filter built for the floor. Sizing to the
  /// leg keeps the whole round on the leg it was meant for; the alternative
  /// is a frame that is refused and has to be rescued by the pair's other leg,
  /// or dropped when there is no other leg to rescue it.
  static int maxElementsFor(int payloadBytes) =>
      payloadBytes <= 0 ? 0 : (payloadBytes * 8) ~/ (p + 2);

  /// Map a packetId to its filter value in `[0, m)` under [salt]: FNV-1a from
  /// a salted basis, then a finalizing mix. Both sides must agree exactly, so
  /// the hash is written out here rather than taken from a platform library
  /// whose implementation could differ across Dart versions or platforms.
  ///
  /// The salt enters the BASIS, ahead of the compression loop. Anything
  /// applied to a finished hash maps equal values to equal values, so it
  /// carries every collision through unchanged — a salt that arrives after
  /// the loop reorders the slots and reproduces the same pairs inside them.
  ///
  /// The finalizer is a mix, and it is what makes the salt reach the bits the
  /// modulus reads. The basis is XORed with the salt and then immediately
  /// with the id's first byte, so the salt enters as one byte at one
  /// position, and FNV diffuses upward from there — leaving the low bits,
  /// which are exactly the ones the modulus takes, close to linear in it.
  ///
  /// From a salted basis alone the damage is concentrated in the salt's TOP
  /// bit. Against a chance of 1/128 = 0.78%, a salt step of 128 recurs at
  /// 51% — 65 times chance, half of every collision surviving the change.
  /// Other steps sit between about 0.9 and 2 times chance. Two sightings of
  /// one packet are a sweep-wrap apart, so the step between them is
  /// arbitrary and lands on that bit as readily as any other, which puts the
  /// structure squarely on the case the two-vote retirement rule prices at
  /// 1/128 squared. With the mix every output bit depends on every input bit
  /// and every step sits on chance.
  static int _hash(String packetId, int m, int salt) {
    var h = 0xcbf29ce484222325 ^ salt;
    for (final unit in packetId.codeUnits) {
      h ^= unit;
      // 64-bit FNV prime, kept inside Dart's signed 64-bit int by masking.
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    h ^= h >>> 33;
    h = (h * 0xff51afd7ed558ccd) & 0xFFFFFFFFFFFFFFFF;
    h ^= h >>> 33;
    h = (h * 0xc4ceb9fe1a85ec53) & 0xFFFFFFFFFFFFFFFF;
    h ^= h >>> 33;
    // Modulo bias is irrelevant here: the filter's job is a uniform-ish
    // spread, not a uniform distribution.
    return (h % m).abs();
  }

  /// Build a filter over [ids] under [salt]. Returns the encoded payload; [n]
  /// (the element count the reader needs to reconstruct the modulus) and the
  /// salt both ride the frame, since a reader cannot derive either.
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
  static ({Uint8List data, int n}) build(List<String> ids,
      {required int salt, int? maxPayloadBytes}) {
    final cap = maxElementsFor(maxPayloadBytes ?? GcsFilter.maxPayloadBytes);
    final take = ids.length > cap ? ids.sublist(0, cap) : ids;
    final n = take.length;
    if (n == 0) return (data: Uint8List(0), n: 0);
    final m = n << p;
    final values = [for (final id in take) _hash(id, m, salt)]..sort();

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
  ///
  /// [salt] must be the one the frame carried. A lookup under any other salt
  /// is not a weaker answer, it is an unrelated one: the salt reshuffles the
  /// whole slot assignment, so every id reads as absent and the holder
  /// answers a converged peer with its entire window.
  static bool mightContain(List<int> values, int n, String packetId,
      {required int salt}) {
    if (n == 0 || values.isEmpty) return false;
    final target = _hash(packetId, n << p, salt);
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
