"""Volatile, authenticated control channel for a desktop driver session."""
import asyncio
import json
import time


class SessionChannel:
    """One loopback connection carrying commands, heartbeats, and UI events."""
    def __init__(self, host, port, token):
        self.host, self.port, self.token = host, port, token
        self.reader = self.writer = None
        self.commands = asyncio.Queue()
        self.events = asyncio.Queue()
        self.last_heartbeat = time.monotonic()
        self._sender = self._receiver = None
        self.failure = None

    async def connect(self):
        self.reader, self.writer = await asyncio.wait_for(
            asyncio.open_connection(self.host, self.port), 10)
        await self._write({'type': 'hello', 'token': self.token})
        self._sender = asyncio.create_task(self._send_events())
        self._receiver = asyncio.create_task(self._read_messages())

    async def _write(self, message):
        self.writer.write(json.dumps(message, separators=(',', ':')).encode() + b'\n')
        await self.writer.drain()

    def emit(self, state, details):
        if self.failure is None:
            self.events.put_nowait({'type': 'event', 'event': dict(details, state=state)})

    async def _send_events(self):
        try:
            while True:
                await self._write(await self.events.get())
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self.failure = exc

    async def _read_messages(self):
        try:
            while line := await self.reader.readline():
                if len(line) > 64 * 1024:
                    raise ValueError('Session message is too large')
                message = json.loads(line)
                if not isinstance(message, dict):
                    continue
                if message.get('type') == 'heartbeat':
                    self.last_heartbeat = time.monotonic()
                elif message.get('type') == 'command' and isinstance(message.get('command'), dict):
                    self.commands.put_nowait(message['command'])
            self.failure = ConnectionError('Raw Bluetooth app disconnected')
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self.failure = exc

    def next_command(self):
        try:
            return self.commands.get_nowait()
        except asyncio.QueueEmpty:
            return None

    def heartbeat_expired(self):
        return self.failure is not None or time.monotonic() - self.last_heartbeat > 15

    async def close(self):
        for task in (self._sender, self._receiver):
            if task:
                task.cancel()
        for task in (self._sender, self._receiver):
            if task:
                await asyncio.gather(task, return_exceptions=True)
        if self.writer:
            self.writer.close()
            await self.writer.wait_closed()


class NullSessionChannel:
    """In-memory test double for backend unit tests."""
    def __init__(self):
        self.events = []
        self.last_heartbeat = time.monotonic()

    def emit(self, state, details):
        self.events.append((state, details))

    def next_command(self):
        return None

    def heartbeat_expired(self):
        return False

    def close(self):
        pass
