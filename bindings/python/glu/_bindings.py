import ctypes
import ctypes.util
import os
import pathlib

_here = pathlib.Path(__file__).parent.resolve()

_glu_paths = [
    os.environ.get("GLU_LIB_PATH"),
    ctypes.util.find_library("glu"),
    str(_here.parent.parent.parent / "zig-out" / "lib" / "libglu.so"),
    "/usr/local/lib/libglu.so",
    "/usr/lib/libglu.so",
]

_lib = None
for p in _glu_paths:
    if p and os.path.exists(p):
        _lib = ctypes.cdll.LoadLibrary(p)
        break

if _lib is None:
    raise OSError(
        f"libglu.so not found. Tried: {[p for p in _glu_paths if p]}"
    )


# ── Error codes ─────────────────────────────────────────────────────────────

GLU_OK = 0
GLU_ERR_OUT_OF_MEM = -1
GLU_ERR_SHM_OPEN = -2
GLU_ERR_MMAP = -3
GLU_ERR_SOCKET = -4
GLU_ERR_BIND = -5
GLU_ERR_LISTEN = -6
GLU_ERR_ACCEPT = -7
GLU_ERR_CONNECT = -8
GLU_ERR_SEND = -9
GLU_ERR_RECV = -10
GLU_ERR_ADDR_RESOLVE = -11
GLU_ERR_WOULD_BLOCK = -12
GLU_ERR_CONN_RESET = -13
GLU_ERR_INTERRUPTED = -14
GLU_ERR_SETSOCKOPT = -15
GLU_ERR_FILE_SYSTEM = -16
GLU_ERR_NO_SPACE = -17
GLU_ERR_PARSE = -18
GLU_ERR_GENERATE = -19


class GluError(Exception):
    _messages = {
        GLU_OK: "success",
        GLU_ERR_OUT_OF_MEM: "out of memory",
        GLU_ERR_SHM_OPEN: "shm_open failed",
        GLU_ERR_MMAP: "mmap failed",
        GLU_ERR_SOCKET: "socket creation failed",
        GLU_ERR_BIND: "bind failed",
        GLU_ERR_LISTEN: "listen failed",
        GLU_ERR_ACCEPT: "accept failed",
        GLU_ERR_CONNECT: "connect failed",
        GLU_ERR_SEND: "send failed",
        GLU_ERR_RECV: "receive failed",
        GLU_ERR_ADDR_RESOLVE: "address resolution failed",
        GLU_ERR_WOULD_BLOCK: "operation would block",
        GLU_ERR_CONN_RESET: "connection reset",
        GLU_ERR_INTERRUPTED: "interrupted by signal",
        GLU_ERR_SETSOCKOPT: "setsockopt failed",
        GLU_ERR_FILE_SYSTEM: "file system error",
        GLU_ERR_NO_SPACE: "no space in ring buffer",
        GLU_ERR_PARSE: "parse error",
        GLU_ERR_GENERATE: "code generation error",
    }

    def __init__(self, code: int):
        self.code = code
        msg = self._messages.get(code, f"unknown error ({code})")
        super().__init__(msg)


def _check(rc: int):
    if rc != GLU_OK:
        raise GluError(rc)


# ── Opaque handle types ─────────────────────────────────────────────────────

glu_channel_t = ctypes.c_void_p
glu_publisher_t = ctypes.c_void_p
glu_subscriber_t = ctypes.c_void_p
glu_tcp_listener_t = ctypes.c_void_p
glu_tcp_connection_t = ctypes.c_void_p
glu_udp_socket_t = ctypes.c_void_p


# ── Struct types ────────────────────────────────────────────────────────────

class glu_udp_endpoint_t(ctypes.Structure):
    _fields_ = [
        ("host", ctypes.c_char * 46),
        ("host_len", ctypes.c_size_t),
        ("port", ctypes.c_uint16),
    ]


class glu_node_entry_t(ctypes.Structure):
    _fields_ = [
        ("name", ctypes.c_char_p),
        ("pid", ctypes.c_uint32),
        ("alive", ctypes.c_int),
    ]


class glu_msg_field_t(ctypes.Structure):
    _fields_ = [
        ("name", ctypes.c_char_p),
        ("type_", ctypes.c_char_p),
    ]


