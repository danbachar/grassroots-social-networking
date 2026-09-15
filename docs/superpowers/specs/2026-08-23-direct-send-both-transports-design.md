# Direct send over both transports, originator only

Status: implemented
Date: 2026-08-23

## The rule

A node writes a packet **directly** only when it **created** that packet and
holds a live link to the recipient — the BLE leg preferred, else a live UDX
connection. Everything else goes to the DTN memory buffer and reaches the
recipient through the sync exchange.

Two changes follow from that one sentence, in opposite directions:

- an **originator** gains the UDX arm it does not have today
- a **carrier** loses the immediate last-hop write it has today

## Change 1 — the originator writes over either transport

### Why it does not today

`_trySendMessageNow` (`lib/src/grassroots_network.dart:1477`) has two
branches. The BLE branch is entered whenever BLE is enabled and usable, and
inside it `_ensureNoiseSession` short-circuits to true because the session
gate above already proved a session exists. It hands each sealed packet to
`MessageRouter.dispatchOutbound`, which direct-writes or buffers, and returns
true **either way**.

Buffering therefore counts as success, so the UDP branch below is unreachable
on any device with BLE enabled. A message to a peer out of BLE range but on a
live UDX link is buffered rather than written, and leaves on the next sync
exchange — up to one announce interval later (10 s by default).

The cause is not branch order. `dispatchOutbound`
(`lib/src/routing/message_router.dart:1018`) is already the single
transport-agnostic decision point; it has been injected a BLE-only
capability. `directSend` (`lib/src/grassroots_network.dart:3881`) resolves a
BLE leg or returns false — it cannot see a UDX connection.

### `directSend` learns both transports

Its contract becomes: write the sealed packet on a live link to this
recipient and report which transport carried it, or report that no live link
exists.

- live BLE leg (`_connectedBleDeviceIdForPeer`) → `_bleService.sendToPeer`
- else live UDX connection (`_udpService.getPeerIdForPubkey != null`) →
  `_udpService.sendToPeer`
- else → none

BLE stays preferred when both are live. Neither arm dials: a link either
exists or the packet is buffered.

Return type changes from `bool` to `PeerTransport?`, and `dispatchOutbound`
changes with it, because `_markSent` needs to record which wire carried the
message and that answer now comes from the router rather than from which
branch ran. The coordinator maps `PeerTransport` to `MessageTransport` at the
`_markSent` call.

### The send path collapses to one branch

`_trySendMessageNow` becomes:

1. session gate — unchanged, no session means no packet is ever created
2. `createMessagePacket`
3. seal and fragment once
4. `dispatchOutbound` per sealed packet
5. `_markSent` with the transport the router reports, `aired` true if any
   packet was written

A fragmented message can split across outcomes — some fragments written, some
buffered. `aired` is true if **any** fragment was written, and the recorded
transport is the one that carried the first written fragment. A direct write
that fails falls through to the buffer, as `dispatchOutbound` already does
today: the write is attempted, and only its failure produces a buffer entry.

The UDP branch (`lib/src/grassroots_network.dart:1626-1721`) is deleted,
along with its inline connect-on-demand, its inline `_discoverPeerViaFriends`
call, and its per-transport seal. The send path no longer dials, punches, or
queries mediators.

`_sendPacketViaUdp` and `_sealedPacketBytesForTransport` are **not** deleted —
they have five other callers (Noise handshake, ANNOUNCE, signaling). Only
their message-path call sites go.

### Why there is no `_sendPacketViaBle` to match

`_sendPacketViaUdp` bundles three steps: connect if needed, seal for the
transport, write. BLE has no counterpart because it has no dial — a BLE link
either exists, formed by scanning, advertising and pairing, or it does not.
The nearest thing, `_sendDirectSignalingOverLiveBle`
(`lib/src/grassroots_network.dart:2863`), resolves an already-live leg or
returns false.

Once the send path writes only on live links, the establish half is unwanted
and both transports reduce to the same two steps: resolve a live handle,
write already-sealed bytes. The symmetric pair is the two arms of
`directSend`, not a new helper. This also removes the second asymmetry —
`_sendPacketViaUdp` seals inside itself while the BLE message path seals
before dispatch, which is what makes one-seal-one-packetId impossible today.

## Change 2 — the carrier's immediate last hop is removed

