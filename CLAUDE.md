# Claude Instructions for Grassroots Networking

## Working Style
Always be precise, critical, and helpful. Prefer to ask rather than assume if you have unclarities.

## Project Philosophy

Grassroots Networking is a **peer-to-peer messaging transport** — a thin layer that moves packets between devices over Bluetooth (BLE) and the Internet (UDP). It is not an application; it is the plumbing that applications like GSG build on top of.

**Core principles:**

- **Opportunistic mesh delivery (BLE).** Over Bluetooth, messages reach the recipient by multi-hop **managed flooding**: every node relays packets toward the recipient — TTL-bounded and deduplicated — and nodes **store-carry-forward**, caching packets for recipients that are currently out of range and re-delivering when they reappear. This lets a user message a friend (or continue an existing chat) even when that friend is not a direct BLE neighbor. The Internet (UDP) transport stays **direct** point-to-point. Either way the message *content* only ever exists in the clear on the two endpoints — relays forward sealed bytes addressed by recipient ID (see Mesh Envelope & Trust).
- **Identity is a key pair.** Every device holds an Ed25519 key pair. The public key *is* the peer's identity — nicknames are cosmetic. All trust decisions flow from cryptographic verification.
- **Two transports, one interface.** BLE covers nearby peers without Internet; UDP covers the globe. Both transports surface the same abstraction to the coordinator: connect, send, receive, disconnect. BLE is preferred when both are available.
- **Clean breaks, not compatibility shims.** When refactoring, fully replace old code. No legacy wrappers, no "kept for compatibility" comments, no dead code. Update every call site. There are no installed apps in the wild — you are free to rename, restructure, and break wire formats whenever it improves the design.

## No Legacy or Compatibility Code

When refactoring, DO NOT keep old code "for legacy" or "for compatibility". Fully replace old implementations, remove unused imports and dead code, and update all call sites. Use the Redux store (`AppState`) exclusively for shared state — no mutable singletons.

This applies to **wire-format decoders too**: when you add a field to a packet, do not write the decoder to "gracefully handle truncated/old payloads where the field is missing." There is no old version in the wild — the new field is required, and a payload that lacks it is malformed and must throw. Tolerance for a hypothetical previous version is a compatibility shim by another name.

## Opportunistic Mesh & Store-Carry-Forward (BLE)

The Bluetooth transport is an **opportunistic mesh**. Delivery is multi-hop and works in two cooperating ways:

- **Managed flooding (open relay).** A node rebroadcasts any packet it receives to all of its other BLE neighbors, decrementing the packet's TTL and dropping it at zero. A `BloomFilter` of seen packet IDs prevents loops and re-sends. Relaying is **not** friend-gated: a node forwards packets for recipients it has no relationship with — it only ever sees the recipient ID, never the sender or the content. This is a deliberate reversal of the old "never relay for arbitrary peers" rule, and it is what makes the mesh reach beyond direct neighbors.
- **Store-carry-forward (DTN).** When a packet's recipient is not currently in range, a relay **caches** it in a bounded, age-expiring store and re-floods it when that recipient later appears (on their ANNOUNCE / peer-connected event). Intermediaries thus hold other peers' traffic — but only as opaque, recipient-addressed, end-to-end-sealed bytes they cannot read.

The sender **still** keeps its own outbound queue (the madGLP "fair message delivery" assumption, `docs/GLP_Networking_API/sections/api.tex` §Networking Assumptions): the sender re-floods its own un-acked messages when conditions change, independent of any relay's DTN cache.

Bound everything: the DTN store, the per-recipient cache depth, and per-neighbor relay rate are all capped — an unbounded flood/cache is an abuse and battery sink. ANNOUNCE is **not** flooded; it stays neighbor-local (presence, not reach).

## Mesh Envelope & Trust

A relayed packet's **outer envelope carries only the recipient ID** (plus type, TTL, packet ID, length). It does **not** carry the sender — the sender's identity and the message body live inside an **encrypted envelope sealed to the recipient's Noise session**, readable only by the recipient. Consequences that are load-bearing for the whole design:

- **No cleartext sender, no per-packet Ed25519 signature on the wire.** The old header field for the sender pubkey and the whole-packet signature are gone. A relay cannot tell who originated a packet, and therefore **cannot authenticate it** — relaying is unverified by construction. This is the accepted cost of sender-anonymity; it is bounded by TTL, dedup, and per-neighbor rate limits, not by hop-by-hop signatures.
- **Authentication is end-to-end, inside Noise.** The recipient trusts a message because it decrypts under a Noise session whose peer static key was verified during the handshake. The peer's Ed25519 identity is conveyed **inside the encrypted handshake payload** (not in any cleartext header) and checked against the Noise static via the birational map (`docs/GLP_Networking_API/sections/ip.tex` §IP Connection). Because the outer envelope has no sender, the recipient demultiplexes an inbound sealed packet by **trial-decrypting** against its active sessions; the AEAD tag identifies the right one.
- **Sessions are keyed by peer identity, not by transport path.** A mesh session is end-to-end and survives changing relay paths. The application AEAD AAD must exclude any field a relay mutates (notably **TTL**).
- **ANNOUNCE is the one exception** — it is a neighbor-local, non-flooded presence broadcast that *is* about identity, so it carries the pubkey and a payload-level signature in the clear and is verified hop-locally.

## BLE Discovery & Identity

