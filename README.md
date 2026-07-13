# Grassroots Networking

A peer-to-peer messaging **transport** for mobile devices, written in Flutter/Dart. It moves end-to-end-encrypted packets between phones over two independent paths — **Bluetooth Low Energy** (an opportunistic multi-hop mesh, no infrastructure required) and the **Internet** (direct UDP with NAT hole-punching) — behind one connect/send/receive interface. It is not an application; it is the plumbing that applications like GSG build on top of. A demo chat app is included for development and field testing.

## Core ideas

**Identity is a key pair.** Every device holds an Ed25519 key pair; the public key *is* the peer's identity. Nicknames are cosmetic. All trust decisions flow from cryptographic verification, and message content only ever exists in the clear on the two endpoints.

**Two transports, one interface.** BLE covers nearby peers without Internet; UDP covers the globe. Both surface the same abstraction to the coordinator, and each can be toggled independently. Losing one transport has zero effect on the other — a peer stays reachable as long as any transport is live.

**Opportunistic BLE mesh.** Over Bluetooth, delivery is multi-hop *managed flooding*: every node relays packets toward the recipient, TTL-bounded and deduplicated by a Bloom filter. Nodes also *store-carry-forward*: a bounded, age-expiring DTN cache holds packets for recipients currently out of range and re-floods them when the recipient reappears. Relays are open (not friend-gated) but blind — the outer envelope carries only the recipient ID; the sender's identity and the message body are sealed inside a Noise session that only the recipient can open. There is no cleartext sender and no per-packet signature on the wire: authentication is end-to-end, inside Noise, and the recipient demultiplexes inbound packets by trial decryption.

**Direct Internet transport with friend-assisted hole-punching.** UDP (via [UDX](https://pub.dev/packages/grassroots_dart_udx)) stays strictly point-to-point — no content relays. Since most phones sit behind NAT, *well-connected* friends (devices with a globally routable address) act as signaling relays: they hand both NAT'd peers each other's observed address and coordinate a punch, after which the deterministic initiator (lexicographically smaller public key) opens the stream and the friend leaves the path. Signaling is friend-only; content never touches the relay.

**Dual-role BLE.** Every BLE pair converges to two GATT legs, each device central on one and peripheral on the other. Platform asymmetries (notably iOS↔Android link ordering) are solved by choosing who initiates each leg, never by settling for a single link.

**Redux state.** All peer and transport state lives in an immutable Redux store (`AppState`) — a strict projection of facts emitted by the transport layers, never an inference. UI subscribes to the store; no mutable singletons.

See [CLAUDE.md](CLAUDE.md) for the full set of design rules and invariants, and [docs/](docs/) for the protocol specification and design notes.

## Repository layout

```
lib/
  main.dart, chat_screen.dart, ...   Demo chat app (UI reads the Redux store)
  src/
    grassroots_network.dart          Coordinator: transports, sessions, reachability
    transport/                       BLE + UDP transport services, hole punching,
                                     public-address discovery
    mesh/                            Bloom-filter dedup, DTN store-carry-forward cache
    session/                         Noise session management (end-to-end encryption)
    signaling/                       Friend-assisted address exchange & punch coordination
    routing/                         Packet routing between transports and the app
    protocol/, proto/                Wire formats
    store/                           Redux state, actions, reducers
    trace/                           Opt-in diagnostic traces (contacts, density, battery,
                                     coarse location) for field experiments
docs/                                Protocol spec (GLP Networking API), design documents
test/                                Unit and integration tests
trace_server/                        Self-hosted trace-upload server (Python + Caddy)
tools/                               Debugging utilities
```

The BLE plumbing itself (dual-role GATT, advertising, scanning) lives in a separate plugin, [grassroots-bluetooth-layer](https://github.com/danbachar/grassroots-bluetooth-layer), pulled in as a git dependency.

## Getting started

Prerequisites:

- Flutter ≥ 3.10, Dart ≥ 3.0
- Git SSH access to [grassroots-bluetooth-layer](https://github.com/danbachar/grassroots-bluetooth-layer) (git dependency in `pubspec.yaml`)
- A **physical device** for anything involving BLE — emulators and simulators have no usable BLE stack. The UDP transport works anywhere.

```bash
flutter pub get
flutter run            # debug build on a connected device
```

On first launch the app generates an Ed25519 identity, stores it in platform secure storage, and starts advertising/scanning (BLE) and binding sockets (UDP). Two devices running the app near each other discover and connect automatically, subject to the trust setting (open cold-call vs. closed/friends-only).

### Tests

```bash
flutter test
```

Transport logic (BLE pair arbitration, UDP hole-punching, mesh relay, reducers) is covered by unit tests with a fake BLE host; `test/integration/` exercises multi-node scenarios.

## Release builds (Android APK)

Release signing is read from `android/key.properties` — copy [android/key.properties.example](android/key.properties.example), generate a keystore once with the `keytool` command in its comments, and fill in your values. Without the file, release builds fall back to the debug key (fine for `flutter run --release`, not for distribution).

```bash
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
```

To enable diagnostic-trace uploads in a build, inject the (secret) upload token
at build time — it is deliberately not committed to source:

```bash
flutter build apk --release --dart-define=TRACE_TOKEN=<token>
```

Without the define, trace uploads stay inert (see [trace_config.dart](lib/src/trace/trace_config.dart)).

Host the APK on any HTTPS server and install it by opening the URL on the phone (Android will ask to allow installs from the browser). Updates install over the top as long as the signing key and `applicationId` stay the same — keep the keystore safe and backed up. Bump `version:` in `pubspec.yaml` for each release; Android refuses downgrades.

## Diagnostic traces

For field experiments the app can record opt-in traces — contact events, peer density, buffer/battery state, coarse background location — and upload them to a self-hosted collector. See [trace_server/README.md](trace_server/README.md) for deployment and [trace_server/schema.md](trace_server/schema.md) for the record schema.

## License

[MIT](LICENSE)
