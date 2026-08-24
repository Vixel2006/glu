# Changelog

All notable changes to `glupy` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
adheres to [Semantic Versioning](https://semver.org/).

## [0.2.0]

### Fixed

- Dataclass codecs now resolve annotations via `typing.get_type_hints()`, so
  message modules using `from __future__ import annotations` (string
  annotations) work correctly.
- Nested dataclasses pack/unpack recursively at their byte offsets instead of
  raising `TypeError`.
- Unsupported field annotations now raise a `TypeError` naming the offending
  field.

### Changed

- **Breaking:** the exception hierarchy is richer: `GluLoadError(ImportError)`
  for missing/incompatible libraries, `GluClosedError` and `GluTimeoutError`
  (both `GluError` → `RuntimeError`) for handle/backpressure failures.
- **Breaking:** `Subscriber.read()` / `read_as()` now block up to `timeout`
  seconds (None = forever) and raise `GluTimeoutError` when it expires; they
  no longer return `None` on an empty ring — use `peek()` / `peek_as()` for
  non-blocking checks.
- `libglu.so` is loaded lazily; importing `glupy` never fails due to a missing
  native library, only the first API call does.
- `Publisher.publish()` packs dataclass/struct payloads directly into the
  shared slot (no intermediate byte copies); raw buffers are passed without a
  Python-side copy when writable.
- Package version is single-sourced in `glupy._version`; Python >= 3.9 is now
  required.

### Added

- `Subscriber.read(timeout=...)`, `read_as(..., timeout=...)`.
- Iterator protocol over `Subscriber` (`for msg in sub:`).
- Config dataclasses (`TcpConfig`, `UdpSocketConfig`) generate their ctypes
  conversion automatically from field definitions.
- Wheels bundling `libglu.so` per-platform (manylinux x86_64/aarch64) built in
  CI; sdist available with system-library fallback (`GLU_LIB_PATH`,
  `LD_LIBRARY_PATH`).
- Test suite split into lib-free codec unit tests and marked integration
  tests; ruff/mypy/pytest configured; CI runs the Python job.

## [0.1.0]

### Added

- Initial ctypes bindings: shared-memory `Publisher`/`Subscriber`, multicast
  `Peer`, TCP server/stream, UDP sockets, dataclass codec, context managers,
  and `py.typed` type hints.
