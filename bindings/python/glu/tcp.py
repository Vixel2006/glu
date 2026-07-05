import ctypes

from ._bindings import (
    _lib,
    glu_tcp_listener_t,
    glu_tcp_connection_t,
    _check,
)


class TcpConnection:
    def __init__(self, handle: glu_tcp_connection_t | None = None):
        self._handle = handle

    @classmethod
    def connect(cls, host: str, port: int) -> "TcpConnection":
        out = glu_tcp_connection_t()
        _check(_lib.glu_tcp_connect(host.encode(), port, ctypes.byref(out)))
        return cls(out)

    def close(self) -> None:
        if self._handle:
            _lib.glu_tcp_connection_deinit(self._handle)
            self._handle = None

    def __del__(self) -> None:
        self.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def send(self, data: bytes | bytearray) -> int:
        buf = bytes(data)
        rc = _lib.glu_tcp_send(self._handle, buf, len(buf))
        if rc < 0:
            _check(rc)
        return rc

    def receive(self, size: int = 4096) -> bytes:
        buf = ctypes.create_string_buffer(size)
        rc = _lib.glu_tcp_receive(self._handle, buf, size)
        if rc < 0:
            _check(rc)
        return buf.raw[:rc]

    def set_blocking(self, blocking: bool) -> None:
        _check(_lib.glu_tcp_set_blocking(self._handle, int(blocking)))

    @property
    def handle(self):
        return self._handle


class TcpListener:
    def __init__(self, port: int):
        self._handle = glu_tcp_listener_t()
        _check(_lib.glu_tcp_listen(port, ctypes.byref(self._handle)))

    def close(self) -> None:
        if self._handle:
            _lib.glu_tcp_listener_deinit(self._handle)
            self._handle = None

    def __del__(self) -> None:
        self.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def accept(self) -> TcpConnection:
        out = glu_tcp_connection_t()
        _check(_lib.glu_tcp_accept(self._handle, ctypes.byref(out)))
        return TcpConnection(out)

    @property
    def port(self) -> int:
        return _lib.glu_tcp_listener_port(self._handle)

    @property
    def handle(self):
        return self._handle