class glu_msg_t(ctypes.Structure):
    _fields_ = [
        ("name", ctypes.c_char_p),
        ("fields", ctypes.POINTER(glu_msg_field_t)),
        ("field_count", ctypes.c_uint32),
    ]


class glu_node_config_t(ctypes.Structure):
    _fields_ = [
        ("name", ctypes.c_char_p),
        ("path", ctypes.c_char_p),
        ("bin", ctypes.c_char_p),
        ("extra_cfg", ctypes.POINTER(ctypes.c_char_p)),
        ("extra_cfg_count", ctypes.c_uint32),
    ]


class glu_launched_node_t(ctypes.Structure):
    _fields_ = [
        ("name", ctypes.c_char_p),
        ("pid", ctypes.c_int32),
    ]


# ── Function signatures ─────────────────────────────────────────────────────

_lib.glu_channel_open.argtypes = [ctypes.c_char_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(glu_channel_t)]
_lib.glu_channel_open.restype = ctypes.c_int

_lib.glu_channel_close.argtypes = [glu_channel_t]
_lib.glu_channel_close.restype = None

_lib.glu_channel_write.argtypes = [glu_channel_t, ctypes.c_void_p, ctypes.c_uint32]
_lib.glu_channel_write.restype = None

_lib.glu_channel_read.argtypes = [glu_channel_t, ctypes.c_uint32]
_lib.glu_channel_read.restype = ctypes.c_void_p

_lib.glu_channel_msg_size.argtypes = [glu_channel_t]
_lib.glu_channel_msg_size.restype = ctypes.c_uint32

_lib.glu_channel_capacity.argtypes = [glu_channel_t]
_lib.glu_channel_capacity.restype = ctypes.c_uint32

_lib.glu_channel_write_cursor.argtypes = [glu_channel_t]
_lib.glu_channel_write_cursor.restype = ctypes.c_uint32

_lib.glu_publisher_init.argtypes = [ctypes.c_char_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(glu_publisher_t)]
_lib.glu_publisher_init.restype = ctypes.c_int

_lib.glu_publisher_deinit.argtypes = [glu_publisher_t]
_lib.glu_publisher_deinit.restype = None

_lib.glu_publisher_reserve.argtypes = [glu_publisher_t]
_lib.glu_publisher_reserve.restype = ctypes.c_void_p

_lib.glu_publisher_commit.argtypes = [glu_publisher_t]
_lib.glu_publisher_commit.restype = None

_lib.glu_publisher_publish.argtypes = [glu_publisher_t, ctypes.c_void_p, ctypes.c_uint32]
_lib.glu_publisher_publish.restype = None

_lib.glu_subscriber_init.argtypes = [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(glu_subscriber_t)]
_lib.glu_subscriber_init.restype = ctypes.c_int

_lib.glu_subscriber_deinit.argtypes = [glu_subscriber_t]
_lib.glu_subscriber_deinit.restype = None

_lib.glu_subscriber_receive.argtypes = [glu_subscriber_t]
_lib.glu_subscriber_receive.restype = ctypes.c_void_p

_lib.glu_tcp_listen.argtypes = [ctypes.c_uint16, ctypes.POINTER(glu_tcp_listener_t)]
_lib.glu_tcp_listen.restype = ctypes.c_int

_lib.glu_tcp_listener_deinit.argtypes = [glu_tcp_listener_t]
_lib.glu_tcp_listener_deinit.restype = None

_lib.glu_tcp_listener_port.argtypes = [glu_tcp_listener_t]
_lib.glu_tcp_listener_port.restype = ctypes.c_uint16

_lib.glu_tcp_accept.argtypes = [glu_tcp_listener_t, ctypes.POINTER(glu_tcp_connection_t)]
_lib.glu_tcp_accept.restype = ctypes.c_int

_lib.glu_tcp_connect.argtypes = [ctypes.c_char_p, ctypes.c_uint16, ctypes.POINTER(glu_tcp_connection_t)]
_lib.glu_tcp_connect.restype = ctypes.c_int

_lib.glu_tcp_send.argtypes = [glu_tcp_connection_t, ctypes.c_void_p, ctypes.c_uint32]
_lib.glu_tcp_send.restype = ctypes.c_int

_lib.glu_tcp_receive.argtypes = [glu_tcp_connection_t, ctypes.c_void_p, ctypes.c_uint32]
_lib.glu_tcp_receive.restype = ctypes.c_int

