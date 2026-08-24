"""Integration tests for shared-memory pub/sub. Require libglu.so."""

from __future__ import annotations

import ctypes
import threading
from dataclasses import dataclass

import glupy
import pytest

pytestmark = pytest.mark.integration


@dataclass
class Pose:
    x: float
    y: float
    z: float
    yaw: float


@dataclass
class Telemetry:
    seq: glupy.u32
    timestamp: glupy.i64
    temperature: glupy.f32
    voltage: glupy.f32
    active: glupy.bool_


@dataclass
class Wheel:
    id: glupy.u32
    rpm: glupy.f32


@dataclass
class Chassis:
    seq: glupy.u32
    front_left: Wheel
    front_right: Wheel


class PointMsg(ctypes.Structure):
    _fields_ = [
        ("x", ctypes.c_float),
        ("y", ctypes.c_float),
        ("z", ctypes.c_float),
        ("seq", ctypes.c_uint32),
    ]


def test_pubsub_dataclass_basic(topic):
    with (
        glupy.Publisher(topic, Pose, capacity=8) as pub,
        glupy.Subscriber(topic, Pose, capacity=8) as sub,
    ):
        assert pub.msg_size == glupy.sizeof(Pose)
        pub.publish(Pose(x=10.5, y=20.25, z=30.125, yaw=1.57))
        pose = sub.read(timeout=2.0)

        assert isinstance(pose, Pose)
        assert pose.x == pytest.approx(10.5)
        assert pose.y == pytest.approx(20.25)
        assert pose.z == pytest.approx(30.125)
        assert pose.yaw == pytest.approx(1.57)


def test_pubsub_nested_dataclass(topic):
    msg = Chassis(seq=3, front_left=Wheel(0, 120.5), front_right=Wheel(1, 118.25))
    with (
        glupy.Publisher(topic, Chassis, capacity=8) as pub,
        glupy.Subscriber(topic, Chassis, capacity=8) as sub,
    ):
        pub.publish(msg)
        decoded = sub.read(timeout=2.0)
        assert decoded.seq == 3
        assert decoded.front_left.id == 0
        assert decoded.front_left.rpm == pytest.approx(120.5)
        assert decoded.front_right.id == 1
        assert decoded.front_right.rpm == pytest.approx(118.25)


def test_pubsub_typed_reserve_as(topic):
    with (
        glupy.Publisher(topic, Telemetry, capacity=8) as pub,
        glupy.Subscriber(topic, Telemetry, capacity=8) as sub,
    ):
        with pub.reserve_as() as slot:
            assert slot is not None
            slot.seq = 77
            slot.timestamp = 987654321
            slot.temperature = 42.5
            slot.voltage = 12.6
            slot.active = True

        data = sub.read(timeout=2.0)
        assert data.seq == 77
        assert data.timestamp == 987654321
        assert data.temperature == pytest.approx(42.5)
        assert data.voltage == pytest.approx(12.6, abs=1e-4)
        assert data.active is True


def test_pubsub_bytes_peek_ack(topic):
    payload = b"0123456789ABCDEF"
    with (
        glupy.Publisher(topic, len(payload), 8) as pub,
        glupy.Subscriber(topic, len(payload), 8) as sub,
    ):
        pub.publish(payload)

        peeked = sub.peek()
        assert peeked is not None
        assert bytes(peeked) == payload
        sub.ack()

        # Ring drained after ack.
        assert sub.peek() is None


def test_pubsub_struct_zero_copy(topic):
    msg_size = ctypes.sizeof(PointMsg)
    with glupy.Publisher(topic, msg_size, 8) as pub, glupy.Subscriber(topic, msg_size, 8) as sub:
        with pub.reserve_as(PointMsg) as slot:
            slot.x = 1.0
            slot.y = 2.0
            slot.z = 3.0
            slot.seq = 42

        msg = sub.read_as(PointMsg, timeout=2.0)
        assert msg.seq == 42
        assert msg.x == pytest.approx(1.0)
        assert msg.y == pytest.approx(2.0)
        assert msg.z == pytest.approx(3.0)


def test_read_timeout_raises(topic):
    with (
        glupy.Publisher(topic, 16, 4),
        glupy.Subscriber(topic, 16, 4) as sub,
        pytest.raises(glupy.GluTimeoutError),
    ):
        sub.read(timeout=0.05)


def test_iterator_yields_published_messages(topic):
    with (
        glupy.Publisher(topic, Pose, capacity=8) as pub,
        glupy.Subscriber(topic, Pose, capacity=8) as sub,
    ):

        def publish_later():
            pub.publish(Pose(x=1.0, y=2.0, z=3.0, yaw=0.0))

        timer = threading.Timer(0.05, publish_later)
        timer.start()
        received = next(iter(sub))
        timer.join()
        assert received.x == pytest.approx(1.0)


def test_closed_publisher_raises(topic):
    pub = glupy.Publisher(topic, 8, 4)
    pub.close()

    with pytest.raises(glupy.GluClosedError):
        pub.publish(b"12345678")

    # close() is idempotent.
    pub.close()


def test_type_size_mismatch_raises(topic):
    class WrongSize(ctypes.Structure):
        _fields_ = [("val", ctypes.c_uint32)]

    with glupy.Publisher(topic, 16, 4) as pub:  # noqa: SIM117
        with pytest.raises(ValueError, match="msg_size"), pub.reserve_as(WrongSize):
            pass


def test_publish_wrong_buffer_size_raises(topic):
    with glupy.Publisher(topic, 16, 4) as pub, pytest.raises(ValueError, match="Buffer size"):
        pub.publish(b"too short")


def test_read_after_subscriber_close_raises(topic):
    with glupy.Publisher(topic, 16, 4):
        sub = glupy.Subscriber(topic, 16, 4)
        sub.close()
        with pytest.raises(glupy.GluClosedError):
            sub.read(timeout=0.01)
