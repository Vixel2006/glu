import ctypes
import time
from contextlib import contextmanager
from dataclasses import is_dataclass
from typing import Any, Generator, Iterator, Optional, Type, TypeVar, Union, cast

from ._lib import _Handle, _parse_msg_spec, get_lib, raise_last_error
from .codec import Codec, get_codec
from .errors import GluTimeoutError
from .types import Tos

T = TypeVar("T")

_POLL_MIN = 5e-5
_POLL_MAX = 5e-4


def shm_unlink(topic: str) -> None:
    get_lib().glu_shm_unlink(topic.encode("utf-8"))


class Publisher(_Handle):
    """Zero-copy, shared-memory topic publisher."""

    _name = "Publisher"

    def __init__(
        self,
        topic: str,
        msg_size_or_type: Union[int, Type[Any]],
        capacity: int = 1024,
        tos: Tos = Tos.RELIABLE,
    ):
        self._topic, self._capacity, self._tos = topic, capacity, tos
        self._msg_size, self._msg_type = _parse_msg_spec(msg_size_or_type)
        self._close_fn = get_lib().glu_publisher_free
        self._handle = get_lib().glu_publisher_new(
            topic.encode("utf-8"),
            self._msg_size,
            capacity,
            int(tos),
        )
        if not self._handle:
            raise_last_error(f"Failed to create Publisher for '{topic}'")

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

    def reserve(self) -> Optional[int]:
        self._ensure_open()
        ptr = get_lib().glu_publisher_reserve(self._handle)
        return ptr if ptr else None

    def commit(self) -> None:
        self._ensure_open()
        get_lib().glu_publisher_commit(self._handle)

    def _codec_for(self, target_type: Optional[Type[Any]]) -> Codec:
        cls = target_type or self._msg_type
        if cls is None:
            raise ValueError(
                "target_type must be specified if Publisher was initialized with integer msg_size"
            )
        codec = get_codec(cls)
        if codec.size != self._msg_size:
            raise ValueError(
                f"Type size {codec.size} does not match publisher msg_size {self._msg_size}"
            )
        return codec

    @contextmanager
    def reserve_as(
        self, target_type: Optional[Type[T]] = None
    ) -> Generator[Optional[T], None, None]:
        codec = self._codec_for(target_type)
        ptr = self.reserve()
        if ptr is None:
            yield None
            return
        if not codec.is_dataclass:
            instance = cast(T, cast(Type[ctypes.Structure], codec.target_type).from_address(ptr))
            try:
                yield instance
            finally:
                self.commit()
        else:
            instance = codec.unpack_from(ptr)
            try:
                yield instance
            finally:
                codec.pack_into(ptr, instance)
                self.commit()

    def publish(self, msg: Any) -> None:
        self._ensure_open()
        lib = get_lib()
        if is_dataclass(msg) or isinstance(msg, ctypes.Structure):
            codec = get_codec(type(msg))
            if codec.size != self._msg_size:
                raise ValueError(
                    f"Message size {codec.size} does not match publisher msg_size {self._msg_size}"
                )
            ptr = lib.glu_publisher_reserve(self._handle)
            if ptr:
                codec.pack_into(ptr, msg)
                lib.glu_publisher_commit(self._handle)
                return
            res = lib.glu_publisher_publish(self._handle, ctypes.c_char_p(codec.to_bytes(msg)))
        else:
            buf = memoryview(msg)
            if len(buf) != self._msg_size:
                raise ValueError(
                    f"Buffer size {len(buf)} does not match publisher msg_size {self._msg_size}"
                )
            try:
                payload = (ctypes.c_char * self._msg_size).from_buffer(msg)
            except TypeError:
                payload = (ctypes.c_char * self._msg_size).from_buffer_copy(buf)
            res = lib.glu_publisher_publish(self._handle, payload)

        if res != 0:
            raise_last_error(f"Failed to publish to topic '{self._topic}'")


class Subscriber(_Handle):
    """Zero-copy, shared-memory topic subscriber."""

    _name = "Subscriber"

    def __init__(
        self,
        topic: str,
        msg_size_or_type: Union[int, Type[Any]],
        capacity: int = 1024,
    ):
        self._topic, self._capacity = topic, capacity
        self._msg_size, self._msg_type = _parse_msg_spec(msg_size_or_type)
        self._close_fn = get_lib().glu_subscriber_free
        self._handle = get_lib().glu_subscriber_new(
            topic.encode("utf-8"),
            self._msg_size,
            capacity,
        )
        if not self._handle:
            raise_last_error(f"Failed to create Subscriber for '{topic}'")

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

    def peek(self) -> Optional[memoryview]:
        self._ensure_open()
        ptr = get_lib().glu_subscriber_peek(self._handle)
        return memoryview((ctypes.c_char * self._msg_size).from_address(ptr)) if ptr else None

    def _codec_for(self, target_type: Optional[Type[Any]]) -> Codec:
        cls = target_type or self._msg_type
        if cls is None:
            raise ValueError(
                "target_type must be specified if Subscriber was initialized with integer msg_size"
            )
        codec = get_codec(cls)
        if codec.size != self._msg_size:
            raise ValueError(
                f"Type size {codec.size} does not match subscriber msg_size {self._msg_size}"
            )
        return codec

    def peek_as(self, target_type: Optional[Type[T]] = None) -> Optional[T]:
        self._ensure_open()
        codec = self._codec_for(target_type)
        ptr = get_lib().glu_subscriber_peek(self._handle)
        return cast(T, codec.unpack_from(ptr)) if ptr else None

    def ack(self) -> None:
        self._ensure_open()
        get_lib().glu_subscriber_ack(self._handle)

    def _poll_read(self, fetch_fn: Any, timeout: Optional[float]) -> Any:
        deadline = None if timeout is None else time.monotonic() + timeout
        delay = _POLL_MIN
        while True:
            msg = fetch_fn()
            if msg is not None:
                return msg
            if deadline is not None and time.monotonic() >= deadline:
                raise GluTimeoutError(f"No message on topic '{self._topic}' within {timeout}s")
            time.sleep(delay if deadline is None else min(delay, deadline - time.monotonic()))
            delay = min(_POLL_MAX, delay * 2)

    def read(self, timeout: Optional[float] = None) -> Any:
        return self._poll_read(self._read_once, timeout)

    def read_as(self, target_type: Optional[Type[T]] = None, timeout: Optional[float] = None) -> T:
        codec = self._codec_for(target_type)
        return self._poll_read(lambda: self._read_once_as(codec), timeout)

    def _read_once(self) -> Optional[Any]:
        if self._msg_type is not None:
            return self._read_once_as(get_codec(self._msg_type))
        view = self.peek()
        if view is None:
            return None
        data = bytes(view)
        self.ack()
        return data

    def _read_once_as(self, codec: Codec) -> Optional[Any]:
        self._ensure_open()
        ptr = get_lib().glu_subscriber_peek(self._handle)
        if not ptr:
            return None
        instance = codec.unpack_from(ptr)
        self.ack()
        return instance

    def __iter__(self) -> Iterator[Any]:
        return self

    def __next__(self) -> Any:
        self._ensure_open()
        return self.read()
