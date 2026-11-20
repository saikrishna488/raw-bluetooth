"""Asyncio-facing handle to the native ordered datagram delivery thread."""
import asyncio
import json
import time
import _driver_native


class SocketPointer:
    def __init__(self, path):
        self._handle = _driver_native.sender_create(str(path))

    def apply(self, report, coalescible=False, motion_timestamp_ns=None):
        # The receiver uses this timestamp to discard motion that was held
        # while macOS was busy launching another application. Control
        # reports are deliberately never stamped or discarded.
        if coalescible:
            report = dict(report)
            # This crosses a Python/Swift process boundary, so use wall-clock
            # time rather than a process-local monotonic clock.
            report['motion_timestamp_ns'] = motion_timestamp_ns or time.time_ns()
        _driver_native.sender_enqueue(self._handle, json.dumps(report), coalescible)

    def release(self):
        self.apply({f'button{i + 1}': False for i in range(8)})

    async def drain(self):
        return await asyncio.to_thread(_driver_native.sender_drain, self._handle, 1.0)

    async def close(self):
        await asyncio.to_thread(_driver_native.sender_close, self._handle)
