#!/usr/bin/env python3
"""Writes a compose file with N responders, one per UDP port.

Host networking is not a convenience here. Docker's bridge networking
rewrites the source address of inbound UDP, so every responder would report
the same proxy address instead of the phone's mapping — which is the one
measurement this experiment exists to take. Host networking needs Linux;
on Docker Desktop the numbers would be meaningless.
"""
import argparse

p = argparse.ArgumentParser()
p.add_argument("-n", "--peers", type=int, default=16,
               help="responders to run (default 16)")
p.add_argument("--base-port", type=int, default=41000)
p.add_argument("--silence-probe", type=int, default=0,
               help="seconds of silence before an unsolicited probe; "
                    "0 disables. Set this for the mapping-lifetime run.")
p.add_argument("-o", "--out", default="docker-compose.yml")
a = p.parse_args()

svc = []
for i in range(a.peers):
    port = a.base_port + i
    svc.append(f"""  peer{i:03d}:
    image: udx-fanout-responder
    build: .
    network_mode: host
    restart: unless-stopped
    environment:
      UDX_PORT: "{port}"
      PEER_LABEL: "peer{i:03d}"
      SILENCE_PROBE_S: "{a.silence_probe}"
    logging:
      driver: json-file
      options: {{max-size: "50m", max-file: "3"}}""")

with open(a.out, "w") as f:
    f.write(f"# Generated: {a.peers} responders on UDP "
            f"{a.base_port}-{a.base_port + a.peers - 1}.\n"
            f"# Regenerate with: ./gen-compose.py -n {a.peers}\n"
            "services:\n" + "\n".join(svc) + "\n")
print(f"{a.out}: {a.peers} responders, UDP "
      f"{a.base_port}-{a.base_port + a.peers - 1}")
