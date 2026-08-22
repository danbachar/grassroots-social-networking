# Control-plane figures — how to regenerate them

    cd trace_server/analysis/nexus-line
    python3 analyze.py --uploads 'exp_line-2.jsonl:3085171:0' 'exp_line-2.jsonl:210193:0' --until '2026-08-22 10:49:48'

That is the 2026-08-22 Nexus field sweep, cut at the surviving phone's own
`expStop`. For any later run, `python3 analyze.py` with no arguments takes the
newest upload per device, and `--list` prints the candidates.

Needs `ssh trace-server` and matplotlib. Writes PDF + PNG + `summary.csv`
next to the script; server pulls are cached in `.cache/` (delete to refetch).

## The figures

| file | what it shows |
|---|---|
| `fig_establishment` | every trial's stack-cold time to a session, one series per phone, lines are per-distance medians |
| `fig_delivery` | delivered fraction per direction |
| `fig_stages` | median seconds from `bt-on` to advertisement seen / GATT up / Noise session / pair usable |
| `fig_control_bytes` | control bytes a trial by packet class, data plane overlaid, with the control:data ratio |
| `fig_power` | median discharge current during the dwell |
| `fig_path_loss` | median conn-RSSI per distance, log-distance fit, July Pixel fit overlaid |

## What the numbers say (2026-08-22)

Control plane is **2.3 kB per trial and flat with distance** — `announce`
alone is ~1.45 kB of it, the sync filter and ACKs ~0.7 kB, handshake ~0.25 kB
— against **0.49 kB of data plane**, a **4.8 : 1** ratio at this load (2
messages a trial each way). The ratio is a property of the load, not the
range: the beacon rate does not know how far away the peer is. Establishment
medians sit at 2.1–4.3 s with no trend to 120 m, and the stage plot shows
where the time goes — discovery dominates, GATT-to-session is a few hundred
milliseconds.

Delivery: **233/238 forward, 230/234 reverse**.

## Two things to state in the caption

* **The reverse direction is reconstructed from receipts** for 10–110 m. That
  phone fell mid-run and cold-started, losing everything since its last flush,
  so its own ledger is gone; the survivor's `recv` records are the evidence and
  the denominator is the per-trial send rate observed on the recording side.
  Those points are hollow and marked INFERRED, and they are a **floor** — a
  message lost in flight appears in neither file. The dip to 90 % at 110 m is
  the fall itself (the peer stopped sending in `t10`), not a range effect.
* **120 m carries 17 trials, not 10** — the survivor's 10 plus 7 from the
  restarted phone, which was physically at 120 m. Its two >20 s establishments
  are waits through the survivor's unsynchronised reset windows, which is why
  the second phone's series is drawn separately rather than pooled.

`fig_stages` also shows GATT coming up *before* the peer's advertisement is
seen at several distances. That is real and not a clock artefact: a GATT link
exists before identity does, so the leg the peer dials lands before we have
seen anything from it.
