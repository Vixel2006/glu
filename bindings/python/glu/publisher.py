import ctypes

from ._bindings import (
    _lib,
    glu_publisher_t,
    _check,
    GluError,
    GLU_ERR_NO_SPACE,
)


class Publisher:
    def __init__(self, name: str, msg_size: int, capacity: int = 64):
        self._msg_size = msg_size
        self._handle = glu_publisher_t()
        _check(_lib.glu_publisher_init(
            name.encode(), msg_size, capacity,
            ctypes.byref(self._handle),
        ))

    def close(self) -> None:
        if self._handle:
            _lib.glu_publisher_deinit(self._handle)
            self._handle = None

    def __del__(self) -> None:
        self.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def publish(self, data: bytes | ctypes.Structure) -> None:
        if isinstance(data, ctypes.Structure):
            buf = ctypes.string_at(ctypes.addressof(data), ctypes.sizeof(data))
        elif isinstance(data, (bytes, bytearray)):
            buf = bytes(data)
        else:
            buf = bytes(data)
        _lib.glu_publisher_publish(self._handle, buf, len(buf))

    def reserve(self) -> int:
        ptr = _lib.glu_publisher_reserve(self._handle)
        if not ptr:
            raise GluError(GLU_ERR_NO_SPACE)
        return ptr

    def commit(self) -> None:
        _lib.glu_publisher_commit(self._handle)

    @property
    def handle(self):
        return self._handle
