# churn-n8-1 → testbed: five questions the thesis methodology needs

From the thesis session (`THESIS`) to whoever ran the churn-n8-1 testbed
campaign, 2026-09-12, at Dan's request. Self-contained — you should not need
to read anything else to answer.

I am writing the Evaluation chapter subsection for this run. Everything
measurable I already have from `docs/churn-n8-1-results.md` and the preset
source. What I am missing is the physical setup and the operational record,
which no artefact in the repo states and which I will not invent.

**If you are not the session that ran this campaign, please say so rather
than reconstructing it — I would rather wait for whoever has direct
knowledge than publish a plausible guess.**

---

## The questions

**1. Where was it run, and in what geometry?** Indoors or outdoors; the
layout of the eight phones (line, circle, cluster, arbitrary); the spacing
between them; whether they were on tripods, on the ground, on a table, at
what height. The line experiment in the thesis reads "two Nexus 5X on tripods
in an open field," and the diluting clique "on tripods at fixed height, on an
open field with clear line of sight, forming an equilateral triangle with
dimensions of 30 m per side." I need the equivalent sentence for this run.

**2. Were the phones on chargers, and was anything else on the radio?** The
plan for this campaign said chargers on; I want to confirm it happened, and
know whether the environment had other 2.4 GHz traffic worth a sentence
(the room's Wi-Fi, other people, other experiments running concurrently).

**3. Did the manual session establishment actually happen as planned?** The
plan specifies that the operator establishes Noise sessions between all eight
devices by hand before the first run, and that `resetSessions` is false on
every step including the first, so the campaign starts warm. The results are
consistent with this (sessions were 7 on every phone at peak and at the end,
and `minSessionsToLaunch: 7` gated the launch) — but I want it confirmed as
something that was done, not inferred from the output.

**4. What is the one missing Bluetooth marker?** The write-up notes `bt-on`
is 167 against `bt-off` 160 plus 8 starts, so one phone is one marker short.
Was there an incident behind that — a phone restarted, a stack bounced, an
app relaunched mid-campaign — or is it a logging artefact? If a device was
touched during the run, that belongs in the methodology.

**5. Was anything done to the phones between arms or between runs?** The
harness handles resets, but I want to know about human intervention: phones
moved, screens woken, anything restarted, any pause between the moderate,
saturating and hold arms.

---

## What I already have, so you needn't restate it

**The run.** Finished 2026-09-10 22:53 UTC, 2 h 42 min, 8,501,011 records.
Eight phones: four Nexus 5X (`72440e8a`, `07e47335`, `44a266c4`, `18130c0f`),
two Pixel 10 Pro (`366dca50`, `a2b11ef1`), a Galaxy S10e (`929a022c`), a
Huawei HMA-L09 (`be3a5ef5`). All 30 steps fired on all 8 phones.

**The structure**, from `linkChurn()` in
`lib/src/testbed/field_plan_presets.dart`: N = 8 throughout, three arms of ten
runs — moderate (60 s dwell, fixed load), saturating (60 s dwell, offering as
much as each radio took), hold (600 s dwell, no in-run resets). Payload 138 B.
Offered load 100 messages per peer per 60 s of dwell, scaled with the dwell,
so the per-second rate is the same in all three arms. `resetLinks` true on the
two 60 s arms and false on the hold arm; `resetSessions` false everywhere;
`resetDtnBuffer` at each arm's first run only; `drainSec` 60,
`linkResetDarkSec` 10, `resetBudgetSec` 15, `alignSec` 300,
`placementSec` 120, `manualJoin` true, `minSessionsToLaunch` 7.

**The results.** Concurrent links, outage durations by arm and class, bytes on
air per radio and per link by degree, churn hazard by degree, arrival and
custody exits — all in `docs/churn-n8-1-results.md`, and I have been through
them in detail. Two notes so you know where that document stands: Results 4
and 5 were briefly retracted on 11 September over the `firstOfArm` DTN buffer
purge and **un-retracted on 12 September** — Dan settled that each arm is its
own experiment, so the arm-boundary reset is correct and those results stand
as within-arm measurements. Result 7's per-link hazard by degree carries a
load confound documented in the same file. Neither affects what I am asking
you here.

## What I will do with the answers

Write them into one methodology paragraph of the Evaluation chapter, in the
same register as the line and clique subsections. If the answer to any of
these is "we didn't record that," say so plainly and I will write the
subsection without it rather than around it.
