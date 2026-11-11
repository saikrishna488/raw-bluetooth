"""Run the existing behavioral contract against C++ and check bit extraction."""
import random
import unittest
import test_hid_mouse
import test_hid_keyboard
from hid_mouse import MouseReports as PythonMouse
try:
    from native_hid import MouseReports, KeyboardReports
except ModuleNotFoundError:
    MouseReports = KeyboardReports = None


@unittest.skipIf(MouseReports is None, 'Build native/build.py to test C++')
class NativeMouseTests(test_hid_mouse.ReportsTest):
    def setUp(self):
        self.original = test_hid_mouse.MouseReports
        test_hid_mouse.MouseReports = MouseReports

    def tearDown(self):
        test_hid_mouse.MouseReports = self.original

    def test_all_field_widths_and_offsets(self):
        rng = random.Random(196)
        for width in range(1, 33):
            for offset in range(8):
                descriptor = bytes([0x75, offset, 0x95, 1, 0x81, 1,
                                    0x05, 1, 0x09, 0x30, 0x15, 0x81,
                                    0x75, width, 0x95, 1, 0x81, 6])
                reference, native = PythonMouse(descriptor), MouseReports(descriptor)
                self.assertEqual(reference.lengths, native.lengths)
                self.assertEqual(reference.fields, native.fields)
                for _ in range(20):
                    data = rng.getrandbits(width + offset).to_bytes((width + offset + 7)//8, 'little')
                    self.assertEqual(reference.decode(0, data), native.decode(0, data))

    def test_malformed_descriptors(self):
        for descriptor in (b'\xfe', b'\xfe\x03\x00\x01', b'\x75\x21\x95\x01\x81\x02', b'\xb4'):
            with self.assertRaises(ValueError):
                MouseReports(descriptor)


@unittest.skipIf(KeyboardReports is None, 'Build native/build.py to test C++')
class NativeKeyboardTests(test_hid_keyboard.KeyboardTests):
    def setUp(self):
        self.original = test_hid_keyboard.KeyboardReports
        test_hid_keyboard.KeyboardReports = KeyboardReports

    def tearDown(self):
        test_hid_keyboard.KeyboardReports = self.original
