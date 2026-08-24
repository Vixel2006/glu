import ctypes
from dataclasses import is_dataclass
from typing import Any, Optional, Type, TypeVar, Union, cast

from ._lib import _Handle, _parse_msg_spec, get_lib, raise_last_error
from .codec import get_codec
from .types import Tos

T = TypeVar("T")


class Peer(_Handle):
    """Multicast network session peer sending fixed-size datagrams."""

    _name = "Peer"

    def __init__(
        self,
        topic: str,
        msg_size_or_type: Union[int, Type[Any]],
        capacity: int = 1024,
        tos: Tos = Tos.RELIABLE,
    ):
        self._topic, self._capacity, self._tos = topic, capacity, tos
        self._msg_size, self._msg_type = _parse_msg_spec(msg_size_or_type)
        self._close_fn = get_lib().glu_peer_free
        self._handle = get_lib().glu_peer_new(
            topic.encode("utf-8"),
            self._msg_size,
            capacity,
            int(tos),
        )
        if not self._handle:
            raise_last_error(f"Failed to create Peer for '{topic}'")

    @property
    def topic(self) -> str:
        return self._topic

    @property
    def msg_size(self) -> int:
        return self._msg_size

    @property
    def msg_type(self) -> Optional[Type[Any]]:
        return self._msg_type

    @property
    def capacity(self) -> int:
        return self._capacity

    @property
    def tos(self) -> Tos:
        return self._tos

    def send(self, data: Any) -> None:
        self._ensure_open()
        if is_dataclass(data) or isinstance(data, ctypes.Structure):
            payload = get_codec(type(data)).to_bytes(data)
        elif isinstance(data, str):
            payload = data.encode("utf-8")
        else:
            payload = bytes(memoryview(data))

        if get_lib().glu_peer_send(self._handle, payload, len(payload)) != 0:
            raise_last_error(f"Peer send failed on topic '{self._topic}'")

    def recv(self, capacity: Optional[int] = None) -> bytes:
        self._ensure_open()
        cap = capacity if capacity is not None else self._msg_size
        buf = (ctypes.c_char * cap)()
        out_len = ctypes.c_size_t(0)
        if get_lib().glu_peer_recv(self._handle, buf, cap, ctypes.byref(out_len)) != 0:
            raise_last_error(f"Peer recv failed on topic '{self._topic}'")
        return buf.raw[: out_len.value]

    def recv_as(self, target_type: Optional[Type[T]] = None) -> T:
        cls = target_type or self._msg_type
        if cls is None:
            raise ValueError(
                "target_type must be specified if Peer was initialized with integer msg_size"
            )
        codec = get_codec(cls)
        return cast(T, codec.unpack_from_buffer(self.recv(codec.size)))

    def recv_into(self, buffer: bytearray) -> int:
        self._ensure_open()
        cap = len(buffer)
        c_buf = (ctypes.c_char * cap).from_buffer(buffer)
        out_len = ctypes.c_size_t(0)
        if get_lib().glu_peer_recv(self._handle, c_buf, cap, ctypes.byref(out_len)) != 0:
            raise_last_error(f"Peer recv_into failed on topic '{self._topic}'")
        return out_len.value
