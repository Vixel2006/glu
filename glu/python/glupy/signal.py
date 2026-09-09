"""Signal handling for graceful shutdown."""

from ._lib import get_lib, raise_last_error


class Signal:
    """Install SIGINT/SIGTERM handlers for graceful shutdown.

    Usage::

        sig = Signal()
        while sig.running():
            # your event loop
            pass
    """

    def __init__(self) -> None:
        lib = get_lib()
        if lib.glu_signal_init() != 0:
            raise_last_error("glu_signal_init")

    def running(self) -> bool:
        """Returns True while no terminating signal has been received."""
        return get_lib().glu_signal_running()

    def stop(self) -> None:
        """Manually trigger shutdown."""
        get_lib().glu_signal_stop()

    def __enter__(self) -> "Signal":
        return self

    def __exit__(self, *args: object) -> None:
        pass
