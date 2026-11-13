"""Thin binding to C++ CoreGraphics pointer output; Swift GUI is independent."""
import json
import _driver_native
from native_backend import call


def clamp_pointer(x, y, displays):
    return tuple(call('clamp_pointer', {'x': x, 'y': y, 'displays': displays}))


def request_accessibility():
    return call('request_accessibility', {})


class Pointer:
    def __init__(self):
        self._handle = _driver_native.pointer_create()

    def apply(self, report):
        _driver_native.pointer_apply(self._handle, json.dumps(report))

    def release(self):
        _driver_native.pointer_release(self._handle)
