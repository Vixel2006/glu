import ctypes

from ._bindings import (
    _lib,
    glu_udp_socket_t,
    glu_udp_endpoint_t,
    _check,
)


class UdpSocket:
    def __init__(self, port: int):
        self._handle = glu_udp_socket_t()
        _check(_lib.glu_udp_bind(port, ctypes.byref(self._handle)))

    def close(self) -> None:
        if self._handle:
            _lib.glu_udp_deinit(self._handle)
            self._handle = None

    def __del__(self) -> None:
        self.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def send_to(self, host: str, port: int, data: bytes | bytearray) -> int:
        buf = bytes(data)
        rc = _lib.glu_udp_send_to(self._handle, host.encode(), port, buf, len(buf))
        if rc < 0:
            _check(rc)
        return rc

    def receive_from(self, size: int = 65536) -> tuple[bytes, str, int]:
        buf = ctypes.create_string_buffer(size)
        out_bytes = ctypes.c_uint32()
        endpoint = glu_udp_endpoint_t()
        rc = _lib.glu_udp_receive_from(
            self._handle, buf, size,
            ctypes.byref(out_bytes),
            ctypes.byref(endpoint),
        )
        if rc < 0:
            _check(rc)
        host_len = min(endpoint.host_len, 45)
        host = endpoint.host[:host_len].decode("utf-8", errors="replace")
        return buf.raw[:out_bytes.value], host, endpoint.port

    def set_blocking(self, blocking: bool) -> None:
        _check(_lib.glu_udp_set_blocking(self._handle, int(blocking)))

    @property
    def handle(self):
        return self._handle
