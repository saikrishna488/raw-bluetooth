import json
import asyncio
import socket
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch
from m196_driver import SocketPointer
from bumble.core import AdvertisingData
from gui_backend import advertisement_info, read_command, Backend, DisplayPasskey, DeviceOutput


def device_token(name):
    value = 1469598103934665603
    for byte in name.encode():
        value = ((value ^ byte) * 1099511628211) & ((1 << 64) - 1)
    return str(value)


def binary_report(data):
    """Decode the private native sender protocol for transport tests."""
    assert data[0] == 1
    device = str(int.from_bytes(data[4:12], 'little'))
    if data[1] == 1:
        result = {'device': device, 'x': int.from_bytes(data[12:14], 'little', signed=True),
                  'y': int.from_bytes(data[14:16], 'little', signed=True),
                  'wheel': int.from_bytes(data[16:18], 'little', signed=True),
                  'pan': int.from_bytes(data[18:20], 'little', signed=True)}
        if data[2] & 1:
            result.update({f'button{i + 1}': bool(data[20] & (1 << i)) for i in range(8)})
        else:
            result['motion_timestamp_ns'] = int.from_bytes(data[20:28], 'little')
        return {key: value for key, value in result.items()
                if value or key in ('device', 'motion_timestamp_ns') or key == 'button1'}
    if data[1] == 2:
        keys, consumer, offset = [], [], 14
        for _ in range(data[12]): keys.append(int.from_bytes(data[offset:offset + 2], 'little')); offset += 2
        for _ in range(data[13]): consumer.append(int.from_bytes(data[offset:offset + 2], 'little')); offset += 2
        return {'kind': 'keyboard', 'device': device, 'keys': keys, 'consumer': consumer}
    assert data[1] == 3
    return {'kind': 'release', 'device': device}


def advertisement(data, connectable=True, scan_response=False):
    return SimpleNamespace(address='00:11:22:33:44:55', data_bytes=data,
                           data=AdvertisingData.from_bytes(data), rssi=-39,
                           is_connectable=connectable, is_scan_response=scan_response)


