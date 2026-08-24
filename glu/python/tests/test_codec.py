"""Unit tests for the codec layer.

These are pure-Python tests and do NOT require libglu.so. The module uses
``from __future__ import annotations`` deliberately, so every dataclass here
exercises the string-annotation (PEP 563) resolution path.
"""

from __future__ import annotations

import ctypes
from dataclasses import dataclass

import glupy
import pytest
from glupy.codec import Codec, get_codec, sizeof


@dataclass
class Inner:
    a: glupy.u32
    b: glupy.f32


@dataclass
class Outer:
    seq: glupy.u32
    inner: Inner
    flag: glupy.bool_


@dataclass
class NativeTypes:
    count: int  # implicitly i64
    ratio: float  # implicitly f64
    enabled: bool  # implicitly c_bool


@dataclass
class WithArray:
    vals: ctypes.c_float * 3


def test_sizeof_dataclass():
    assert sizeof(Inner) == ctypes.sizeof(glupy.u32) + ctypes.sizeof(glupy.f32)
    # i64(8) + f64(8) + c_bool(1), tail-padded to 8-byte alignment.
    assert sizeof(NativeTypes) == 24


def test_sizeof_instance_and_buffer():
    inner = Inner(a=1, b=2.0)
    assert sizeof(inner) == sizeof(Inner)
    assert sizeof(b"1234") == 4


def test_sizeof_rejects_unknown():
    with pytest.raises(TypeError):
        sizeof(object())


def test_explicit_types_roundtrip():
    @dataclass
    class Msg:
        seq: glupy.u32
        ts: glupy.i64
        temp: glupy.f32
        active: glupy.bool_

    msg = Msg(seq=42, ts=987654321, temp=1.5, active=True)
    decoded = get_codec(Msg).unpack_from_buffer(get_codec(Msg).to_bytes(msg))
    assert decoded == msg


def test_native_type_mapping():
    codec = get_codec(NativeTypes)
    assert codec.ctypes_cls.count.size == 8  # int -> i64
    assert codec.ctypes_cls.ratio.size == 8  # float -> f64
    msg = NativeTypes(count=-5, ratio=0.25, enabled=True)
    decoded = codec.unpack_from_buffer(codec.to_bytes(msg))
    assert decoded == msg


def test_nested_dataclass_roundtrip():
    outer = Outer(seq=7, inner=Inner(a=3, b=1.5), flag=True)
    codec = get_codec(Outer)
    raw = codec.to_bytes(outer)

    # The nested struct is embedded at its natural field offset.
    offset = codec.ctypes_cls.inner.offset
    assert raw[offset : offset + codec.ctypes_cls.inner.size] == get_codec(Inner).to_bytes(
        outer.inner
    )

    decoded = codec.unpack_from_buffer(raw)
    assert decoded.seq == 7
    assert decoded.inner.a == 3
    assert decoded.inner.b == 1.5
    assert decoded.flag is True


def test_nested_dataclass_pack_into():
    codec = get_codec(Outer)
    buf = bytearray(codec.size)
    address = ctypes.addressof((ctypes.c_char * len(buf)).from_buffer(buf))
    outer = Outer(seq=9, inner=Inner(a=11, b=0.5), flag=False)
    codec.pack_into(address, outer)
    decoded = codec.unpack_from(address)
    assert decoded == outer


def test_array_field_roundtrip():
    msg = WithArray(vals=(ctypes.c_float * 3)(1.0, 2.0, 3.0))
    codec = get_codec(WithArray)
    decoded = codec.unpack_from_buffer(codec.to_bytes(msg))
    assert list(decoded.vals) == [1.0, 2.0, 3.0]


def test_ctypes_struct_passthrough():
    class Point(ctypes.Structure):
        _fields_ = [("x", ctypes.c_float), ("y", ctypes.c_float)]

    codec = get_codec(Point)
    assert codec.is_dataclass is False
    assert codec.ctypes_cls is Point

    buf = bytearray(codec.size)
    address = ctypes.addressof((ctypes.c_char * len(buf)).from_buffer(buf))
    codec.pack_into(address, Point(1.5, -2.5))
    out = Point.from_address(address)
    assert out.x == 1.5
    assert out.y == -2.5


def test_unsupported_annotation_names_field():
    @dataclass
    class Bad:
        name: str

    with pytest.raises(TypeError, match=r"Bad\.name"):
        Codec(Bad)


def test_unsupported_message_type():
    with pytest.raises(TypeError):
        Codec(int)


def test_codec_cache_identity():
    assert get_codec(Outer) is get_codec(Outer)


def test_pack_into_truncates_short_raw_buffers():
    class Fixed(ctypes.Structure):
        _fields_ = [("a", ctypes.c_uint32), ("b", ctypes.c_uint32)]

    buf = bytearray(ctypes.sizeof(Fixed))
    address = ctypes.addressof((ctypes.c_char * len(buf)).from_buffer(buf))
    get_codec(Fixed).pack_into(address, b"\x01\x00\x00\x00")
    assert buf[0] == 1
    assert buf[4] == 0
