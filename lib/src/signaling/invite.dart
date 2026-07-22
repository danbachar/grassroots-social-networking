import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart';

/// One introducer named in an [Invite]: a well-connected friend of the
/// inviter who has volunteered to coordinate a first-contact hole-punch for
/// invitees. The invitee reaches the introducer at one of [addresses].
class InviteIntroducer {
  /// The introducer's 32-byte Ed25519 public key.
  final Uint8List pubkey;

  /// "ip:port" address candidates where the introducer can be reached.
  final List<String> addresses;

  const InviteIntroducer({required this.pubkey, required this.addresses});

  String get pubkeyHex =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// A signed cold-bootstrap capability issued by an inviter.
///
/// Grassroots is infrastructure-free: there is no always-on server two
/// strangers can rendezvous at. An invite is how a peer bootstraps first
/// contact with someone it has never met — it names one or more
/// **introducers** (the inviter's well-connected, willing friends) who will
/// coordinate the invitee↔inviter hole-punch. The whole thing is signed by
/// the inviter, so it is a bearer capability bounded by [expiry], [maxUses],
/// and the single-use [nonce]:
///
///  - An introducer coordinates a punch toward the inviter only for a peer
///    presenting a valid invite the inviter (its own friend) signed — so an
///    `open` introducer helps redeem *genuine* invites, never becoming an
///    open punch relay toward its friends.
///  - The inviter accepts the invitee's first contact — even under a closed
///    posture — because it verifies its own signature over the invite and
///    that the nonce is unused, then burns the nonce.
///
/// See `docs/rv-removal-and-invite-links.md` §Cold bootstrap via invite links.
class Invite {
  /// Wire format version.
  static const int version = 1;

  /// Length of the random single-use nonce, in bytes.
  static const int nonceLength = 16;

  /// The inviter's 32-byte Ed25519 public key (verifies [signature]).
  final Uint8List inviter;

  /// The introducers who can coordinate the punch, in redundancy order.
  final List<InviteIntroducer> introducers;

  /// Unix seconds after which the invite is void.
  final int expiry;

  /// Random single-use-per-slot nonce; the inviter burns it on redemption.
  final Uint8List nonce;

  /// How many times this invite may be redeemed before the inviter refuses.
  final int maxUses;

  /// Ed25519 signature by [inviter] over [canonicalBody].
  final Uint8List signature;

  const Invite({
    required this.inviter,
    required this.introducers,
    required this.expiry,
    required this.nonce,
    required this.maxUses,
    required this.signature,
  });

  String get inviterHex =>
      inviter.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String get nonceHex =>
      nonce.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  bool isExpiredAt(DateTime now) =>
      now.millisecondsSinceEpoch ~/ 1000 >= expiry;

  /// The signed body: everything except the trailing signature.
  ///
  /// ```
  /// version(1) + inviter(32) + expiry u64 BE(8) + nonce(16)
  ///   + maxUses u16 BE(2) + introducerCount(1)
  ///   + repeated introducer:
  ///       pubkey(32) + addrCount(1)
  ///       + repeated(addrLen u16 BE(2) + addrBytes)
  /// ```
  static Uint8List canonicalBody({
    required Uint8List inviter,
    required List<InviteIntroducer> introducers,
    required int expiry,
    required Uint8List nonce,
    required int maxUses,
  }) {
    if (inviter.length != 32) {
      throw ArgumentError('Invite inviter must be 32 bytes');
    }
    if (nonce.length != nonceLength) {
      throw ArgumentError('Invite nonce must be $nonceLength bytes');
    }
    final buffer = BytesBuilder();
    buffer.addByte(version);
    buffer.add(inviter);
    buffer.add(_u64be(expiry));
    buffer.add(nonce);
    buffer.add(_u16be(maxUses));
    buffer.addByte(introducers.length);
    for (final intro in introducers) {
      if (intro.pubkey.length != 32) {
        throw ArgumentError('Introducer pubkey must be 32 bytes');
      }
      buffer.add(intro.pubkey);
      buffer.addByte(intro.addresses.length);
      for (final addr in intro.addresses) {
        final bytes = Uint8List.fromList(utf8.encode(addr));
        buffer.add(_u16be(bytes.length));
        buffer.add(bytes);
      }
    }
    return buffer.toBytes();
  }

  Uint8List get _body => canonicalBody(
        inviter: inviter,
        introducers: introducers,
        expiry: expiry,
        nonce: nonce,
        maxUses: maxUses,
      );

  /// The full signed blob: `body || signature(64)`.
  Uint8List encode() => Uint8List.fromList([..._body, ...signature]);

  /// The shareable `grassroots://invite?d=<base64url>` link.
  String toLink() {
    final d = base64Url.encode(encode());
    return 'grassroots://invite?d=$d';
  }

