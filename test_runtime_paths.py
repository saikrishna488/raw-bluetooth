"""Installed workers must never put private state inside their bundle."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from runtime_paths import data_directory, write_diagnostic
from m196_driver import configuration


class RuntimePathsTests(unittest.TestCase):
    def test_diagnostic_replaces_unwritable_legacy_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'm196-report-map.hex'
            path.write_text('old')
            path.chmod(0o400)
            with patch.dict(os.environ, {'RAW_BLUETOOTH_DATA_DIR': folder}):
                write_diagnostic(path.name, 'new')
            self.assertEqual(path.read_text(), 'new')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(Path(folder).iterdir()), [path])

    def test_diagnostic_permission_failure_is_nonfatal_and_cleans_temporary_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'keyboard-report-map.hex'
            path.mkdir()
            with patch.dict(os.environ, {'RAW_BLUETOOTH_DATA_DIR': folder}):
                with self.assertLogs(level='WARNING'):
                    write_diagnostic(path.name, 'new')
            self.assertEqual(list(Path(folder).iterdir()), [path])

    def test_unwritable_diagnostic_directory_is_nonfatal(self):
        with patch('native_backend.call', side_effect=PermissionError('denied')):
            with self.assertLogs(level='WARNING'):
                write_diagnostic('keyboard-report-map.hex', 'new')

    def test_default_is_checkout(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(data_directory(), Path(__file__).resolve().parent)

    def test_identity_is_created_and_reused_in_application_data(self):
        with tempfile.TemporaryDirectory() as folder:
            with patch.dict(os.environ, {'RAW_BLUETOOTH_DATA_DIR': folder}):
                first = configuration()
                second = configuration()
                identity = Path(folder) / 'driver-identity.json'
                self.assertTrue(identity.is_file())
                self.assertEqual(identity.stat().st_mode & 0o777, 0o600)
                self.assertEqual(first.address, second.address)
                self.assertIn(folder, first.keystore)
