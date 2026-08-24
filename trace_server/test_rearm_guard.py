#!/usr/bin/env python3
"""Checks for `analyze._drop_pre_arm` — the re-arm guard.

    python3 trace_server/test_rearm_guard.py

Plain asserts and a __main__, deliberately: the analysis chain has no test
runner and adding pytest for one module would be more machinery than the code
it guards. Run it after touching the guard.

Every case here is a scenario that was WRONG at some point, not a hypothetical:
a first arm that ran and was aborted (field day 2026-08-08), a completed run
followed by a stray arm (the guard used to delete the completed run), and a
peer holding `recv` rows for ids the abandoned arm minted (message ids carry
no per-run term, so both arms mint the same ones).
"""
from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import analyze  # noqa: E402


def rec(dev: str, t: int, ty: str, **kw):
    row = {"_device": dev, "_t": t, "_type": ty, "_exp": "x"}
    row.update(kw)
    return row


def check(name: str, rows: list[dict], expect_kept: list[int]) -> bool:
    kept = sorted(analyze._drop_pre_arm(pd.DataFrame(rows))._t.tolist())
    ok = kept == sorted(expect_kept)
    print(f"{'PASS' if ok else 'FAIL'}  {name}")
    if not ok:
        print(f"      kept={kept}\n      want={sorted(expect_kept)}")
    return ok


def main() -> int:
    ok = True

    # The field-day case. The abandoned arm ran and was aborted; the real run
    # follows and ends. t=55 goes too: the real run re-minted the dead arm's
    # id, so the receiver's bloom had already seen it and it never delivered.
    ok &= check("aborted arm then real run -> keep the real run", [
        rec("A", 10, "marker", label="placement"),
        rec("A", 20, "marker", label="n=3 t1"),
        rec("A", 25, "message", messageId="m1", dir="sent"),
        rec("A", 30, "marker", label="aborted"),
        rec("A", 40, "marker", label="placement"),
        rec("A", 50, "marker", label="n=3 t1"),
        rec("A", 55, "message", messageId="m1", dir="sent"),
        rec("A", 90, "marker", label="end"),
    ], [40, 50, 90])

    # A COMPLETED run followed by a stray arm that measured nothing. Flooring
    # at the last `placement` deleted the completed run and left its peers'
    # deliveries in place — a mutilated rep, worse than a dropped one.
    ok &= check("complete run then stray aborted arm -> keep the complete run", [
        rec("A", 10, "marker", label="placement"),
        rec("A", 20, "marker", label="n=3 t1"),
        rec("A", 25, "message", messageId="m1", dir="sent"),
        rec("A", 30, "marker", label="end"),
        rec("A", 600, "marker", label="placement"),
        rec("A", 610, "marker", label="aborted"),
    ], [10, 20, 25, 30])

    # A per-device cut leaves the PEER's view of the abandoned arm behind, and
    # that row joins the real run's later send for the same id — which prints
    # a negative latency and a false "every latency is biased LOW" verdict.
    ok &= check("peer recv of an abandoned-arm id is dropped too", [
        rec("A", 10, "marker", label="placement"),
        rec("A", 25, "message", messageId="m9", dir="sent"),
        rec("B", 26, "message", messageId="m9", dir="recv"),
        rec("A", 30, "marker", label="aborted"),
        rec("A", 40, "marker", label="placement"),
        rec("A", 90, "marker", label="end"),
        rec("B", 95, "message", messageId="ok", dir="recv"),
    ], [40, 90, 95])

    # Two COMPLETE runs under one experiment id. The later one survives, and
    # its traffic must NOT be tainted by the earlier one: message ids carry no
    # per-run term, so both runs mint the same ids. Tainting deleted 65k
    # records of the surviving run on 2026-08-10 before this was caught.
    ok &= check("a completed earlier run does not taint the surviving run", [
        rec("A", 10, "marker", label="placement"),
        rec("A", 20, "message", messageId="shared", dir="sent"),
        rec("A", 30, "marker", label="end"),
        rec("A", 100, "marker", label="placement"),
        rec("A", 110, "message", messageId="shared", dir="sent"),
        rec("B", 111, "message", messageId="shared", dir="recv"),
        rec("A", 120, "marker", label="end"),
    ], [100, 110, 111, 120])

    ok &= check("single arm is a no-op", [
        rec("A", 10, "marker", label="placement"),
        rec("A", 25, "message", messageId="m1", dir="sent"),
        rec("A", 90, "marker", label="end"),
    ], [10, 25, 90])

    # Without marker rows the guard cannot see an arm at all. It must say so:
    # a silent pass-through reads the abandoned arm as part of the run.
    ok &= check("no markers -> untouched (warns)", [
        rec("A", 25, "message", messageId="m1", dir="sent"),
    ], [25])

    print("ALL PASS" if ok else "FAILURES")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
