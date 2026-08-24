class GluLoadError(ImportError):
    """Raised when ``libglu.so`` cannot be located or loaded."""


class GluError(RuntimeError):
    """Base class for all GLU runtime failures."""


class GluClosedError(GluError):
    """Raised when an operation is attempted on a closed handle."""


class GluTimeoutError(GluError):
    """Raised when a timed operation expires before completing."""
