"""Exercise C++ persistence, log recovery, and input validation through the ABI."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from native_backend import call, EventJournal


class NativeBackendTests(unittest.TestCase):
    def test_hci_fragmentation_and_combined_packets(self):
        command = [1, 3, 12, 0]
        acl = [2, 1, 0, 3, 0, 8, 9, 10]
        combined = command + acl
        for split in range(len(combined) + 1):
            self.assertEqual(call('hci_packets', [combined[:split], combined[split:]]), [command, acl])
        self.assertEqual(call('hci_packets', [[byte] for byte in combined]), [command, acl])
        for byte in (0, 3, 4, 5, 255):
            with self.assertRaises(ValueError):
                call('hci_packets', [[byte]])

    def test_saved_records_validate_addresses_categories_and_utf8(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'saved.json'
            path.write_text(json.dumps({'01:02:03:04:05:06': {'name': '🖱' * 300, 'category': 'Mouse', 'appearance': '962'},
                                        '../file': {'category': 'Mouse'},
                                        '11:12:13:14:15:16': {'category': 'Audio'}}))
            data = call('saved_load', {'path': str(path)})
            self.assertEqual(list(data), ['01:02:03:04:05:06'])
            self.assertEqual(data['01:02:03:04:05:06']['name'], '🖱' * 255)
            self.assertEqual(data['01:02:03:04:05:06']['appearance'], 962)

    def test_private_writes_replace_symlinks_without_touching_target(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / 'target'
            target.write_text('unchanged')
            path = Path(folder) / 'private.json'
            path.symlink_to(target)
            call('save', {'path': str(path), 'data': {'safe': True}})
            self.assertFalse(path.is_symlink())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(target.read_text(), 'unchanged')

    def test_forget_only_removes_selected_bond_and_preserves_mode(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'bonds.json'
            path.write_text(json.dumps({'RawBluetooth': {'mouse': {'ltk': 'private'}, 'keyboard': {'ltk': 'keep'}},
                                        'old': {'mouse': {'ltk': 'private'}}}))
            self.assertTrue(call('forget_bond', {'path': str(path), 'peer': 'mouse'}))
            self.assertEqual(json.loads(path.read_text()), {'RawBluetooth': {'keyboard': {'ltk': 'keep'}}, 'old': {}})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertFalse(call('forget_bond', {'path': str(path), 'peer': 'missing'}))

    def test_journal_rotation_preserves_current_devices_and_pairing(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'events.jsonl'
            journal = EventJournal(path, limit=600)
            journal.emit('device', {'address': 'mouse', 'name': 'Mouse'})
            journal.emit('saved', {'address': 'mouse', 'auto_reconnect': True})
            journal.emit('connected', {'address': 'mouse'})
            journal.emit('connecting', {'address': 'keyboard'})
            journal.emit('passkey', {'address': 'keyboard', 'code': '001234'})
            for _ in range(15):
                journal.emit('input', {'address': 'mouse', 'reports': 100})
            journal.close()
            events = [json.loads(line) for line in path.read_text().splitlines()]
            states = [event['state'] for event in events]
            for state in ('device', 'saved', 'connected', 'connecting', 'passkey'):
                self.assertIn(state, states)
            self.assertTrue(any(event.get('code') == '001234' for event in events))
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)
            with self.assertRaisesRegex(RuntimeError, 'closed'):
                journal.emit('ready', {})

    def test_empty_or_corrupt_preferences_do_not_prevent_startup(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'saved.json'
            for data in ('{', '[]', 'null', '"text"'):
                path.write_text(data)
                self.assertEqual(call('saved_load', {'path': str(path)}), {})
