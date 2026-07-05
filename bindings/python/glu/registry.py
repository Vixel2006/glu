import ctypes

from ._bindings import (
    _lib,
    glu_node_entry_t,
    _check,
)


def register(name: str, pid: int | None = None) -> None:
    if pid is None:
        _check(_lib.glu_register(name.encode()))
    else:
        _check(_lib.glu_register_pid(name.encode(), pid))


def unregister(name: str) -> None:
    _lib.glu_unregister(name.encode())


def list_alive() -> list[dict]:
    entries = ctypes.POINTER(glu_node_entry_t)()
    count = ctypes.c_uint32()
    _check(_lib.glu_list_alive(ctypes.byref(entries), ctypes.byref(count)))
    result = []
    for i in range(count.value):
        result.append({
            "name": entries[i].name.decode("utf-8", errors="replace"),
            "pid": entries[i].pid,
            "alive": bool(entries[i].alive),
        })
    _lib.glu_free_node_entries(entries, count.value)
    return result
