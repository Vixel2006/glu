import ctypes

from ._bindings import (
    _lib,
    glu_subscriber_t,
    _check,
)


class Subscriber:
    def __init__(self, name: str, msg_size: int, capacity: int = 64):
        self._msg_size = msg_size
        self._handle = glu_subscriber_t()
        _check(_lib.glu_subscriber_init(
            name.encode(), msg_size, capacity,
            ctypes.byref(self._handle),
        ))

    def close(self) -> None:
        if self._handle:
            _lib.glu_subscriber_deinit(self._handle)
            self._handle = None

    def __del__(self) -> None:
        self.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def receive(self) -> bytes | None:
        ptr = _lib.glu_subscriber_receive(self._handle)
        if not ptr:
            return None
        return ctypes.string_at(ptr, self._msg_size)

    @property
    def handle(self):
        return self._handle
