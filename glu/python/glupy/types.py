import ctypes
from dataclasses import dataclass
from enum import IntEnum
from typing import ClassVar, Type


class Tos(IntEnum):
    RELIABLE = 0
    BEST_EFFORT = 1


class _ConfigToC:
    C_CLS: ClassVar[Type[ctypes.Structure]]

    def to_c(self) -> ctypes.Structure:
        c_struct = self.C_CLS()
        for entry in self.C_CLS._fields_:
            setattr(c_struct, entry[0], getattr(self, entry[0]))
        return c_struct


class GluTcpConfig(ctypes.Structure):
    _fields_ = [
        ("nodelay", ctypes.c_bool),
        ("quickack", ctypes.c_bool),
        ("keepalive", ctypes.c_bool),
        ("keepalive_idle", ctypes.c_uint32),
        ("keepalive_interval", ctypes.c_uint32),
        ("keepalive_count", ctypes.c_uint32),
        ("recv_buf", ctypes.c_int32),
        ("send_buf", ctypes.c_int32),
        ("defer_accept", ctypes.c_bool),
        ("connect_timeout_ms", ctypes.c_uint32),
        ("recv_timeout_ms", ctypes.c_int32),
        ("send_timeout_ms", ctypes.c_int32),
    ]


class GluUdpSocketConfig(ctypes.Structure):
    _fields_ = [
        ("recv_buf", ctypes.c_int32),
        ("send_buf", ctypes.c_int32),
        ("broadcast", ctypes.c_bool),
        ("reuse_addr", ctypes.c_bool),
        ("recv_timeout_ms", ctypes.c_int32),
        ("send_timeout_ms", ctypes.c_int32),
    ]


class GluEndpoint(ctypes.Structure):
    _fields_ = [
        ("host", ctypes.c_char * 46),
        ("host_len", ctypes.c_uint32),
        ("port", ctypes.c_uint16),
        ("_pad", ctypes.c_uint16),
    ]


@dataclass
class Endpoint:
    host: str
    port: int

    @classmethod
    def from_c(cls, c_endpoint: GluEndpoint) -> "Endpoint":
        return cls(
            host=c_endpoint.host[: c_endpoint.host_len].decode("utf-8"), port=c_endpoint.port
        )


@dataclass
class TcpConfig(_ConfigToC):
    C_CLS = GluTcpConfig

    nodelay: bool = True
    quickack: bool = True
    keepalive: bool = False
    keepalive_idle: int = 7200
    keepalive_interval: int = 75
    keepalive_count: int = 9
    recv_buf: int = -1
    send_buf: int = -1
    defer_accept: bool = False
    connect_timeout_ms: int = 5000
    recv_timeout_ms: int = -1
    send_timeout_ms: int = -1


@dataclass
class UdpSocketConfig(_ConfigToC):
    C_CLS = GluUdpSocketConfig

    recv_buf: int = -1
    send_buf: int = -1
    broadcast: bool = False
    reuse_addr: bool = False
    recv_timeout_ms: int = -1
    send_timeout_ms: int = -1
