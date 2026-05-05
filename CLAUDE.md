# Claude Instructions for Grassroots Networking

## Working Style
Always be precise, critical, and helpful. Prefer to ask rather than assume if you have unclarities.

## Project Philosophy

Grassroots Networking is a **peer-to-peer messaging transport** — a thin layer that moves packets between devices over Bluetooth (BLE) and the Internet (UDP). It is not an application; it is the plumbing that applications like GSG build on top of.

**Core principles:**

- **Direct delivery only.** Messages go straight from sender to recipient. If the recipient is unreachable, the send fails and the caller decides what to do. There is no caching, no store-and-forward queue, no relaying of message content through intermediaries. The application layer owns persistence and retry logic.
- **Identity is a key pair.** Every device holds an Ed25519 key pair. The public key *is* the peer's identity — nicknames are cosmetic. All trust decisions flow from cryptographic verification.
- **Two transports, one interface.** BLE covers nearby peers without Internet; UDP covers the globe. Both transports surface the same abstraction to the coordinator: connect, send, receive, disconnect. BLE is preferred when both are available.
- **Clean breaks, not compatibility shims.** When refactoring, fully replace old code. No legacy wrappers, no "kept for compatibility" comments, no dead code. Update every call site. There are no installed apps in the wild — you are free to rename, restructure, and break wire formats whenever it improves the design.

## No Legacy or Compatibility Code

When refactoring, DO NOT keep old code "for legacy" or "for compatibility". Fully replace old implementations, remove unused imports and dead code, and update all call sites. Use the Redux store (`AppState`) exclusively for shared state — no mutable singletons.

## No Store-and-Forward / No Relaying

Grassroots does NOT cache, relay, or forward messages on behalf of other peers. A send either succeeds (recipient is online and reachable) or fails immediately. The application layer handles retry. This is a deliberate design choice — keeping the transport layer stateless and simple.

## BLE Discovery & Identity

Every device advertises the same well-known Grassroots discovery service UUID. iOS-to-Android cross-platform discovery only works reliably when there is a single 128-bit UUID in the advertise packet (no per-peer derivation, no local name); pre-connect identity differentiation is impossible. Identity is established **only** post-connect via the ANNOUNCE handshake, which carries the full public key, nickname, and signature. Until ANNOUNCE arrives, a path is anonymous.

## Well-Connected Friends & Hole-Punching

Most mobile devices sit behind NAT and cannot accept incoming UDP connections from the public Internet. A **well-connected** device is one that has a globally routable public address — it can be reached directly by anyone.

Well-connected friends play a special role: they act as **signaling relays** to help two NAT'd peers find each other. The flow is:

1. Each device registers its current address with its well-connected friends.
2. When peer A wants to reach peer B, A asks a mutual well-connected friend for B's address.
3. The friend coordinates a simultaneous hole-punch: it tells both A and B to send packets to each other at the same time, punching holes in both NATs.
4. Once the holes are open, A and B communicate directly — the well-connected friend is no longer in the path.

**Important:** Well-connected friends relay *signaling metadata* (addresses, punch timing), never message content. This preserves the direct-delivery principle.

**Signaling is friend-only.** A well-connected device only coordinates hole-punches between peers that are both its friends. It only registers friends' addresses in its address table, only responds to address queries for friends, and only sends PUNCH_INITIATE to friends. This is a trust boundary — we don't relay for arbitrary peers.

## Redux Architecture

All peer and transport state lives in an immutable Redux store (`AppState`). Key slices: `PeersState` (discovered BLE devices + identified peers), `TransportsState` (per-transport lifecycle + public address), `MessagesState`, `FriendshipsState`, `SettingsState`. UI reads from the store and subscribes to changes. Actions describe events; reducers produce the next state. No mutable singletons.

The Redux state is a strict projection of facts emitted by the transport layers — never an inference. Reducers must not synthesize state from "I haven't heard from X in N seconds" heuristics; that's the transport layer's job to surface as an explicit event (path failed, UDX session torn down, etc.).

## Transport Layer

Two transports are available, toggled independently in settings:

- **Bluetooth (BLE)** — local, no Internet required. Preferred when both are available.
- **Internet (UDP via UDX)** — global reach, requires Internet. Uses hole-punching for NAT traversal.

The `TransportState` lifecycle for each transport is: `uninitialized → initializing → ready → active` (plus `error` and `disposed`). A transport is "usable" when it is `ready` or `active`.

User-facing UI strings should say "Internet", not "UDP" or internal protocol names.

## Single Public Address

Each device advertises exactly **one UDP address** — the public address discovered via an external service (seeip.org). Never advertise LAN/private addresses. Never add a second address field to the ANNOUNCE. If the public address doesn't work on the local network (hairpin routing failure), the solution is to fix the transport layer (e.g. fall back to raw UDP), not to add LAN addresses.

## Peer Address Persistence

Never unilaterally clear a peer's stored UDP address. Update it when a new valid address arrives (from ANNOUNCE, signaling, or observation), and clear it only when the peer explicitly tells us they no longer have one. Stale peer cleanup, our-side disconnects, and transport restarts must not null out `udpAddress` — it is the last known location and the only way to attempt reconnection. This applies to friends and non-friends alike.

## Transport Independence

BLE and UDP are independent transports. Disabling or losing one must have **zero effect** on the other's connection state, peer reachability, or online status. A peer connected via UDP remains online regardless of BLE state. The stale peer logic, the UI, and the reducer must all respect this: never let a BLE disconnection degrade UDP-derived state.