_lib.glu_tcp_connection_deinit.argtypes = [glu_tcp_connection_t]
_lib.glu_tcp_connection_deinit.restype = None

_lib.glu_tcp_set_blocking.argtypes = [glu_tcp_connection_t, ctypes.c_int]
_lib.glu_tcp_set_blocking.restype = ctypes.c_int

_lib.glu_udp_bind.argtypes = [ctypes.c_uint16, ctypes.POINTER(glu_udp_socket_t)]
_lib.glu_udp_bind.restype = ctypes.c_int

_lib.glu_udp_deinit.argtypes = [glu_udp_socket_t]
_lib.glu_udp_deinit.restype = None

_lib.glu_udp_send_to.argtypes = [glu_udp_socket_t, ctypes.c_char_p, ctypes.c_uint16, ctypes.c_void_p, ctypes.c_uint32]
_lib.glu_udp_send_to.restype = ctypes.c_int

_lib.glu_udp_receive_from.argtypes = [glu_udp_socket_t, ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(glu_udp_endpoint_t)]
_lib.glu_udp_receive_from.restype = ctypes.c_int

_lib.glu_udp_set_blocking.argtypes = [glu_udp_socket_t, ctypes.c_int]
_lib.glu_udp_set_blocking.restype = ctypes.c_int

_lib.glu_register.argtypes = [ctypes.c_char_p]
_lib.glu_register.restype = ctypes.c_int

_lib.glu_register_pid.argtypes = [ctypes.c_char_p, ctypes.c_uint32]
_lib.glu_register_pid.restype = ctypes.c_int

_lib.glu_unregister.argtypes = [ctypes.c_char_p]
_lib.glu_unregister.restype = None

_lib.glu_list_alive.argtypes = [ctypes.POINTER(ctypes.POINTER(glu_node_entry_t)), ctypes.POINTER(ctypes.c_uint32)]
_lib.glu_list_alive.restype = ctypes.c_int

_lib.glu_free_node_entries.argtypes = [ctypes.POINTER(glu_node_entry_t), ctypes.c_uint32]
_lib.glu_free_node_entries.restype = None

_lib.glu_parse_glu_file.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.POINTER(glu_msg_t)), ctypes.POINTER(ctypes.c_uint32)]
_lib.glu_parse_glu_file.restype = ctypes.c_int

_lib.glu_free_msgs.argtypes = [ctypes.POINTER(glu_msg_t), ctypes.c_uint32]
_lib.glu_free_msgs.restype = None

_lib.glu_launch.argtypes = [ctypes.POINTER(glu_node_config_t), ctypes.c_uint32, ctypes.POINTER(ctypes.POINTER(glu_launched_node_t)), ctypes.POINTER(ctypes.c_uint32)]
_lib.glu_launch.restype = ctypes.c_int

_lib.glu_launch_detached.argtypes = [ctypes.POINTER(glu_node_config_t), ctypes.c_uint32, ctypes.c_char_p]
_lib.glu_launch_detached.restype = ctypes.c_int

_lib.glu_free_launched_nodes.argtypes = [ctypes.POINTER(glu_launched_node_t), ctypes.c_uint32]
_lib.glu_free_launched_nodes.restype = None


# ── Convenience helpers ─────────────────────────────────────────────────────

def glu_channel_open(name, msg_size, capacity):
    out = glu_channel_t()
    _check(_lib.glu_channel_open(name.encode(), msg_size, capacity, ctypes.byref(out)))
    return out


def glu_publisher_init(name, msg_size, capacity=64):
    out = glu_publisher_t()
    _check(_lib.glu_publisher_init(name.encode(), msg_size, capacity, ctypes.byref(out)))
    return out


def glu_subscriber_init(sub_id, name, msg_size, capacity=64):
    out = glu_subscriber_t()
    _check(_lib.glu_subscriber_init(sub_id, name.encode(), msg_size, capacity, ctypes.byref(out)))
    return out


def glu_tcp_listen(port):
    out = glu_tcp_listener_t()
    _check(_lib.glu_tcp_listen(port, ctypes.byref(out)))
    return out


def glu_tcp_connect(host, port):
    out = glu_tcp_connection_t()
    _check(_lib.glu_tcp_connect(host.encode(), port, ctypes.byref(out)))
    return out
