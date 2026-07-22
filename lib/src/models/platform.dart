/// Peer OS platform, exchanged as a required 1-byte field in the signed
/// ANNOUNCE payload and stored pubkey-keyed on `PeerState`.
///
/// Load-bearing for BLE dual-role leg ordering: the one hardware-measured
/// constraint (an iOS central cannot open the SECOND link toward a non-iOS
/// peer) keys off the peer's platform. Carrying it inside the signed ANNOUNCE
/// makes platform knowledge rotation-stable (survives MAC/slot rotation) and
/// backgrounding-stable (unlike the `grs-ios` advertisement marker, which
/// disappears while the iOS app is backgrounded).
enum PeerPlatform {
  /// Android or any other non-iOS platform. Wire byte 0.
  other,

  /// iOS. Wire byte 1.
  ios;

  /// The byte this platform encodes to in the ANNOUNCE payload.
  int get wireByte => this == PeerPlatform.ios ? 1 : 0;

  /// Decode an ANNOUNCE platform byte. Any value other than 0/1 is malformed
  /// — there is no old version in the wild to be tolerant of.
  static PeerPlatform fromWireByte(int byte) {
    switch (byte) {
      case 0:
        return PeerPlatform.other;
      case 1:
        return PeerPlatform.ios;
      default:
        throw FormatException('Unknown ANNOUNCE platform byte: $byte');
    }
  }
}
