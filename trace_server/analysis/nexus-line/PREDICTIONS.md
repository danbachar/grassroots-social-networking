# nexus-line — predictions, committed before the run

Two Nexus 5X (`00d98aa1795bc454` nick 4, `00de4b24f89021e4` nick 1) on the
same tripods and the same 12 places as the Pixel run. Software, procedure,
mounting and load are held constant, so hardware class is the only variable
left.

Comparator, `line-field/README.md` — two Pixel 10 Pros, 2026-08-20:

| | Pixel |
|---|---|
| path loss | RSSI(d) = −36.6 − 18.2·log10(d), n = **1.82**, σ 3.2 dB |
| establishment 10–110 m | 20/20 every distance, medians 2.3–6.9 s |
| establishment 120 m | 2/20, ~20.5 s — the cliff |
| delivery | 444/444 |
| control plane | ~3.1–3.4 kB/trial, flat |
| power | 204–233 mA, flat |

## The decision rule needs one correction before it is used

The brief reads a hardware verdict off the exponent: `n≈3.2 → hardware
dominates`. **`n` is the wrong instrument for that question.** It is the slope
of received power against log distance — a property of the propagation
geometry, which is exactly what this arm holds constant. The handset moves the
*intercept* (TX power, antenna gain, and the vendor's RSSI calibration, which
is not an absolute scale) and it moves the *sensitivity floor*, which is what
sets the cliff. Neither of those tilts the slope.

So a hardware effect can be large and still leave n ≈ 1.8. Reading "n stayed
1.8" as "mounting dominated" would then be wrong. The discriminators that do
carry hardware are **A** and **the cliff distance**, and those are what the
predictions below commit to. n is still worth fitting — a slope that really
does move to ~3 means something about the site or the mounting changed and
the arm is not the controlled comparison it claims to be.

## Committed predictions

| # | quantity | prediction | confidence |
|---|---|---|---|
| 1 | path-loss exponent n | **1.7–2.3**, not ~3.2 | high |
| 2 | intercept A | **5–12 dB below** the Pixels' −36.6 | medium |
| 3 | cliff (first distance under 50 % establishment) | **70–100 m**, i.e. it moves in | medium |
| 4 | establishment at 10 m | **≥ 80 %** of trials | high |
| 5 | establishment medians where it forms | **slower than 2.3–6.9 s**, heavier tail | medium |
| 6 | delivery among established trials | **~100 %** | high |
| 7 | `00d98aa1795bc454` vs `00de4b24f89021e4` | the first shows **more reset overruns and more 133s** | medium |

Prediction 7 is not a guess. Under its previous identity that serial was the
worst unit in the fleet on reset cost — a discrete second mode at 15.08–15.14 s
on ~20 % of resets, and the only 109 s and 179 s outliers measured. Its partner
was clean, 0 overruns in 30, max 3.19 s. If the pair diverges on establishment,
check that asymmetry before attributing anything to hardware class as such:
one bad unit is not a device generation.

## What would falsify the arm rather than answer it

* n lands near 3 → the site or the mounting is not actually held constant, and
  the July-vs-August confound is not isolated after all.
* Establishment fails at 10 m → something is broken, not distant. Stack-reset
  and re-run before reading anything into the ladder.
* The two phones' clocks drift apart during the run → cross-device numbers are
  unusable; same-device establishment still is.

## Anchor comparability — must be settled before the tables are compared

The brief anchors establishment at the **`bt-on`** marker. The Pixel comparator
was anchored at **`links-reset`** (`line-field/README.md`, "anchored at radio-up
(the `links-reset` marker)"). Those are different instants, so the two runs'
establishment numbers are not comparable as they stand.

Re-anchor the Pixel run to `bt-on` and quote both from the same definition, or
measure the `links-reset`→`bt-on` gap and state it. Do not compare a `bt-on`
median against a `links-reset` median.
