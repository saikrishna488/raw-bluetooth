"""Async Bumble transport adapter for the native account-restricted USB broker."""
import asyncio
from contextvars import ContextVar
import json
import os
from pathlib import Path
import struct

from bumble.transport import open_transport
from bumble.transport.common import AsyncPacketReader, PumpedPacketSource, Transport
from native_backend import call
from _driver_native import input_clock_ns

received_at_ns = ContextVar('received_at_ns', default=None)


class USBPacketSource(PumpedPacketSource):
    def __init__(self, reader, timestamped):
        self.reader = reader
        self.timestamped = timestamped
        self.legacy_reader = AsyncPacketReader(reader)
        super().__init__(self.receive)

    async def receive(self):
        if not self.timestamped:
            packet = await self.legacy_reader.next_packet()
            received_at_ns.set(input_clock_ns())
            return packet
        timestamp, length = struct.unpack('<QI', await self.reader.readexactly(12))
        if not 1 < length <= 65537:
            raise ValueError('Invalid USB packet envelope length')
        packet = await self.reader.readexactly(length)
        received_at_ns.set(timestamp)
        return packet


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
        writer.write(json.dumps({'transport': name, 'rx_version': 1}).encode() + b'\n')
        await writer.drain()
        reply = json.loads(await asyncio.wait_for(reader.readline(), 25))
        if 'error' in reply:
            raise RuntimeError(reply['error'])
        source = USBPacketSource(reader, reply.get('rx_version') == 1)
        source.start()
        return Transport(source, WriterSink(writer))
    except BaseException:
        writer.close()
        await writer.wait_closed()
        raise
