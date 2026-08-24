import contextlib
import ctypes
import os
from pathlib import Path
from typing import Any, NoReturn, Optional, Tuple, Type, Union

from .errors import GluClosedError, GluError, GluLoadError
from .types import GluEndpoint, GluTcpConfig, GluUdpSocketConfig

_LIB: Optional[ctypes.CDLL] = None


class _Handle:
    _handle: Optional[int] = None
    _close_fn: Any = None
    _name: str = ""

    def _ensure_open(self) -> None:
        if not getattr(self, "_handle", None):
            raise GluClosedError(f"{self._name or self.__class__.__name__} is closed")

    def close(self) -> None:
        if getattr(self, "_handle", None):
            if self._close_fn:
                self._close_fn(self._handle)
            self._handle = None

    def __enter__(self) -> Any:
        return self

    def __exit__(self, *args: Any) -> None:
        self.close()

    def __del__(self) -> None:
        with contextlib.suppress(Exception):
            self.close()


def _parse_msg_spec(msg_size_or_type: Union[int, Type[Any]]) -> Tuple[int, Optional[Type[Any]]]:
    if isinstance(msg_size_or_type, int):
        return msg_size_or_type, None
    from .codec import sizeof

    return sizeof(msg_size_or_type), msg_size_or_type


def _find_libglu() -> Optional[Path]:
    pkg_dir = Path(__file__).resolve().parent
    candidates = [
        os.environ.get("GLU_LIB_PATH"),
        pkg_dir / "libglu.so",
        pkg_dir / "lib" / "libglu.so",
        pkg_dir.parents[2] / "zig-out" / "lib" / "libglu.so",
    ]
    for p in candidates:
        if p and Path(p).exists():
            return Path(p)
    return None


def get_lib() -> ctypes.CDLL:
    global _LIB
    if _LIB is None:
        path = _find_libglu()
        if path is None:
            try:
                _LIB = ctypes.CDLL("libglu.so")
            except OSError as e:
                raise GluLoadError(
                    "Could not find libglu.so. Build it with 'zig build' from "
                    "a repository checkout, set GLU_LIB_PATH=/path/to/libglu.so, "
                    "or install it system-wide."
                ) from e
        else:
            try:
                _LIB = ctypes.CDLL(str(path))
            except OSError as e:
                raise GluLoadError(f"Failed to load {path}: {e}") from e
        _configure_prototypes(_LIB)
    return _LIB


def _configure_prototypes(lib: ctypes.CDLL) -> None:
    vp, cp, u16, u32, sz, psz = (
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_uint16,
        ctypes.c_uint32,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_size_t),
    )
    p_tcp, p_udp, p_ep, p_vp = (
        ctypes.POINTER(GluTcpConfig),
        ctypes.POINTER(GluUdpSocketConfig),
        ctypes.POINTER(GluEndpoint),
        ctypes.POINTER(vp),
    )
    funcs: dict[str, tuple[list[Any], Any]] = {
        "glu_last_error": ([], cp),
        "glu_shm_unlink": ([cp], None),
        "glu_publisher_new": ([cp, u32, u32, ctypes.c_int], vp),
        "glu_publisher_free": ([vp], None),
        "glu_publisher_reserve": ([vp], vp),
        "glu_publisher_commit": ([vp], None),
        "glu_publisher_publish": ([vp, vp], ctypes.c_int),
        "glu_subscriber_new": ([cp, u32, u32], vp),
        "glu_subscriber_free": ([vp], None),
        "glu_subscriber_peek": ([vp], vp),
        "glu_subscriber_ack": ([vp], None),
        "glu_peer_new": ([cp, u32, u32, ctypes.c_int], vp),
        "glu_peer_free": ([vp], None),
        "glu_peer_send": ([vp, cp, sz], ctypes.c_int),
        "glu_peer_recv": ([vp, cp, sz, psz], ctypes.c_int),
        "glu_tcp_listen": ([u16, cp, p_tcp], vp),
        "glu_tcp_accept": ([vp, p_vp], ctypes.c_int),
        "glu_tcp_connect": ([cp, u16], vp),
        "glu_tcp_send": ([vp, cp, sz, psz], ctypes.c_int),
        "glu_tcp_receive": ([vp, cp, sz, psz], ctypes.c_int),
        "glu_tcp_apply_socket_opts": ([ctypes.c_int, p_tcp], ctypes.c_int),
        "glu_tcp_close_stream": ([vp], None),
        "glu_tcp_close_server": ([vp], None),
        "glu_udp_bind": ([u16, cp, p_udp], vp),
        "glu_udp_send_to": ([vp, cp, u16, cp, sz, psz], ctypes.c_int),
        "glu_udp_receive_from": ([vp, cp, sz, psz, p_ep], ctypes.c_int),
        "glu_udp_connect": ([vp, cp, u16], ctypes.c_int),
        "glu_udp_send": ([vp, cp, sz, psz], ctypes.c_int),
        "glu_udp_receive": ([vp, cp, sz, psz], ctypes.c_int),
        "glu_udp_join_multicast": ([vp, cp, u16, cp], None),
        "glu_udp_close": ([vp], None),
    }
    for name, (argtypes, restype) in funcs.items():
        fn = getattr(lib, name)
        fn.argtypes = argtypes
        fn.restype = restype


def get_last_error() -> str:
    err = get_lib().glu_last_error()
    return err.decode("utf-8") if err else "Unknown error"


def raise_last_error(context: str = "") -> NoReturn:
    msg = get_last_error()
    raise GluError(f"{context}: {msg}" if context else msg)


def __getattr__(name: str) -> Any:
    if name == "lib":
        return get_lib()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
