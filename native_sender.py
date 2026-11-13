"""Asyncio-facing handle to the native ordered datagram delivery thread."""
import asyncio
import json
import _driver_native


class SocketPointer:
    def __init__(self, path):
        self._handle = _driver_native.sender_create(str(path))

    def apply(self, report):
        _driver_native.sender_enqueue(self._handle, json.dumps(report))

    def release(self):
        self.apply({f'button{i + 1}': False for i in range(8)})

    async def drain(self):
        return await asyncio.to_thread(_driver_native.sender_drain, self._handle, 1.0)

    async def close(self):
        await asyncio.to_thread(_driver_native.sender_close, self._handle)
