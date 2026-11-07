import unittest
from hid_mouse import MouseReports


class ReportsTest(unittest.TestCase):
    def test_mouse_buttons_signed_axes_and_wheel(self):
        parser = MouseReports(bytes.fromhex(
            '05010902a1010901a10005091901290315002501950375018102'
            '95017505810105010930093109381581257f750895038106c0c0'))
        self.assertEqual(parser.decode(0, bytes([5, 255, 2, 255])), {
            'button1': True, 'button2': False, 'button3': True,
            'x': -1, 'y': 2, 'wheel': -1})
        with self.assertRaises(ValueError):
            parser.decode(0, b'\x00')

    def test_report_id_packed_twelve_bit_axes(self):
        parser = MouseReports(bytes.fromhex(
            '05010902a10185020501093009311600f826ff07750c95028106c0'))
        packed = ((-17 & 4095) | (1024 << 12)).to_bytes(3, 'little')
        self.assertEqual(parser.decode(2, packed), {'x': -17, 'y': 1024})
        with self.assertRaises(ValueError):
            parser.decode(7, packed)

    def test_absolute_axes_are_not_forwarded(self):
        parser = MouseReports(bytes.fromhex('05010930150026ff00750895018102'))
        self.assertEqual(parser.decode(0, b'\x40'), {})

    def test_malformed_descriptor(self):
        with self.assertRaises(ValueError):
            MouseReports(b'\x76\x01')
        with self.assertRaises(ValueError):
            MouseReports(b'\xb4')


if __name__ == '__main__':
    unittest.main()
