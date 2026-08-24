"""RSSI aggregation must reject what the radio never measured.

The discovered/conn streams emit 0 and -1 while the peer record has no real
sample yet, and the connection stream reads 8-11 dB high for the first
10-20 s after a BLE restart. Averaged into a per-step mean, the two invent
several dB of step-to-step scatter on a pair that a dense advertisement
stream shows flat to under 2 dB. One published instability figure already
came from exactly that.
"""
import pandas as pd

from analyze import CONN_RSSI_SETTLE_MS, _valid_rssi


def frame(rows):
    return pd.DataFrame(rows)


def test_sentinels_never_reach_a_mean():
    sub = frame([
        {"_t": 1000, "rssi": 0},
        {"_t": 1100, "rssi": -1},
        {"_t": 1200, "rssi": -42},
        {"_t": 1300, "rssi": -44},
    ])
    vals = _valid_rssi(sub, 0, settle=False)
    assert list(vals) == [-42, -44]


def test_conn_samples_inside_the_settle_window_are_excluded():
    t0 = 10_000
    early = t0 + CONN_RSSI_SETTLE_MS - 1   # transient, reads high
    late = t0 + CONN_RSSI_SETTLE_MS        # settled
    sub = frame([
        {"_t": early, "rssi": -18},
        {"_t": late, "rssi": -29},
        {"_t": late + 500, "rssi": -28},
    ])
    vals = _valid_rssi(sub, t0, settle=True)
    assert list(vals) == [-29, -28]


def test_adv_samples_are_never_excluded_on_time():
    # The advertisement stream has no transient; dropping its early samples
    # would only shrink n for nothing.
    sub = frame([{"_t": 0, "rssi": -40}, {"_t": 1, "rssi": -41}])
    vals = _valid_rssi(sub, 0, settle=False)
    assert len(vals) == 2


def test_empty_slice_stays_empty():
    assert _valid_rssi(pd.DataFrame(), 0, settle=True).empty


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"ok {name}")
