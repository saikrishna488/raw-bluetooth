"""Installed workers must never put private state inside their bundle."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from runtime_paths import data_directory
from m196_driver import configuration


class RuntimePathsTests(unittest.TestCase):
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
