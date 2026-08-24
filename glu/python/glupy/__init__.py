"""glupy - Python bindings for GLU (high-performance robotics middleware).

Importing this package never touches the native library; the first API call
loads ``libglu.so`` lazily (see :mod:`glupy._lib`).
"""

from ._lib import get_last_error as last_error
from ._version import __version__
from .codec import (
    bool_,
    f32,
    f64,
    get_codec,
    i8,
    i16,
    i32,
    i64,
    sizeof,
    u8,
    u16,
    u32,
    u64,
)
from .errors import GluClosedError, GluError, GluLoadError, GluTimeoutError
from .peer import Peer
from .pubsub import Publisher, Subscriber, shm_unlink
from .tcp import TcpConfig, TcpServer, TcpStream, apply_tcp_socket_opts
from .types import Endpoint, Tos, UdpSocketConfig
from .udp import UdpSocket

__all__ = [
    "Endpoint",
    "GluClosedError",
    # Errors
    "GluError",
    "GluLoadError",
    "GluTimeoutError",
    # Multicast peer sessions
    "Peer",
    # Shared-memory pub/sub
    "Publisher",
    "Subscriber",
    # Transports
    "TcpConfig",
    "TcpServer",
    "TcpStream",
    "Tos",
    "UdpSocket",
    "UdpSocketConfig",
    "__version__",
    "apply_tcp_socket_opts",
    "bool_",
    "f32",
    "f64",
    "get_codec",
    "i8",
    "i16",
    "i32",
    "i64",
    "last_error",
    "shm_unlink",
    # Codec & fixed-width types
    "sizeof",
    "u8",
    "u16",
    "u32",
    "u64",
]
