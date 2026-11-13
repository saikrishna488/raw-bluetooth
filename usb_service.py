"""Async Bumble transport adapter for the native account-restricted USB broker."""
import asyncio
import json
import os
from pathlib import Path

from bumble.transport import open_transport
from bumble.transport.common import AsyncPacketReader, PumpedPacketSource, Transport
from native_backend import call


def socket_path(uid=None):
    return Path(f'/var/run/raw-bluetooth-{os.getuid() if uid is None else uid}/usb.sock')


def service_installed():
    return call('service_installed', {'path': str(socket_path())})


class WriterSink:
    def __init__(self, writer):
        self.writer = writer

    def on_packet(self, packet):
        # Bound memory if a client stops reading while its adapter is active.
        if self.writer.transport.get_write_buffer_size() > 1024 * 1024:
            self.writer.close()
            return
        self.writer.write(packet)

    def close(self):
        self.writer.close()


async def open_driver_transport(name):
    if not name.startswith('usb:') or not service_installed():
        return await open_transport(name)
    reader, writer = await asyncio.open_unix_connection(str(socket_path()), limit=4096)
    try:
        writer.write(json.dumps({'transport': name}).encode() + b'\n')
        await writer.drain()
        reply = json.loads(await asyncio.wait_for(reader.readline(), 25))
        if 'error' in reply:
            raise RuntimeError(reply['error'])
        source = PumpedPacketSource(AsyncPacketReader(reader).next_packet)
        source.start()
        return Transport(source, WriterSink(writer))
    except BaseException:
        writer.close()
        await writer.wait_closed()
        raise
