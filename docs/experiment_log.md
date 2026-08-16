# Experiment log

Every field run is reproducible from its commit: **one commit per run**, its hash
pinned below. Uploaded traces are keyed by the run id (`exp_<id>.jsonl`).

**Naming convention (from scf-rearm-12 on):** a run id carries a **three-word
change descriptor** suffix after the base name, so the id itself says what was
different — e.g. `scf-rearm-12-seen-window-cursor`. Runs before -12 predate this
rule and are named `scf-rearm-N`.

| run id | purpose | commit |
|---|---|---|
| `scf-rearm-7` | Arm B baseline — no-flood mesh, id-list sync offers, direct-recipient priority; the reference the GCS arm is measured against (9% delivery, 1.09× redundancy). | `6d1d7b6` |
| `scf-rearm-8` | Arm C, first GCS attempt — **aborted** before its anchor when the filter window bounds overflowed a uint32; no clean build commit (fix folded into `e214146`). | *(aborted)* |
| `scf-rearm-9` | Arm C, GCS **held**-filter with the uint64 window fix — priced the compact offer but exposed 12.09× conveyance redundancy and 1% delivery. | `e214146` |
| `scf-rearm-10` | Arm C, GCS held-filter with the seen set **age-bounded** (rotating bloom removed) — balanced load, delivery 1%→6%, but redundancy held at 12.76×. | `27786f6` |
| `scf-rearm-11` | Arm C, GCS filter advertising the **seen set** instead of held packets, so responders stop re-conveying already-delivered messages. | `f273184` |
| `scf-rearm-12-direct-deliver-connected` | Arm C + **direct-deliver fast path**: a message to a connected peer fires on the raw leg the moment it is sealed, not at the next sync offer. Reads delivery up vs -11 while redundancy stays ~1× (fast-path and sync copies must dedup on the packetId bloom). | `fc2b186` |
| `dilute-1-cooldown-alltoall` | **Diluting clique** N=2→6 (one node joins per 150 s phase via scriptedRadio join-order) under a light all-to-all write; recorded + auto-uploaded. Measures dual-leg convergence + delivery vs clique size, validating the dial-failure **cooldown** fix (rate-limited redial replacing e52ab04's one-strike eviction) under growth. | `5b22db4` |
| `dilute-2-loadsweep-alltoall` | **Load sweep**: diluting clique N=2→6, and at each N the all-to-all offered load ramps in 10 steps (~10% → `saturate`), 30 s/step. Delivery read vs the ACHIEVED send rate (saturate anchors the ceiling). Produces delivery-vs-load curves per clique size. | `8e6e306` |
| `dilute-3-direct-ack-nobuffer` | Load sweep re-run under the router-owned outbound path: direct-write to a connected recipient (ACKs included, no buffering when delivered directly), buffer only when unreachable. Reads ackRx/delivered recovery vs dilute-2 (6.4% ACK return, median 16 s). | `a408cf9` |
| `dilute-4-tenreps-n2`..`n6` | **10-rep load curves**, one ~1h run per fixed clique size N=2..6: 10 loads × 10 back-to-back 30 s trials, first N phones only (rest sat out), fresh convergence + upload per N. Gives per-(N, load) delivery with real confidence intervals on the router-owned outbound build. | `c86a867` |
