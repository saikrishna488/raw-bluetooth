import json
import asyncio
import errno
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch
from m196_driver import SocketPointer
from bumble.core import AdvertisingData
from gui_backend import advertisement_info, read_command, Backend, DisplayPasskey


def advertisement(data, connectable=True):
    return SimpleNamespace(address='00:11:22:33:44:55', data_bytes=data,
                           data=AdvertisingData.from_bytes(data), rssi=-39,
                           is_connectable=connectable)


class DiscoveryTests(unittest.TestCase):
    def test_actual_m196_advertisement(self):
        raw = bytes.fromhex('0319c20306ff06000300800a084c6f6769204d31393602010503031218')
        info = advertisement_info(advertisement(raw))
        self.assertEqual(info['name'], 'Logi M196')
        self.assertEqual(info['category'], 'Mouse')
        self.assertTrue(info['connectable'])
        # A scan response without a name must preserve the named device row.
        followup = advertisement_info(advertisement(bytes.fromhex('02010503031218'), False), info)
        self.assertEqual(followup['name'], 'Logi M196')
        self.assertTrue(followup['connectable'])

    def test_keyboard_and_broadcast(self):
        info = advertisement_info(advertisement(bytes.fromhex('0319c103'), False))
        self.assertEqual(info['category'], 'Keyboard')
        self.assertFalse(info['connectable'])
        named = advertisement_info(advertisement(bytes.fromhex('0a084c6f6769204b323530')))
        self.assertEqual(named['category'], 'Keyboard')

    def test_command_replay_invalid_and_partial_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'command.json'
            self.assertIsNone(read_command(path, None))
            path.write_text('{')
            self.assertIsNone(read_command(path, None))
            command = {'id': '1', 'action': 'connect', 'address': '00:11:22:33:44:55'}
            path.write_text(json.dumps(command))
            self.assertEqual(read_command(path, None), command)
            self.assertIsNone(read_command(path, '1'))
            path.write_text(json.dumps({'id': '2', 'action': 'execute'}))
            self.assertIsNone(read_command(path, None))
            path.write_text(' ' * 5000)
            self.assertIsNone(read_command(path, None))


class ConnectionTests(unittest.IsolatedAsyncioTestCase):
    async def test_input_sender_recovers_from_temporary_socket_congestion(self):
        sender = SocketPointer.__new__(SocketPointer)
        sender.sock = object()
        sender.queue = asyncio.Queue()
        sender.failure = None
        send = AsyncMock(side_effect=[OSError(errno.ENOBUFS, 'full'), None, None])
        loop = asyncio.get_running_loop()
        with patch.object(loop, 'sock_sendall', send):
            task = asyncio.create_task(sender.send_reports())
            try:
                sender.apply({'x': 1})
                sender.apply({'x': 2})
                await asyncio.wait_for(sender.queue.join(), 1)
                self.assertIsNone(sender.failure)
                self.assertEqual(send.await_count, 3)
                packets = [call.args[1] for call in send.await_args_list]
                self.assertEqual(packets[0], packets[1])
                self.assertEqual(json.loads(packets[2]), {'x': 2})
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)

    async def test_input_sender_reports_a_dead_socket(self):
        sender = SocketPointer.__new__(SocketPointer)
        sender.sock = object()
        sender.queue = asyncio.Queue()
        sender.failure = None
        loop = asyncio.get_running_loop()
        with patch.object(loop, 'sock_sendall', AsyncMock(side_effect=ConnectionRefusedError())):
            task = asyncio.create_task(sender.send_reports())
            try:
                sender.apply({'x': 1})
                await asyncio.wait_for(sender.queue.join(), 1)
                with self.assertRaisesRegex(RuntimeError, 'Pointer helper disconnected'):
                    sender.apply({'x': 2})
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)

    async def test_disconnect_keyboard_keeps_mouse_task(self):
        with tempfile.TemporaryDirectory() as tmp:
            backend = Backend(Path(tmp), 'test', saved_path=Path(tmp) / 'saved.json')
            mouse = asyncio.create_task(asyncio.Event().wait())
            keyboard = asyncio.create_task(asyncio.Event().wait())
            backend.connection_tasks = {'mouse': mouse, 'keyboard': keyboard}
            await backend.disconnect('keyboard')
            self.assertTrue(keyboard.cancelled())
            self.assertFalse(mouse.done())
            self.assertIn('mouse', backend.connection_tasks)
            await backend.disconnect()
            backend.events.close()

    async def test_keyboard_passkey_retains_leading_zeroes(self):
        events = []
        backend = SimpleNamespace(emit=lambda state, **data: events.append((state, data)))
        delegate = DisplayPasskey(backend, 'keyboard')
        await delegate.display_number(1234, 6)
        self.assertEqual(events, [('passkey', {'address': 'keyboard', 'code': '001234'})])

    async def test_reconnect_requires_recent_advertisement_and_respects_disconnect(self):
        with tempfile.TemporaryDirectory() as tmp:
            backend = Backend(Path(tmp), 'test', saved_path=Path(tmp) / 'saved.json')
            key = '00:11:22:33:44:66'
            info = {'address':key, 'name':'Logi K250', 'category':'Keyboard', 'appearance':961, 'last_seen':100}
            backend.devices[key] = info
            backend.remember(key)
            self.assertEqual(backend.reconnect_candidates(now=105), [key])
            self.assertEqual(backend.reconnect_candidates(now=120), [])
            backend.retry_at[key] = 110
            self.assertEqual(backend.reconnect_candidates(now=105), [])
            backend.retry_at.clear()
            await backend.disconnect(key)
            self.assertEqual(backend.reconnect_candidates(now=105), [])
            backend.remember(key, True)
            self.assertEqual(backend.reconnect_candidates(now=105), [key])
            backend.remember(key, False)
            self.assertEqual(backend.reconnect_candidates(now=105), [])
            backend.events.close()

    async def test_device_preferences_survive_restart_without_bond_contents(self):
        from saved_devices import SavedDevices
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'saved.json'
            store = SavedDevices(path)
            info = {'address':'00:11:22:33:44:66', 'name':'Logi K250', 'category':'Keyboard', 'appearance':961, 'ltk':'must not be stored'}
            store.remember(info, False)
            restored = SavedDevices(path)
            self.assertFalse(restored.devices[info['address']]['auto_reconnect'])
            self.assertNotIn('ltk', path.read_text())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    async def test_bonds_migrate_only_saved_peers_and_preserve_original(self):
        from adapters import migrate_bonds
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'driver-bonds.json'
            original = {'old-controller': {'keyboard': {'ltk': {'value':'ab' * 16}}, 'other': {'ltk': {'value':'cd' * 16}}}}
            path.write_text(json.dumps(original))
            migrate_bonds(path, ['keyboard'])
            result = json.loads(path.read_text())
            self.assertEqual(result['old-controller'], original['old-controller'])
            self.assertEqual(result['RawBluetooth'], {'keyboard': original['old-controller']['keyboard']})
            self.assertTrue(path.with_name('driver-bonds.pre-dual-adapter.json').exists())


if __name__ == '__main__':
    unittest.main()
