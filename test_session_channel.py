import asyncio
import json
import unittest

from session_channel import SessionChannel


class SessionChannelTests(unittest.IsolatedAsyncioTestCase):
    async def test_authenticated_bidirectional_memory_channel(self):
        received = asyncio.Queue()

        async def server(reader, writer):
            hello = json.loads(await reader.readline())
            await received.put(hello)
            writer.write(b'{"type":"heartbeat"}\n')
            writer.write(b'{"type":"command","command":{"id":"1","action":"scan"}}\n')
            await writer.drain()
            await received.put(json.loads(await reader.readline()))
            writer.close()

        listener = await asyncio.start_server(server, '127.0.0.1', 0)
        port = listener.sockets[0].getsockname()[1]
        channel = SessionChannel('127.0.0.1', port, 'secret')
        try:
            await channel.connect()
            self.assertEqual((await received.get())['token'], 'secret')
            command = None
            for _ in range(20):
                command = channel.next_command()
                if command:
                    break
                await asyncio.sleep(0.01)
            self.assertEqual(command, {'id': '1', 'action': 'scan'})
            channel.emit('ready', {'transport': 'test'})
            self.assertEqual((await received.get())['event']['state'], 'ready')
            await asyncio.sleep(0.01)
            self.assertTrue(channel.heartbeat_expired())
        finally:
            await channel.close()
            listener.close()
            await listener.wait_closed()
