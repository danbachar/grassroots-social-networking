# Removing rendezvous servers in favor of well-connected friends

## Motivation

Grassroots Networking is meant to be infrastructure-free. Today the UDP/Internet
path leans on **rendezvous servers** (the `bootstrap_anchor` package): always-on,
neutral, non-friend facilitators that run the RECONNECT/AVAILABLE matcher and
coordinate NAT hole-punches. But the signaling layer *already* models a second
implementation of the same role — the **friend-mediator** (a client that, while
connected to both peers, does the same matching over its live connections;
`signaling_service.dart` §Facilitator roles). Removing RVs is mostly *deleting one
implementation and leaning on the other*, which also deletes the whole
`bootstrap_anchor/` server we otherwise have to run, secure, and keep wire-compatible.

The cost is real: RVs are always-on and neutral; friends are only useful when
online, publicly reachable, and reachable by both peers. We accept that tradeoff
(it matches the "grassroots" ethos and the GLP spec's friends-rendezvous step),
and cover the two things RVs uniquely provided — steady-state reconnection and
cold bootstrap — as below.

## The facilitator model: capability vs. willingness

A well-connected friend has two **independent** properties:

1. **Capability (auto-detected).** "I have a routable public address" — derived
   best-effort from `public_address_discovery` (a public, non-private,
   non-link-local candidate). Capability alone only qualifies a friend to mediate
   between *its own mutual friends* (no new trust — both parties are already theirs).

2. **Willingness (manual opt-in).** "I volunteer to **introduce strangers** —
   coordinate a first-contact hole-punch for a non-friend invitee redeeming an
   invite." This is a deliberate privacy choice, never auto-enabled.

## Trust gates

- **Mutual-friend mediation** (steady state): allowed for any friend that is
  currently connected to both peers. No new trust; unchanged friend-only posture.
- **Stranger introduction** (invite redemption): allowed only when **both**
  settings are open:
  ```
  facilitate = (coldCallTrustLevel == open) && (facilitateInvites == open)
  ```
  You cannot introduce strangers while closed to cold-calls — introduction is a
  strictly more-open stance. `facilitateInvites` is a separate toggle but is
  AND-gated by cold-call trust (UI disables it while cold-call is closed).
- **Invites are signed** by the inviter (see below).

## Flows

### 1. Steady-state remote reconnection (replaces RV fan-out)

Mediation eligibility is dynamic: **any mutual friend currently holding live
connections to both peers** can mediate; **well-connected friends are preferred**
(durable re-reach after an IP change). `fanOutReconnect` / `fanOutAvailable`
target *mutual friends I can currently reach* (well-connected first) instead of
configured RV addresses. Address reflection stays: seeip.org
(`public_address_discovery`) plus AddrReflect from any well-connected friend.

### 2. Cold bootstrap via invite links

An **invite link** is issued by the inviter and names one or more **introducers**
(the inviter's well-connected friends who have `facilitateInvites` open). It is a
signed capability:

```
invite = {
  inviter:      <inviter pubkey>,
  introducers:  [ {pubkey, addressCandidates[]}, ... ],   // redundancy
  expiry:       <unix seconds>,
  nonce:        <random, single/N-use>,
  maxUses:      <int>,
}
signature = Ed25519_sign(inviter_sk, canonical(invite))
```

Encoded as `grassroots://invite?d=<base64url(invite ‖ signature)>`.

Redemption:
1. Invitee opens the link → learns the inviter + introducers.
2. Invitee sends an `INTRODUCE(invite, signature)` signaling message to one or
   more introducers (redundancy; whichever succeeds first wins).
3. Each introducer verifies: signature is by **its own friend** (`inviter`),
   unexpired, nonce within `maxUses`, and **both its settings are open**. If so it
   runs the RV-style match (invitee ↔ inviter) and PUNCH_INITIATEs both. If not,
   it silently declines; the invitee's other named introducers may still succeed.
4. Invitee ↔ inviter hole-punch and Noise-handshake. The invitee echoes the
   invite `nonce` in the handshake payload; the **inviter** verifies its own
   signature + unused nonce, so it accepts this first contact **even if its own
   cold-call is closed** (it issued the invite). The nonce is then burned.

The signed invite thus does double duty: authorizes the *introducer* to help, and
authorizes the *inviter* to accept the specific redemption. Bearer-style (anyone
with the link can redeem) but bounded by signature + short expiry + `maxUses`, so
`open` means "help redeem *genuine* invites my friends issued," not "punch anyone
toward my friends."

## Deletion scope

- `bootstrap_anchor/` — the entire package (server, tests, Dockerfile, deploy).
- Settings: `rendezvousServers`, `anchorAddress`, `anchorPubkeyHex`,
  `RendezvousServerSettings`; the RV section of `settings_screen.dart`.
- `grassroots_network.dart`: RV branches (`_syncConfiguredRendezvous`,
  `_isRendezvousPubkeyHex`, RV priming/backoff, ~244 RV refs — most collapse into
  the friend path).
- Signaling: `RvListMessage` / `sendRvList` / `_handleRvList` (replaced by
  deriving facilitators from the friend graph + the `facilitateInvites` flag).

Keep: AddrReflect, hole-punch, friend-mediator, `public_address_discovery`.

## New surface

- **Setting:** `facilitateInvites` (open/closed), AND-gated by cold-call trust.
- **Deep links:** register `grassroots://` (Android intent-filter + iOS
  `CFBundleURLSchemes`), add an `app_links`-style dependency, handle inbound links
  in `main.dart`.
- **Invite UI:** Profile → "Invite" → pick from my well-connected + willing
  friends as introducers → build + share/copy the signed link.
- **Signaling:** `INTRODUCE` message (token-bearing) + inviter-side accept-on-nonce.
- **ANNOUNCE:** advertise a "willing to facilitate" bit so friends know who can
  introduce (capability is already derivable from advertised address candidates).

## Phased plan (so remote reconnect never breaks mid-flight)

1. **Generalize mediation** — dynamic dual-connected friend mediation +
   well-connected auto-detect + advertise; repoint fan-out to friends.
   *(Reconnection now works without RVs.)* — **DONE.**
2. **Delete RVs** — remove `bootstrap_anchor/`, RV settings + UI + code paths,
   `RvList*`. — **DONE.**
3. **Invite links** — signed invite + `INTRODUCE` flow + `facilitateInvites`
   setting + generate/redeem UI (the cold-bootstrap path). — **DONE**, with one
   deferral: the `grassroots://` link is generated and redeemed **in-app**
   (paste the link), but the native URL-scheme registration (Android
   intent-filter + iOS `CFBundleURLSchemes` + an `app_links`-style dependency
   so a tapped link cold-launches the app) is **not wired** — it is pure
   platform plumbing with no protocol logic, left as a follow-up. The
   ANNOUNCE "willing to facilitate" bit was not added: an introducer that
   declines simply drops the INTRODUCE, and invite redundancy covers it, so
   advertising willingness up front is an optimization rather than a
   requirement.

### What landed for phase 3

- `lib/src/signaling/invite.dart` — `Invite` (inviter, introducers,
  expiry, nonce, maxUses), Ed25519 sign/verify over the canonical body, and
  the `grassroots://invite?d=<base64url(body‖sig)>` codec. `InviteSigner`,
  `InviteRedeemResult`.
- `SignalingType.introduce` (0x0c) + `IntroduceMessage`; the friend-only
  trust gate in `processSignaling` now lets INTRODUCE through (self-authorizing).
- `SignalingService.coordinateIntroduction` — the introducer's single-step
  punch between invitee (observed address) and inviter (friend address).
- `GrassrootsNetwork`: `createInvite`, `redeemInvite`, `_handleIntroduceReceived`
  (inviter-role accept+nonce-burn / introducer-role verify+coordinate),
  `_availableIntroducers`, and the `_invitedContacts` first-contact
  authorization that lets an invitee through even under closed cold-call.
- `facilitateInvites` setting, AND-gated by cold-call
  (`willingToFacilitateInvites`); settings toggle + You-tab generate/redeem UI.

## Open items / risks

- **Availability:** with no always-on RV, remote reconnection depends on a mutual
  well-connected friend being online. Inherent; acceptable for a grassroots net.
- **Capability false-positives:** a peer behind symmetric NAT may advertise a
  public candidate yet be unreachable; best-effort means wasted punch attempts.
  Mitigate by deprioritizing facilitators whose punches keep failing.
- **Invite abuse bound:** short expiry + `maxUses` + single-use nonce keep an
  `open` introducer from becoming an open punch-relay toward its friends.