class DiscoveryTests(unittest.TestCase):
    def test_actual_m196_advertisement(self):
        raw = bytes.fromhex('0319c20306ff06000300800a084c6f6769204d31393602010503031218')
        info = advertisement_info(advertisement(raw))
        self.assertEqual(info['name'], 'Logi M196')
        self.assertEqual(info['category'], 'Mouse')
        self.assertTrue(info['connectable'])
        # A scan response without a name must preserve the named device row.
        followup = advertisement_info(advertisement(bytes.fromhex('02010503031218'), False, scan_response=True), info)
        self.assertEqual(followup['name'], 'Logi M196')
        self.assertTrue(followup['connectable'])
        broadcast = advertisement_info(advertisement(bytes.fromhex('02010503031218'), False), info)
        self.assertFalse(broadcast['connectable'])

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
    async def test_mouse_motion_and_scroll_preserve_normal_report_cadence(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as folder:
            path = str(Path(folder) / 'pointer.sock')
            receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            receiver.bind(path)
            receiver.setblocking(False)
            output = DeviceOutput(path, 'mouse')
            try:
                output.apply({'x': 2, 'y': -1})
                output.apply({'x': 3, 'wheel': 2})
                reports = [binary_report(await asyncio.wait_for(asyncio.get_running_loop().sock_recv(receiver, 4096), 1)) for _ in range(2)]
                for report in reports: self.assertGreater(report.pop('motion_timestamp_ns'), 0)
                self.assertEqual(reports, [{'x': 2, 'y': -1, 'device': device_token('mouse')},
                                          {'x': 3, 'wheel': 2, 'device': device_token('mouse')}])
            finally:
                await output.close()
                receiver.close()

    async def test_unchanged_buttons_do_not_reduce_report_cadence(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as folder:
            path = str(Path(folder) / 'pointer.sock')
            receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            receiver.bind(path)
            receiver.setblocking(False)
            output = DeviceOutput(path, 'mouse')
            try:
                output.apply({'x': 2, 'button1': False})
                output.apply({'x': 3, 'wheel': 2, 'button1': False})
                reports = [binary_report(await asyncio.wait_for(asyncio.get_running_loop().sock_recv(receiver, 4096), 1)) for _ in range(2)]
                for report in reports: self.assertGreater(report.pop('motion_timestamp_ns'), 0)
                self.assertEqual(reports, [{'x': 2, 'device': device_token('mouse')},
                                          {'x': 3, 'wheel': 2, 'device': device_token('mouse')}])
            finally:
                await output.close()
                receiver.close()

    async def test_button_transition_flushes_prior_motion_in_order(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as folder:
            path = str(Path(folder) / 'pointer.sock')
            receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            receiver.bind(path)
            receiver.setblocking(False)
            output = DeviceOutput(path, 'mouse')
            try:
                output.apply({'x': 4, 'button1': False})
                output.apply({'button1': True})
                reports = [binary_report(await asyncio.wait_for(asyncio.get_running_loop().sock_recv(receiver, 4096), 1)) for _ in range(2)]
                self.assertGreater(reports[0].pop('motion_timestamp_ns'), 0)
                self.assertEqual(reports, [{'x': 4, 'device': device_token('mouse')}, {'button1': True, 'device': device_token('mouse')}])
            finally:
                await output.close()
                receiver.close()

    async def test_generic_mouse_and_keyboard_keep_delivering_after_congestion(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as folder:
            path = str(Path(folder) / 'pointer.sock')
            receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            receiver.bind(path)
            receiver.setblocking(False)
            delivered = []
            async def receive():
                # Native forwarding separates motion from a button transition,
                # preserving the required ordering without carrying JSON state.
                for _ in range(8):
                        delivered.append(binary_report(await asyncio.get_running_loop().sock_recv(receiver, 4096)))
            reader = asyncio.create_task(receive())
            outputs = []
            try:
                for address, reports in (
                    ('generic-mouse', [{'x': 3, 'y': -2, 'button1': True}, {'button1': False, 'wheel': 1}]),
                    ('generic-keyboard', [{'kind': 'keyboard', 'keys': [4], 'consumer': []},
                                          {'kind': 'keyboard', 'keys': [], 'consumer': []}]),
                ):
                    output = DeviceOutput(path, address)
                    outputs.append(output)
                    for report in reports:
                        output.apply(report)
                    output.release()
                    self.assertTrue(await output.output.drain())
                await asyncio.wait_for(reader, 2)
                mouse = device_token('generic-mouse')
                keyboard = device_token('generic-keyboard')
                self.assertEqual([item['device'] for item in delivered], [mouse] * 5 + [keyboard] * 3)
                self.assertEqual(delivered[0]['x'], 3)
                self.assertTrue(delivered[1]['button1'])
                self.assertEqual(delivered[2]['wheel'], 1)
                self.assertFalse(delivered[3]['button1'])
                self.assertEqual(delivered[4]['kind'], 'release')
                self.assertEqual(delivered[5]['keys'], [4])
                self.assertEqual(delivered[7]['kind'], 'release')
            finally:
                reader.cancel()
                await asyncio.gather(reader, return_exceptions=True)
                for output in outputs:
                    await output.close()
                receiver.close()

    async def test_input_sender_discards_stale_motion_when_congested(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as folder:
            path = str(Path(folder) / 'pointer.sock')
            receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            receiver.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            receiver.bind(path)
            receiver.setblocking(False)
            sender = SocketPointer(path)
            try:
                for i in range(200):
                    sender.apply({'x': i, 'padding': 'x' * 128}, coalescible=True)
                # Delay reads to force the sender to replace stale motion.
                await asyncio.sleep(0.05)
                delivered = []
                while True:
                    try:
                        data = await asyncio.wait_for(asyncio.get_running_loop().sock_recv(receiver, 4096), 0.1)
                    except asyncio.TimeoutError:
                        break
                    delivered.append(binary_report(data)['x'])
                self.assertTrue(await sender.drain())
                self.assertLessEqual(len(delivered), 32)
                self.assertTrue(delivered)
                self.assertGreater(delivered[-1], 0)
            finally:
                await sender.close()
                receiver.close()

    async def test_input_sender_reports_a_dead_socket(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as folder:
            path = str(Path(folder) / 'pointer.sock')
            receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            receiver.bind(path)
            sender = SocketPointer(path)
            receiver.close()
            try:
                sender.apply({'x': 1})
                self.assertTrue(await sender.drain())
                with self.assertRaisesRegex(RuntimeError, 'Pointer helper disconnected'):
                    sender.apply({'x': 2})
            finally:
                await sender.close()

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
