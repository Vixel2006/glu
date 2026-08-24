import ctypes
from dataclasses import fields, is_dataclass
from typing import Any, Dict, Optional, Type, Union, cast, get_type_hints

u8, u16, u32, u64 = ctypes.c_uint8, ctypes.c_uint16, ctypes.c_uint32, ctypes.c_uint64
i8, i16, i32, i64 = ctypes.c_int8, ctypes.c_int16, ctypes.c_int32, ctypes.c_int64
f32, f64, bool_ = ctypes.c_float, ctypes.c_double, ctypes.c_bool

_TYPE_MAP: Dict[Any, Any] = {int: i64, float: f64, bool: bool_}


def _resolve_c_type(field_type: Any, owner: type, field_name: str) -> Any:
    if field_type in _TYPE_MAP:
        return _TYPE_MAP[field_type]
    if isinstance(field_type, type) and issubclass(
        field_type, (ctypes._SimpleCData, ctypes.Array, ctypes.Structure)
    ):
        return field_type
    if is_dataclass(field_type):
        return get_codec(field_type).ctypes_cls
    raise TypeError(
        f"Unsupported annotation {field_type!r} for field {owner.__name__}.{field_name}. "
        "Use a fixed-width glupy/ctypes type (e.g. glupy.u32, glupy.f32, glupy.bool_), "
        "a ctypes.Array length, another dataclass, or int/float/bool."
    )


class Codec:
    """Converts between Python objects and fixed-size C memory buffers."""

    def __init__(self, target_type: type):
        self.target_type = target_type
        if isinstance(target_type, type) and issubclass(target_type, ctypes.Structure):
            self.is_dataclass = False
            self.ctypes_cls: Type[ctypes.Structure] = target_type
            self.size = ctypes.sizeof(target_type)
            self._fields_info: list[tuple[str, int, Optional[Codec]]] = []
        elif is_dataclass(target_type):
            self.is_dataclass = True
            try:
                hints = get_type_hints(target_type)
            except NameError:
                hints = {}
            c_fields = [
                (f.name, _resolve_c_type(hints.get(f.name, f.type), target_type, f.name))
                for f in fields(target_type)
            ]
            self.ctypes_cls = type(
                f"_{target_type.__name__}_CStruct",
                (ctypes.Structure,),
                {"_fields_": c_fields},
            )
            self.size = ctypes.sizeof(self.ctypes_cls)
            self._fields_info = [
                (
                    f.name,
                    int(getattr(self.ctypes_cls, f.name).offset),
                    get_codec(hints[f.name])
                    if isinstance(hints.get(f.name), type) and is_dataclass(hints[f.name])
                    else None,
                )
                for f in fields(target_type)
            ]
        else:
            raise TypeError(
                f"Unsupported message type: {target_type!r}. "
                "Must be a dataclass or ctypes.Structure."
            )

    def _write_fields(self, address: int, instance: Any) -> None:
        c_struct = self.ctypes_cls.from_address(address)
        for name, offset, sub in self._fields_info:
            val = getattr(instance, name)
            if sub is not None:
                sub.pack_into(address + offset, val)
            else:
                setattr(c_struct, name, val)

    def _read_fields(self, address: int) -> Dict[str, Any]:
        c_struct = self.ctypes_cls.from_address(address)
        return {
            name: sub.unpack_from(address + offset) if sub is not None else getattr(c_struct, name)
            for name, offset, sub in self._fields_info
        }

    def pack_into(self, address: int, instance: Any) -> None:
        if not self.is_dataclass:
            if isinstance(instance, ctypes.Structure):
                ctypes.memmove(address, ctypes.addressof(instance), self.size)
            else:
                raw = bytes(memoryview(instance))
                ctypes.memmove(address, raw, min(len(raw), self.size))
        else:
            self._write_fields(address, instance)

    def unpack_from(self, address: int) -> Any:
        if not self.is_dataclass:
            return cast(Type[ctypes.Structure], self.target_type).from_address(address)
        return self.target_type(**self._read_fields(address))

    def unpack_from_buffer(self, buffer: Union[bytes, bytearray, memoryview]) -> Any:
        if not self.is_dataclass:
            return cast(Type[ctypes.Structure], self.target_type).from_buffer_copy(buffer)
        tmp = self.ctypes_cls.from_buffer_copy(buffer)
        return self.unpack_from(ctypes.addressof(tmp))

    def to_bytes(self, instance: Any) -> bytes:
        if not self.is_dataclass:
            return bytes(memoryview(instance))
        buf = (ctypes.c_char * self.size)()
        self._write_fields(ctypes.addressof(buf), instance)
        return bytes(buf)


_CODEC_CACHE: Dict[type, Codec] = {}


def get_codec(msg_type: type) -> Codec:
    codec = _CODEC_CACHE.get(msg_type)
    if codec is None:
        codec = Codec(msg_type)
        _CODEC_CACHE[msg_type] = codec
    return codec


def sizeof(msg_type_or_obj: Any) -> int:
    obj = msg_type_or_obj
    if isinstance(obj, type):
        if is_dataclass(obj) or issubclass(obj, ctypes.Structure):
            return get_codec(obj).size
    elif is_dataclass(obj) or isinstance(obj, ctypes.Structure):
        return get_codec(type(obj)).size
    if hasattr(obj, "__len__"):
        return len(obj)
    raise TypeError(f"Cannot determine size of {obj!r}")


__all__ = [
    "Codec",
    "bool_",
    "f32",
    "f64",
    "get_codec",
    "i8",
    "i16",
    "i32",
    "i64",
    "sizeof",
    "u8",
    "u16",
    "u32",
    "u64",
]
