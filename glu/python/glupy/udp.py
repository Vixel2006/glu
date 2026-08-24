import ctypes
from typing import Optional, Tuple, Union

from ._lib import _Handle, get_lib, raise_last_error
from .types import Endpoint, GluEndpoint, UdpSocketConfig

_DEFAULT_CAPACITY = 65536


class UdpSocket(_Handle):
    """UDP socket supporting unicast, connected peers, and multicast."""

    _name = "UdpSocket"

    def __init__(
        self,
        port: int = 0,
        host: str = "0.0.0.0",
        config: Optional[UdpSocketConfig] = None,
    ):
        self._bound_port = port
        self._host = host
        self._close_fn = get_lib().glu_udp_close
        c_cfg = config.to_c() if config else None
        self._handle = get_lib().glu_udp_bind(
            port,
            host.encode("utf-8"),
            ctypes.byref(c_cfg) if c_cfg else None,
        )
        if not self._handle:
            raise_last_error(f"Failed to bind UDP socket on {host}:{port}")

    @property
    def port(self) -> int:
        return self._bound_port

    @property
    def host(self) -> str:
        return self._host

    def send_to(
        self,
        host: str,
        port: int,
        data: Union[bytes, bytearray, memoryview, str],
    ) -> int:
        self._ensure_open()
        payload = data.encode("utf-8") if isinstance(data, str) else bytes(memoryview(data))
        sent = ctypes.c_size_t(0)
        res = get_lib().glu_udp_send_to(
            self._handle,
            host.encode("utf-8"),
            port,
            payload,
            len(payload),
            ctypes.byref(sent),
        )
        if res != 0:
            raise_last_error(f"UDP send_to {host}:{port} failed")
        return sent.value

    def recv_from(self, capacity: int = _DEFAULT_CAPACITY) -> Tuple[bytes, Endpoint]:
        self._ensure_open()
        buf = (ctypes.c_char * capacity)()
        got = ctypes.c_size_t(0)
        ep = GluEndpoint()
        res = get_lib().glu_udp_receive_from(
            self._handle,
            buf,
            capacity,
            ctypes.byref(got),
            ctypes.byref(ep),
        )
        if res != 0:
            raise_last_error("UDP recv_from failed")
        return buf.raw[: got.value], Endpoint.from_c(ep)

    def connect(self, host: str, port: int) -> None:
        self._ensure_open()
        res = get_lib().glu_udp_connect(self._handle, host.encode("utf-8"), port)
        if res != 0:
            raise_last_error(f"UDP connect to {host}:{port} failed")

    def send(self, data: Union[bytes, bytearray, memoryview, str]) -> int:
        self._ensure_open()
        payload = data.encode("utf-8") if isinstance(data, str) else bytes(memoryview(data))
        sent = ctypes.c_size_t(0)
        res = get_lib().glu_udp_send(
            self._handle,
            payload,
            len(payload),
            ctypes.byref(sent),
        )
        if res != 0:
            raise_last_error("UDP send failed")
        return sent.value

    def recv(self, capacity: int = _DEFAULT_CAPACITY) -> bytes:
        self._ensure_open()
        buf = (ctypes.c_char * capacity)()
        got = ctypes.c_size_t(0)
        res = get_lib().glu_udp_receive(
            self._handle,
            buf,
            capacity,
            ctypes.byref(got),
        )
        if res != 0:
            raise_last_error("UDP recv failed")
        return buf.raw[: got.value]

    def join_multicast(self, group: str, port: int, interface: str = "0.0.0.0") -> None:
        self._ensure_open()
        get_lib().glu_udp_join_multicast(
            self._handle,
            group.encode("utf-8"),
            port,
            interface.encode("utf-8"),
        )
