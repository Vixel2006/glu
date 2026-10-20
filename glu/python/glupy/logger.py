"""Per-node file logging."""

import enum

from ._lib import _Handle, get_lib, raise_last_error


class LogLevel(enum.IntEnum):
    """Severity levels for :class:`Logger`."""

    ERROR = 0
    FATAL = 1
    INFO = 2
    WARNING = 3


class Logger(_Handle):
    """Appends ``[node] [timestamp] [LEVEL] msg`` lines to a node's log file.

    The log directory is the same one used by the daemon and read by the
    ``glu nodes logs`` CLI command. The combined line must fit the logger's
    internal 1024-byte buffer; longer messages raise ``GluError``.

    Usage::

        with Logger("my-node") as log:
            log.info("started")
    """

    _name = "Logger"

    def __init__(self, node: str):
        lib = get_lib()
        self._node = node
        self._close_fn = lib.glu_logger_free
        self._handle = lib.glu_logger_new(node.encode("utf-8"))
        if not self._handle:
            raise_last_error(f"Failed to create Logger for '{node}'")

    @property
    def node(self) -> str:
        return self._node

    def log(self, level: LogLevel, msg: str) -> None:
        self._ensure_open()
        if get_lib().glu_logger_log(self._handle, int(level), msg.encode("utf-8")) != 0:
            raise_last_error(f"Failed to log to node '{self._node}'")

    def error(self, msg: str) -> None:
        self.log(LogLevel.ERROR, msg)

    def fatal(self, msg: str) -> None:
        self.log(LogLevel.FATAL, msg)

    def info(self, msg: str) -> None:
        self.log(LogLevel.INFO, msg)

    def warning(self, msg: str) -> None:
        self.log(LogLevel.WARNING, msg)