Today a relay that **receives** a transit packet whose recipient it is
directly linked to writes it at once
(`lib/src/routing/message_router.dart:419-433`), storing it in custody in the
same step. That write is removed. A carried packet is stored and leaves only
through the sync exchange, like every other packet the node did not create.

- The `relayDirect` custody trace event goes with it. Nothing consumes it —
  no analyzer in `trace_server/` references it.
- After this, `directSend` has exactly one caller, `dispatchOutbound`, and
  is by construction the originator's tool alone.
- Custody behaviour is unchanged: a transit packet is stored on arrival
  whether or not the recipient is reachable.

**Cost, accepted deliberately.** A carried message whose recipient is
directly connected now waits for that peer's next sync filter rather than
going out on arrival, so the last hop gains up to one announce interval. This
is the latency the exception was introduced to remove.

**Not a correctness loss.** A TTL-exhausted packet stays in custody and
remains conveyable at every sync exchange, so nothing becomes undeliverable —
only later. It also removes the bounded last-hop duplication the exception
accepted, where every carrier linked to the recipient wrote its own copy and
the recipient deduped the rest.

## Sealing stays exactly once

A packet sealed twice would carry two packetIds, breaking dedup, the ACK
index (`_dtnPacketIds`) and the seen-set. The bytes in the buffer and the
bytes on the wire are the same bytes.

Because a buffered packet must stay conveyable over the BLE mesh, that single
seal is fragmented to the BLE floor MTU — 138 bytes
(`lib/src/protocol/fragment_handler.dart:37-41`). The deleted UDP branch did
not fragment, so on a BLE-disabled device a large message that used to cross
UDX as one packet now crosses as fragments. With BLE enabled nothing changes:
that path already fragments everything, including messages that reach a peer
over UDX by sync exchange.

## Explicitly unchanged

- **The sync exchange stays on both transports**, on both triggers (session
  established, announce tick). It is not redundant with direct send: it is
  the only repair path for a packet buffered while a link is already up — for
  example a direct write that failed — which an on-connect drain would strand
  until a reconnect that a stable UDX link may never have. After change 2 it
  is also the only path for every carried packet.
- **No blind push on connect.** Direct send writes one packet at the moment
  it is created, to a peer already connected; it never replays custody at
  link-up. That replay was built, measured and deleted: 30.9 packets re-sent
  per reconnection over a 90-cycle run, 31% of acknowledgement traffic
  (`docs/architecture-overview.tex:471`).
- DTN buffer drain policy, TTL accounting (one decrement per arrival, at the
  receiving node), both dedup layers (`_seenPackets`, `_deliveredMessages`),
  and the `queued` message status.

## Known gap, deliberately not addressed here

A friend whose address we hold but who shares **no mediator** with us is
never re-dialed after a link drops quietly. `_discoverUnreachableFriends`
runs each announce tick but skips friends with no mediators
(`lib/src/grassroots_network.dart:3691-3694`), and `_reconnectUdpFriends`
does dial known addresses but only fires on our own address change, on
enabling the transport, and at cold start.

This predates the change: with BLE enabled the send path's dial was already
unreachable. It self-heals whenever either side restarts. It gets its own
spec — give the announce-tick sweep the address-dial step
`_reconnectUdpFriends` already has, and clear a peer's discovery throttle on
a UDX drop so the next tick retries at once.

## Testing

TDD, extending the `bufferSnapshot` witness used by
`test/grassroots_network_session_gate_test.dart`:

- a recipient live only over UDX gets a direct write and no buffer entry
- BLE carries it when both links are live
- neither link live → buffered, status `queued`, not `failed`
- no session → still no packet at all, buffer and ACK index both empty
- a fragmented message dispatches every fragment, and a partial write still
  reports `aired`
- **a carried packet whose recipient is directly linked is buffered, not
  written** — the guard on change 2

## Files touched

- `lib/src/grassroots_network.dart` — `directSend`, `_trySendMessageNow`,
  `_markSent` call sites
- `lib/src/routing/message_router.dart` — `dispatchOutbound` return type, the
  relay-arrival direct write and its `relayDirect` trace event
- `test/` — new coverage as above
- `CLAUDE.md` — two edits. The store-carry-forward paragraph must say that a
  send direct-writes on a live link over **either** transport, not a BLE
  neighbour alone. The paragraph beginning "The recipient is the exception,
  and a carrier delivers to it immediately" (line 29) is withdrawn: the sync
  exchange becomes the only way a packet reaches a node that did not create
  it, with no exception for the recipient.
