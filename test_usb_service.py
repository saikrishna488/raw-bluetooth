"""Native broker protocol tests never open or claim a USB controller."""
import asyncio
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import AsyncMock, patch
from usb_service import open_driver_transport

BROKER = Path(__file__).resolve().parent / 'build/native/raw-bluetooth-usb'


class USBServiceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/tmp')
        self.path = Path(self.temp.name) / 'usb.sock'
        self.process = await asyncio.create_subprocess_exec(str(BROKER), '--test-socket', str(self.path),
                                                            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        for _ in range(100):
            if self.path.exists():
                break
            await asyncio.sleep(0.01)
        self.assertTrue(self.path.exists())

    async def asyncTearDown(self):
        if self.process.returncode is None:
            self.process.terminate()
        await asyncio.wait_for(self.process.communicate(), 5)
        self.temp.cleanup()

    async def request(self, request):
        reader, writer = await asyncio.open_unix_connection(str(self.path))
        writer.write(json.dumps(request).encode() + b'\n')
        await writer.drain()
        response = json.loads(await asyncio.wait_for(reader.readline(), 2))
        writer.close()
        await writer.wait_closed()
        return response

    async def test_rejects_paths_other_transports_and_malformed_requests(self):
        for request in ({'transport': '/tmp/code.py'}, {'transport': 'tcp-client:localhost:1234'}, [],
                        {'transport': 'usb:05ac:1234;id'}, {'transport': 15}):
            response = await self.request(request)
            self.assertIn('external USB', response['error'])

    async def test_valid_requests_do_not_touch_usb_in_test_mode(self):
        for _ in range(3):
            response = await self.request({'transport': 'usb:0a12:0001'})
            self.assertIn('protocol test mode', response['error'])
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.path.stat().st_uid, os.getuid())

    async def test_oversized_request_is_rejected(self):
        reader, writer = await asyncio.open_unix_connection(str(self.path))
        writer.write(b'x' * 4096 + b'\n')
        await writer.drain()
        response = json.loads(await asyncio.wait_for(reader.readline(), 2))
        self.assertIn('Oversized', response['error'])
        writer.close()
        await writer.wait_closed()

    async def test_service_cannot_start_as_normal_user(self):
        result = await asyncio.create_subprocess_exec(str(BROKER), str(os.getuid()), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        _, error = await result.communicate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'requires root', error)

    async def test_client_propagates_capture_error(self):
        with patch('usb_service.service_installed', return_value=True), patch('usb_service.socket_path', return_value=self.path):
            with self.assertRaisesRegex(RuntimeError, 'protocol test mode'):
                await open_driver_transport('usb:0a12:0001')

    async def test_uninstalled_service_keeps_existing_transport(self):
        sentinel = object()
        with patch('usb_service.service_installed', return_value=False), patch('usb_service.open_transport', new_callable=AsyncMock, return_value=sentinel):
            self.assertIs(await open_driver_transport('usb:0a12:0001'), sentinel)
