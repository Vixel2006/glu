# glupy

Python bindings for **GLU** — ultra-fast, zero-copy, lock-free robotics middleware.

## Features

- **Standard `@dataclass` messages** — define messages with plain dataclasses; no `ctypes.Structure` boilerplate. Nested dataclasses, fixed-width scalars, and ctypes arrays are all supported.
- **Lock-free shared-memory pub/sub** — SPSC rings under `/dev/shm` with microsecond latencies.
- **Zero-copy reservations** — pack directly into shared memory via context managers.
- **Multicast peer sessions** — reliable or best-effort datagrams.
- **TCP & UDP transports** — high-performance sockets powered by GLU's `io_uring` backend.
- **Pythonic API** — context managers everywhere, timeouts, iterators, a proper exception hierarchy, and full type hints (`py.typed`).

## Installation

```bash
pip install glupy
```

Wheels bundle the native library — nothing else to build.

### From source (development)

Build the native library first, then install in editable mode:

```bash
zig build                      # from the repository root
cd glu/python
pip install -e .
```

For non-standard locations set `GLU_LIB_PATH=/path/to/libglu.so`.

> Requires Linux (shared-memory transport uses `/dev/shm`; TCP/UDP work anywhere the library builds).

## Quick start

### Shared-memory pub/sub

```python
from dataclasses import dataclass
import glupy

@dataclass
class JointState:
    seq: glupy.u32        # explicit fixed-width types are recommended...
    timestamp: glupy.i64
    position: glupy.f32
    velocity: glupy.f32

# --- Publisher ---
with glupy.Publisher("/robot/joint_state", JointState, capacity=1024) as pub:
    pub.publish(JointState(seq=1, timestamp=1000, position=1.57, velocity=0.0))

    # Zero-copy reservation: write fields straight into the slot,
    # committed automatically on exit.
    with pub.reserve_as() as slot:
        slot.seq = 2
        slot.timestamp = 2000
        slot.position = 3.14
        slot.velocity = 0.5

# --- Subscriber ---
with glupy.Subscriber("/robot/joint_state", JointState, capacity=1024) as sub:
    msg = sub.read(timeout=0.5)      # raises GluTimeoutError if empty
    if isinstance(msg, JointState):
        print(f"Seq: {msg.seq}, Pos: {msg.position:.2f}")

    # Or iterate forever:
    # for msg in sub: ...
```

> **Tip:** annotate message fields with explicit fixed-width types (`glupy.u32`,
> `glupy.f32`, ...). Native annotations use implicit mappings (`int -> i64`,
> `float -> f64`) which can silently mismatch C consumers expecting 4-byte types.

### Backpressure (`Tos`)

- `glupy.Tos.RELIABLE` *(default)* — writers block while the ring is full of unread messages.
- `glupy.Tos.BEST_EFFORT` — writers never block; oldest unread messages get overwritten.

### Multicast peers

```python
with glupy.Peer("session", Telemetry, tos=glupy.Tos.RELIABLE) as peer:
    peer.send(Telemetry(seq=1, ...))
    msg = peer.recv_as()
```

### TCP

```python
import glupy

# Server
with glupy.TcpServer(port=9999, host="127.0.0.1") as server:
    with server.accept() as client:
        data = client.recv(1024)
        client.send(b"ACK: " + data)

# Client
with glupy.TcpStream.connect("127.0.0.1", 9999) as stream:
    stream.send(b"Hello GLU")
    print(stream.recv(1024))
```

### UDP

```python
with glupy.UdpSocket(port=8888) as sock:
    sock.send_to("127.0.0.1", 8889, b"Ping")
    data, sender = sock.recv_from()
    print(f"{len(data)} bytes from {sender.host}:{sender.port}")
```

## Error handling

```python
try:
    ...
except glupy.GluTimeoutError:
    ...   # timed read expired
except glupy.GluClosedError:
    ...   # handle was closed
except glupy.GluError:
    ...   # any other GLU failure (GluError subclasses RuntimeError)
```

A missing/incompatible native library raises `glupy.GluLoadError` (an `ImportError`) on first use — importing `glupy` itself always succeeds.

## Development

```bash
zig build                     # from the repository root: builds libglu.so
cd glu/python
pip install -e . pytest ruff mypy
pytest                        # everything
pytest -m "not integration"   # codec unit tests only (no lib needed)
ruff check glupy tests
mypy
```

## License

MIT — see [LICENSE](../../LICENSE).