  /// Decode a signed blob and verify the inviter's signature.
  ///
  /// Throws [FormatException] on malformed bytes or a bad signature — there
  /// is no tolerant path.
  static Invite decode(Uint8List data, Sodium sodium) {
    if (data.length < 1 + 32 + 8 + nonceLength + 2 + 1 + 64) {
      throw const FormatException('Invite too short');
    }
    final body = Uint8List.sublistView(data, 0, data.length - 64);
    final signature = Uint8List.fromList(
      Uint8List.sublistView(data, data.length - 64),
    );

    var offset = 0;
    final ver = body[offset];
    offset += 1;
    if (ver != version) {
      throw FormatException('Unsupported invite version: $ver');
    }
    final inviter = Uint8List.fromList(body.sublist(offset, offset + 32));
    offset += 32;
    final expiry = _readU64be(body, offset);
    offset += 8;
    final nonce = Uint8List.fromList(body.sublist(offset, offset + nonceLength));
    offset += nonceLength;
    final maxUses = _readU16be(body, offset);
    offset += 2;
    final introducerCount = body[offset];
    offset += 1;

    final introducers = <InviteIntroducer>[];
    for (var i = 0; i < introducerCount; i++) {
      if (offset + 33 > body.length) {
        throw const FormatException('Invite introducer truncated');
      }
      final pubkey = Uint8List.fromList(body.sublist(offset, offset + 32));
      offset += 32;
      final addrCount = body[offset];
      offset += 1;
      final addresses = <String>[];
      for (var j = 0; j < addrCount; j++) {
        if (offset + 2 > body.length) {
          throw const FormatException('Invite address length missing');
        }
        final len = _readU16be(body, offset);
        offset += 2;
        if (offset + len > body.length) {
          throw const FormatException('Invite address truncated');
        }
        addresses.add(utf8.decode(body.sublist(offset, offset + len)));
        offset += len;
      }
      introducers.add(InviteIntroducer(pubkey: pubkey, addresses: addresses));
    }

    final ok = sodium.crypto.sign.verifyDetached(
      signature: signature,
      message: body,
      publicKey: inviter,
    );
    if (!ok) {
      throw const FormatException('Invite signature invalid');
    }

    return Invite(
      inviter: inviter,
      introducers: introducers,
      expiry: expiry,
      nonce: nonce,
      maxUses: maxUses,
      signature: signature,
    );
  }

  /// Parse a `grassroots://invite?d=...` link.
  static Invite parseLink(String link, Sodium sodium) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme != 'grassroots' || uri.host != 'invite') {
      throw const FormatException('Not a grassroots invite link');
    }
    final d = uri.queryParameters['d'];
    if (d == null || d.isEmpty) {
      throw const FormatException('Invite link missing payload');
    }
    final Uint8List bytes;
    try {
      bytes = base64Url.decode(base64Url.normalize(d));
    } catch (_) {
      throw const FormatException('Invite link payload is not valid base64url');
    }
    return decode(bytes, sodium);
  }

  static Uint8List _u16be(int v) => Uint8List.fromList([
        (v >> 8) & 0xff,
        v & 0xff,
      ]);

  static Uint8List _u64be(int v) => Uint8List.fromList([
        for (var i = 7; i >= 0; i--) (v >> (8 * i)) & 0xff,
      ]);

  static int _readU16be(Uint8List d, int o) => (d[o] << 8) | d[o + 1];

  static int _readU64be(Uint8List d, int o) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | d[o + i];
    }
    return v;
  }
}

/// Outcome of [GrassrootsNetwork.redeemInvite].
class InviteRedeemResult {
  /// Whether a path to the inviter was established.
  final bool ok;

  /// The inviter's public key on success, else null.
  final Uint8List? inviter;

  /// A human-readable reason on failure, else null.
  final String? error;

  const InviteRedeemResult._(this.ok, this.inviter, this.error);

  factory InviteRedeemResult.success(Uint8List inviter) =>
      InviteRedeemResult._(true, inviter, null);

  factory InviteRedeemResult.failure(String error) =>
      InviteRedeemResult._(false, null, error);
}

/// Signs [Invite]s with an inviter's Ed25519 key. The private key stays here;
/// callers pass their identity's 64-byte secret.
class InviteSigner {
  final Sodium _sodium;

  const InviteSigner(this._sodium);

  /// Build and sign an invite. [privateKey] is the inviter's 64-byte Ed25519
  /// secret (seed || pubkey); [inviter] is the matching 32-byte public key.
  Invite sign({
    required Uint8List inviter,
    required Uint8List privateKey,
    required List<InviteIntroducer> introducers,
    required int expiry,
    required Uint8List nonce,
    required int maxUses,
  }) {
    final body = Invite.canonicalBody(
      inviter: inviter,
      introducers: introducers,
      expiry: expiry,
      nonce: nonce,
      maxUses: maxUses,
    );
    final secretKey = SecureKey.fromList(_sodium, privateKey);
    try {
      final signature = _sodium.crypto.sign.detached(
        message: body,
        secretKey: secretKey,
      );
      return Invite(
        inviter: inviter,
        introducers: introducers,
        expiry: expiry,
        nonce: nonce,
        maxUses: maxUses,
        signature: signature,
      );
    } finally {
      secretKey.dispose();
    }
  }
}
