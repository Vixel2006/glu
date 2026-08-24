"""Integration tests for multicast Peer sessions. Require libglu.so."""

from __future__ import annotations

import uuid
from dataclasses import dataclass

import glupy
import pytest

pytestmark = pytest.mark.integration


@dataclass
class Telemetry:
    seq: glupy.u32
    timestamp: glupy.i64
    temperature: glupy.f32
    voltage: glupy.f32
    active: glupy.bool_


@pytest.fixture
def session() -> str:
    """Unique multicast session name."""
    return f"glupy_test_peer_{uuid.uuid4().hex[:12]}"


def test_peer_dataclass_roundtrip(session):
    msg = Telemetry(seq=101, timestamp=555, temperature=36.6, voltage=11.1, active=True)
    with glupy.Peer(session, Telemetry, capacity=4, tos=glupy.Tos.BEST_EFFORT) as peer:
        peer.send(msg)
        received = peer.recv_as()
        assert received.seq == 101
        assert received.timestamp == 555
        assert received.temperature == pytest.approx(36.6, abs=1e-4)
        assert received.voltage == pytest.approx(11.1, abs=1e-4)
        assert received.active is True


def test_peer_explicit_target_type(session):
    msg = Telemetry(seq=7, timestamp=9, temperature=1.0, voltage=2.0, active=False)
    with glupy.Peer(session, glupy.sizeof(Telemetry), capacity=4) as peer:
        peer.send(msg)
        # Raw-size peer; decode by passing the type explicitly.
        raw = peer.recv()
        assert len(raw) == glupy.sizeof(Telemetry)
        decoded = glupy.get_codec(Telemetry).unpack_from_buffer(raw)
        assert decoded == msg


def test_peer_recv_into(session):
    payload = b"datagram-bytes"
    with glupy.Peer(session, len(payload), capacity=4) as peer:
        peer.send(payload)
        buf = bytearray(len(payload))
        n = peer.recv_into(buf)
        assert n == len(payload)
        assert bytes(buf) == payload


def test_peer_closed_raises(session):
    peer = glupy.Peer(session, 16, capacity=4)
    peer.close()
    with pytest.raises(glupy.GluClosedError):
        peer.send(b"x")
    peer.close()  # idempotent
