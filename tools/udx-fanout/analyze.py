#!/usr/bin/env python3
"""Reads responder logs and answers the two questions the run exists to ask.

Feed it `docker compose logs --no-color` or the raw JSONL.
"""
import argparse
import collections
import json
import re
import sys

p = argparse.ArgumentParser()
p.add_argument("log", nargs="?", default="-", help="log file, or - for stdin")
a = p.parse_args()

src = sys.stdin if a.log == "-" else open(a.log)
events = []
for line in src:
    # compose prefixes each line with "peer000-1  | "
    line = re.sub(r"^\S+\s+\|\s*", "", line.rstrip())
    if not line.startswith("{"):
        continue
    try:
        events.append(json.loads(line))
    except json.JSONDecodeError:
        pass

if not events:
    sys.exit("no JSON lines found")

peers = sorted({e["peer"] for e in events})
opens = [e for e in events if e["ev"] == "open"]
by_peer = collections.defaultdict(set)
for e in opens:
    by_peer[e["peer"]].add(e["src"])

mapped_ports = {s.rsplit(":", 1)[1] for s in (e["src"] for e in opens)}
addrs = {s.rsplit(":", 1)[0] for s in (e["src"] for e in opens)}

print(f"responders seen        {len(peers)}")
print(f"responders with a peer {len(by_peer)}")
print(f"streams opened         {sum(1 for e in events if e['ev'] == 'stream')}")
print(f"source addresses       {len(addrs)} {sorted(addrs)[:4]}")
print(f"distinct source ports  {len(mapped_ports)}")

if len(by_peer) > 1:
    if len(mapped_ports) == 1:
        print("\nNAT: endpoint-independent — every responder saw the same "
              "source port,\n     so the whole fan-out costs ONE mapping.")
    elif len(mapped_ports) >= len(by_peer):
        print("\nNAT: address-and-port-dependent (symmetric) — one source "
              "port per\n     responder, so the fan-out costs N mappings and "
              "N keepalives.")
    else:
        print(f"\nNAT: {len(mapped_ports)} mappings for {len(by_peer)} peers "
              "— partial reuse; read the\n     per-peer table below.")

probes = [e for e in events if e["ev"] == "probe_send"]
if probes:
    afters = sorted({e["afterS"] for e in probes})
    print(f"\nsilence probes sent    {len(probes)} after {afters}s of silence")
    print("     A probe that the phone never received means the mapping "
          "expired inside\n     that silence. Read the phone log, not this "
          "one — the send always succeeds.")

errs = collections.Counter(
    e["ev"] for e in events if e["ev"].endswith("error"))
if errs:
    print(f"\nerrors                 {dict(errs)}")

print("\nper responder:")
for peer in peers:
    srcs = by_peer.get(peer, set())
    n = sum(1 for e in events if e["peer"] == peer and e["ev"] == "data")
    tot = max((e.get("total", 0) for e in events
               if e["peer"] == peer and e["ev"] == "data"), default=0)
    print(f"  {peer:<10} src={','.join(sorted(srcs)) or '-':<24} "
          f"datagrams={n:<6} bytes={tot}")
