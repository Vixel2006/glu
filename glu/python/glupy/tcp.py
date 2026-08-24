import ctypes
from typing import Optional, Union

from ._lib import _Handle, get_lib, raise_last_error
from .types import TcpConfig


def apply_tcp_socket_opts(fd: int, config: Optional[TcpConfig] = None) -> None:
    """Apply TCP socket options directly to an existing socket file descriptor."""
    c_cfg = config.to_c() if config else None
    res = get_lib().glu_tcp_apply_socket_opts(fd, ctypes.byref(c_cfg) if c_cfg else None)
    if res != 0:
        raise_last_error("Failed to apply TCP socket options")


class TcpStream(_Handle):
    """Connected TCP stream for sending and receiving data."""

    _name = "TcpStream"

    def __init__(self, handle: int):
        self._handle = handle
        self._close_fn = get_lib().glu_tcp_close_stream
        if not self._handle:
            raise_last_error("Invalid TcpStream handle")

    @classmethod
    def connect(cls, host: str, port: int) -> "TcpStream":
        handle = get_lib().glu_tcp_connect(host.encode("utf-8"), port)
        if not handle:
            raise_last_error(f"Failed to connect to {host}:{port}")
        return cls(handle)

    def send(self, data: Union[bytes, bytearray, memoryview, str]) -> int:
        self._ensure_open()
        payload = data.encode("utf-8") if isinstance(data, str) else bytes(memoryview(data))
        sent = ctypes.c_size_t(0)
        res = get_lib().glu_tcp_send(
            self._handle,
            payload,
            len(payload),
            ctypes.byref(sent),
        )
        if res != 0:
            raise_last_error("TCP send failed")
        return sent.value

    def recv(self, capacity: int = 65536) -> bytes:
        self._ensure_open()
        buf = (ctypes.c_char * capacity)()
        got = ctypes.c_size_t(0)
        res = get_lib().glu_tcp_receive(
            self._handle,
            buf,
            capacity,
            ctypes.byref(got),
        )
        if res != 0:
            raise_last_error("TCP recv failed")
        return buf.raw[: got.value]

    def recv_into(self, buffer: bytearray) -> int:
        self._ensure_open()
        cap = len(buffer)
        c_buf = (ctypes.c_char * cap).from_buffer(buffer)
        got = ctypes.c_size_t(0)
        res = get_lib().glu_tcp_receive(
            self._handle,
            c_buf,
            cap,
            ctypes.byref(got),
        )
        if res != 0:
            raise_last_error("TCP recv_into failed")
        return got.value


class TcpServer(_Handle):
    """TCP server listening for incoming connections."""

    _name = "TcpServer"

    def __init__(
        self,
        port: int,
        host: str = "0.0.0.0",
        config: Optional[TcpConfig] = None,
    ):
        self._port = port
        self._host = host
        self._close_fn = get_lib().glu_tcp_close_server
        c_cfg = config.to_c() if config else None
        self._handle = get_lib().glu_tcp_listen(
            port,
            host.encode("utf-8"),
            ctypes.byref(c_cfg) if c_cfg else None,
        )
        if not self._handle:
            raise_last_error(f"Failed to listen on {host}:{port}")

    @property
    def port(self) -> int:
        return self._port

    @property
    def host(self) -> str:
        return self._host

    def accept(self) -> TcpStream:
        self._ensure_open()
        out_stream = ctypes.c_void_p()
        res = get_lib().glu_tcp_accept(self._handle, ctypes.byref(out_stream))
        if res != 0 or not out_stream.value:
            raise_last_error("TCP accept failed")
        return TcpStream(out_stream.value)
