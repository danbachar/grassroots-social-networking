"""Every link stage must declare whether it counts legs or peers.

The app emits four stages per GATT leg and three per peer. A converged
dual-role pair therefore produces two `connected` events and one `session`,
so any ratio across that boundary tops out at 50%. A run was published
reading exactly that 42% as a transport failure; this test keeps the
distinction from being dropped again when a stage is added.
"""
from analyze import LINK_STAGES, LINK_STAGE_COUNTS


def test_every_stage_declares_what_it_counts():
    assert set(LINK_STAGE_COUNTS) == set(LINK_STAGES)
    assert set(LINK_STAGE_COUNTS.values()) <= {"leg", "peer"}


def test_the_stages_the_transport_emits_per_leg():
    # These come from _traceLink(event, path, role) — once per GATT leg.
    for stage in ("gattConnected", "identified", "connected", "drop"):
        assert LINK_STAGE_COUNTS[stage] == "leg", stage


def test_the_stages_the_mesh_emits_per_peer():
    # A session and its first ACK belong to the peer, not to a leg.
    for stage in ("discovered", "session", "usable"):
        assert LINK_STAGE_COUNTS[stage] == "peer", stage


def test_order_is_the_establishment_ladder():
    assert LINK_STAGES == ["discovered", "gattConnected", "identified",
                           "connected", "session", "usable", "drop"]
