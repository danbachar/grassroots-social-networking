# UDX fan-out probe

How many backbone peers can one phone actually hold open?

The simulator's leader arm gives every leader an Internet link to every
other leader. At 160 nodes that is ~46 concurrent UDX peers per leader, and
it grows with the network — the assumption is doing real work in the result
and has never been measured. This deployment measures it.

## What it measures

Two things, from the same responders.

**Cost per peer.** A phone opens one UDX stream to each responder and holds
it. Every responder logs the source address and port it sees, which is the
phone's mapping as its NAT rewrote it:

- every responder reports the **same** source port — endpoint-independent
  NAT, and the whole fan-out costs **one** mapping and one keepalive;
- every responder reports a **different** source port — address-and-port
  dependent NAT, and the fan-out costs **N** mappings and N keepalives.

Which of the two holds is what decides whether a wide backbone is cheap or
expensive, and it is a property of the carrier and router, not of the app.

**Idle lifetime.** With `--silence-probe T`, a responder stops talking for T
seconds after the last byte it received, then sends unsolicited data. If the
phone receives it, the mapping survived T seconds of silence. Binary-search T
and you have the keepalive interval every peer has to pay for.

The cap then follows: an acceptable battery budget divided by the per-peer
cost at that interval.

## Running it

Linux host, public IP, `docker compose`:

```bash
./gen-compose.py -n 16 && docker compose up -d --build
```

Open UDP `41000-41015` to the phone. Then, from the phone, open one stream
per port and hold. Read the answer with:

```bash
docker compose logs --no-color | ./analyze.py
```

Sweep `-n 1 4 8 16 32 64 128` in separate runs, recording phone-side battery
across each. For the lifetime run instead:

```bash
./gen-compose.py -n 4 --silence-probe 45 && docker compose up -d --build
```

Without a phone, `bin/probe_client.dart <host> <base-port> <peers> <hold-s>`
opens the same streams from any machine, which is how to check a deployment
is answering before taking it to the field.

## The phone side

`phone/` holds the streams on a real handset, and `run-fanout.sh` sweeps the
fan-out while sampling power. The phone reports what the streams did; the
host records what it cost. Neither measures the other, so the two records
stay independent and line up by timestamp.

One-time scaffold, since the Android project is generated rather than
committed:

```bash
cd phone && flutter create --platforms=android . && flutter pub get
```

Then, with the responders already up:

```bash
./run-fanout.sh --host <responder-ip> --peers 1 4 16 64 --hold 600
```

Each fan-out lands as `results/n<N>_power.csv` and `results/n<N>_phone.jsonl`.
The cost curve is charge drawn per unit time against N; if it is linear, the
per-peer cost is the slope and the cap is a battery budget divided by it.

The script unplugs charging for the run (`cmd battery unplug`) and resets on
exit, including on interrupt — charging masks the draw completely, so a run
that could not unplug is reporting nothing useful and says so. It also finds
which power file the handset exposes, because vendors differ and a missing
one would otherwise leave an empty column that looks like a zero.

Hold the screen state fixed across the sweep, and keep the handset still: a
screen that sleeps partway through one fan-out and not another moves the
curve more than the streams do.

## Constraints that change the answer

**Host networking is required, not a convenience.** Docker's bridge
networking rewrites the source address of inbound UDP, so every responder
would report the proxy rather than the phone — erasing the one measurement
this exists to take. That means Linux; on Docker Desktop the numbers are
meaningless.

**All responders share one IP.** Real backbone peers do not. A NAT keyed on
destination *address* alone will look endpoint-independent here and cost N
mappings in the field. To rule that out, run responders on several hosts, or
read the result as a lower bound on cost.

**One phone, one carrier, one router is one data point.** Mapping lifetimes
vary widely between carriers and home routers. The result justifies an order
of magnitude for the simulator's cap, not a precise number — so sweep the
cap across the range rather than pinning the measured value.

**Cellular is where fan-out gets expensive**, because each keepalive pulls
the radio out of idle and holds it in a tail state. Run Wi-Fi and cellular
separately; a Wi-Fi-only result will understate the cost. Note that the
wireless-adb phones lose adb when Wi-Fi drops, so the cellular arm needs a
USB-attached phone.

**The phone side is unverified on hardware.** It analyzes clean and the
responders are tested end to end, but no handset was attached when this was
written, so the first run should be a single peer for a short hold to
confirm the device path before sweeping.

**The responders do not speak Grassroots.** They complete a UDX handshake and
echo. That is enough for mappings and keepalives, which are properties of the
transport; it does not measure anything about ANNOUNCE, Noise, or custody.
