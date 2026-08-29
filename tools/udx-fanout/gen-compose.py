#!/usr/bin/env python3
"""Writes a compose file serving a whole port range.

Two things it deliberately does not do.

It does not run one container per peer. A peer costs a UDP socket and a
multiplexer, not a process, and a small host has no memory for a hundred
Dart runtimes — on a 2 GB box that is an OOM kill, quite possibly of
whatever else the host is running. The handset cannot tell the difference:
its NAT keys on destination address and port, and those are distinct
either way. --shards splits the range across containers where crash
isolation is worth the memory.

It does not use bridge networking. Docker rewrites the source address of
inbound UDP there, so every responder would report the proxy rather than
the phone — erasing the one measurement this exists to take. Host
networking needs Linux; on Docker Desktop the numbers are meaningless.
"""
import argparse

p = argparse.ArgumentParser()
p.add_argument("-n", "--peers", type=int, default=128,
               help="peers to serve, one per port (default 128)")
p.add_argument("--base-port", type=int, default=41000)
p.add_argument("--shards", type=int, default=1,
               help="containers to split the range across (default 1)")
p.add_argument("--silence-probe", type=int, default=0,
               help="seconds of silence before an unsolicited probe; "
                    "0 disables. Set this for the mapping-lifetime run.")
p.add_argument("--report", type=int, default=10,
               help="seconds between throughput reports; 0 disables")
p.add_argument("--echo", action="store_true",
               help="echo received bytes back. Off by default: under a "
                    "throughput run an echo doubles the traffic and prices "
                    "the downlink too, which is a different question.")
p.add_argument("-o", "--out", default="docker-compose.yml")
a = p.parse_args()

if a.shards < 1 or a.shards > a.peers:
    raise SystemExit("--shards must be between 1 and --peers")

last = a.base_port + a.peers - 1
per = -(-a.peers // a.shards)   # ceil, so no peer is dropped
svc = []
for i in range(a.shards):
    lo = a.base_port + i * per
    hi = min(lo + per - 1, last)
    if lo > hi:
        break
    svc.append(f"""  responder{i}:
    image: udx-fanout-responder
    build: .
    network_mode: host
    restart: unless-stopped
    environment:
      UDX_PORTS: "{lo}-{hi}"
      PEER_PREFIX: "peer"
      SILENCE_PROBE_S: "{a.silence_probe}"
      REPORT_S: "{a.report}"
      ECHO: "{'true' if a.echo else 'false'}"
    logging:
      driver: json-file
      options: {{max-size: "50m", max-file: "3"}}""")

shard_flag = f" --shards {a.shards}" if a.shards != 1 else ""
with open(a.out, "w") as f:
    f.write(f"# Generated: {a.peers} peers on UDP {a.base_port}-{last}, "
            f"{len(svc)} container(s).\n"
            f"# Regenerate with: ./gen-compose.py -n {a.peers}{shard_flag}\n"
            "services:\n" + "\n".join(svc) + "\n")
print(f"{a.out}: {a.peers} peers on UDP {a.base_port}-{last} "
      f"across {len(svc)} container(s)")
print(f"open the firewall with: sudo ufw allow {a.base_port}:{last}/udp")
