# Handover prompt — continue bitchat_transport on another machine

Paste the block below into a fresh Claude session on the destination machine. It assumes you `git pull` the `social-graph-connectivity` branch first so the WIP commit is present.

---

I'm continuing work on **bitchat_transport**, a peer-to-peer messaging transport (BLE + UDP/UDX, Flutter/Dart). The repo is checked out at the current working directory on this machine. Please read `CLAUDE.md` at the repo root before doing anything — it contains the non-negotiable project philosophy (direct delivery only, no store-and-forward, deterministic anchor subkey, transport independence, etc.).

## What's on disk

The most recent commit on `social-graph-connectivity` is a large WIP:

> **WIP: bootstrap anchor server + FRIENDS_SYNC + derived anchor subkey**

It has NOT been compiled or tested — the previous machine had no Dart SDK. Treat it as "code-complete but unverified."

Start by running:

```
git log -1 --stat
cat bitchat-anchor-session-summary.md
```

to orient yourself. `bitchat-anchor-session-summary.md` is the condensed design/implementation summary from the prior session.

## What this WIP delivers

1. **Bootstrap anchor server** under `bootstrap_anchor/` — a Dart service deployable to Cloud Run that acts as a well-connected signaling relay.
   - Identity: no on-disk keypair. Server reconstructs its Ed25519 key each startup from `--seed <64-hex>`. The seed is the deterministic anchor subkey derived from the owner's private seed via `SHA-256(ownerSeed || "bitchat-anchor")`.
   - CLI: `--seed <hex>` and `--owner <hex>` both mandatory.
   - Only relays signaling (addresses, PUNCH_INITIATE) for peers that are in the owner's friend list. Never relays message content.
   - Dockerfile + Dockerfile.standalone + build.sh + deploy.sh ready for GCP.

2. **FRIENDS_SYNC protocol (type 0x08)** — owner's device pushes its current friend list to the anchor so the anchor knows who it's allowed to serve.
   - Wire: `type(1) + count(2) + [pubkey(32) + nickLen(1) + nick]*`
   - Implemented in both client (`lib/src/signaling/signaling_codec.dart`) and server (`bootstrap_anchor/lib/src/signaling_codec.dart`).

3. **Derived anchor subkey on the client** — `BitchatIdentity` gained `deriveAnchorKeyPair()`, `anchorPubkeyHex`, `anchorPublicKey`, `anchorSeed`. `lib/src/bitchat.dart` caches these at init and uses the cached values in `_onFriendshipsChanged()` / `_syncFriendsToAnchor()`.

4. **Settings screen** now has an Anchor Server section with just an address field (pubkey is derived, never stored). `SettingsState` lost `anchorPubkeyHex` and gained a sentinel-based `copyWith` so `anchorAddress` can be explicitly cleared.

5. **Large misc WIP** in `lib/src/bitchat.dart` (+~620 lines), `signaling_service.dart`, `transport/udp_transport_service.dart`, `public_address_discovery.dart`, peers/transports store, and tests. These are from earlier uncommitted work that got swept into the same WIP commit — inspect `git show HEAD` to see scope.

## Immediate next steps

1. **Build + static analysis on this machine** (this has never happened for the WIP):
   ```
   flutter pub get
   dart analyze
   cd bootstrap_anchor && dart pub get && dart analyze && cd ..
   ```
   Expect errors. Fix them in place — do NOT add compatibility shims or keep legacy wrappers (see CLAUDE.md "No Legacy or Compatibility Code").

2. **Run the test suite**: `flutter test`. Several tests were edited (`protocol_handler_test.dart`, `message_router_test.dart`, `address_utils_test.dart`) — verify they pass.

3. **Verify FRIENDS_SYNC end-to-end**: encode on client → decode on server, same bytes. The prior session claimed byte-identical codecs but it was never actually exercised.

4. **Smoke-test the anchor server locally**:
   ```
   cd bootstrap_anchor
   dart run bin/server.dart --seed <64-hex> --owner <64-hex>
   ```
   Seed and owner must both be exactly 64 hex chars.

5. Only after 1–4 pass, consider deploying via `bootstrap_anchor/deploy.sh <ANCHOR_SEED_HEX> <OWNER_PUBKEY_HEX>`.

## Known rough edges / pinned bugs (from earlier sessions, not addressed in this WIP)

- **10+ unpushed commits** on `social-graph-connectivity` — confirm `git log origin/social-graph-connectivity..HEAD` and decide whether to push.
- **BLE peripheral can't send to connected centrals** — receive works, send is broken.
- **Auto-UDP retry is too aggressive** — causes reconnect storms.
- **BLE disconnect fix** — was in flight.
- **Stale friendship cleanup** — never finalized.

## Ground rules (from CLAUDE.md — read it in full)

- Direct delivery only. No caching, no store-and-forward, no content relaying.
- Transport independence: BLE state must never affect UDP-derived state and vice versa.
- Never unilaterally clear `udpAddress`. Update on new address, clear only when the peer explicitly says they no longer have one.
- Single public address per device (from seeip.org); never advertise LAN addresses.
- Well-connected friends relay *signaling only*, never message content, and only for mutual friends.
- Redux store is the only source of peer/transport truth. No `PeerStore`, no mutable singletons.
- When refactoring, fully replace old code. No "kept for compatibility" comments.
- User-facing UI says "Internet", not "UDP".

## How to work with me

Be precise and critical. Ask before assuming. Before any non-trivial change, tell me what you're about to do and why. Don't skip the build/analyze step — that's the whole point of moving to a machine with a Dart SDK.

Start by reading `CLAUDE.md` and `bitchat-anchor-session-summary.md`, then run `flutter pub get && dart analyze` and report back what breaks.
