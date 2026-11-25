"""Asyncio-facing handle to the native ordered datagram delivery thread."""
import asyncio
import _driver_native


class SocketPointer:
    def __init__(self, path):
        self._handle = _driver_native.sender_create(str(path))

    def apply(self, report, device=None, **_ignored):
        """Hand a decoded HID report directly to the native binary sender."""
        _driver_native.sender_enqueue_report(self._handle, device or report.get('device', 'default'), report)

    def ingest_hid(self, parser, report_id, data, timestamp, keyboard, device):
        return _driver_native.sender_ingest_hid(
            self._handle, parser, device, report_id, bytes(data), timestamp, keyboard)

    def release(self, device='default'):
        self.apply({'kind': 'release'}, device)

    async def drain(self):
        return await asyncio.to_thread(_driver_native.sender_drain, self._handle, 1.0)

    async def close(self):
        await asyncio.to_thread(_driver_native.sender_close, self._handle)


def prioritize_input_thread():
    """Request interactive scheduling for the active BLE input callback."""
    return bool(_driver_native.input_qos())