Every device advertises a public-key-derived Grassroots service UUID: a fixed Grassroots prefix plus the first 8 bytes of SHA-256(public key). The UUID is only a discovery hint, never an authorization proof. Identity is established by the **self-signed ANNOUNCE** — a neighbor-local (non-relayed) broadcast whose payload carries the full public key, nickname, and an Ed25519 signature over that payload (the packet header no longer signs). In open cold-call mode, nearby unknown BLE peers may complete ANNOUNCE; in closed mode, unknown nearby peers do not get ANNOUNCE, and friend-only metadata is sent only after a verified ANNOUNCE authenticates an accepted friend.

## Dual-Role BLE Is Mandatory

Every BLE pair must converge to a **dual-role connection**: two GATT legs, with each device central on one leg and peripheral on the other. Never ship a design that intentionally leaves a pair single-link. This requirement is inviolable.

Platform asymmetries are solved by choosing **who initiates each leg** — ordering, advertisement markers, pair reform — never by abandoning a leg. The one measured constraint (an iOS central cannot open the *second* link toward an Android it is already linked with; the connect wedges in `connecting` until timeout) is routed around by making iOS open the pair's *first* leg and the Android the reverse leg. iOS devices advertise the fixed `grs-ios` local name so peers can yield the first dial to them.

When a platform behavior is **unknown** (e.g. whether an iOS↔iOS reverse leg works), attempt it and let hardware decide — do not suppress it on extrapolation. A single-link pair is acceptable only as a *transient* state that the transport keeps trying to upgrade, or where hardware has *measurably* refused the second leg and the only remaining lever is initiator order.

## Well-Connected Friends & Hole-Punching

Most mobile devices sit behind NAT and cannot accept incoming UDP connections from the public Internet. A **well-connected** device is one that has a globally routable public address — it can be reached directly by anyone.

Well-connected friends play a special role: they act as **signaling relays** to help two NAT'd peers find each other. The flow is:

1. Each device registers its current address with its well-connected friends.
2. When peer A wants to reach peer B, A asks a mutual well-connected friend for B's address.
3. The friend coordinates a simultaneous hole-punch: it tells both A and B to send packets to each other at the same time, punching holes in both NATs.
4. Once the holes are open, A and B communicate directly — the well-connected friend is no longer in the path.

**Important:** Well-connected friends relay *signaling metadata* (addresses, punch timing), never message content — the **UDP/Internet transport stays direct point-to-point**. Multi-hop content relay happens only on the BLE mesh (see Opportunistic Mesh), and even there relays carry sealed bytes, not readable content.

**UDP signaling is friend-only.** This trust boundary is specific to Internet hole-punch coordination and is *separate* from the BLE mesh's open relay. A well-connected device only coordinates hole-punches between peers that are both its friends: it only registers friends' addresses in its address table, only responds to address queries for friends, and only sends PUNCH_INITIATE to friends. (The BLE mesh, by contrast, relays for arbitrary recipients — but it never exposes addresses or content, only forwards sealed packets by recipient ID.)

## Redux Architecture

All peer and transport state lives in an immutable Redux store (`AppState`). Key slices: `PeersState` (discovered BLE devices + identified peers), `TransportsState` (per-transport lifecycle + public address), `MessagesState`, `FriendshipsState`, `SettingsState`. UI reads from the store and subscribes to changes. Actions describe events; reducers produce the next state. No mutable singletons.

The Redux state is a strict projection of facts emitted by the transport layers — never an inference. Reducers must not synthesize state from "I haven't heard from X in N seconds" heuristics; that's the transport layer's job to surface as an explicit event (path failed, UDX session torn down, etc.).

## Transport Layer

Two transports are available, toggled independently in settings:

- **Bluetooth (BLE)** — local, no Internet required. Preferred when both are available.
- **Internet (UDP via UDX)** — global reach, requires Internet. Uses hole-punching for NAT traversal.

The `TransportState` lifecycle for each transport is: `uninitialized → initializing → ready → active` (plus `error` and `disposed`). A transport is "usable" when it is `ready` or `active`.

User-facing UI strings should say "Internet", not "UDP" or internal protocol names.

## One Address Per Connection, Multiple Candidates Per Peer

Per **connection**, exactly one address pair is in use — there is no per-message address selection or mid-stream address switching. But a device MAY advertise multiple address **candidates** in ANNOUNCE (e.g. public IPv4, public IPv6, link-local IPv6 for the same LAN), and each peer pair selects the candidate that actually works between them: link-local on the same LAN, public IPv6 across the Internet, IPv4 as a fallback. Once a connection is established on a candidate, the pair sticks to that candidate until the path breaks.

The primary public address is discovered via an external service (e.g. seeip.org). Link-local candidates are scoped to the local network and never reach the public Internet; they exist so two devices on the same LAN can connect directly without traversing NAT.

## Peer Address Persistence

Never unilaterally clear a peer's stored UDP address. Update it when a new valid address arrives (from ANNOUNCE, signaling, or observation), and clear it only when the peer explicitly tells us they no longer have one. Stale peer cleanup, our-side disconnects, and transport restarts must not null out `udpAddress` — it is the last known location and the only way to attempt reconnection. This applies to friends and non-friends alike.

## Transport Independence

BLE and UDP are independent transports. Disabling or losing one must have **zero effect** on the other's connection state, peer reachability, or online status. A peer connected via UDP remains online regardless of BLE state. The stale peer logic, the UI, and the reducer must all respect this: never let a BLE disconnection degrade UDP-derived state.

Application-level callbacks (`onPeerConnected`, `onPeerDisconnected`) report consolidated end-to-end reachability, not per-transport events: they fire only when the overall reachable/unreachable state changes (transitions to/from zero live transports). Losing one of two live transports does not fire a disconnect — it only fires when the *last* transport drops.
