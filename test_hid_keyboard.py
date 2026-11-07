import unittest
from hid_keyboard import KeyboardReports


BOOT = bytes.fromhex(
    '05010906a101050719e029e715002501750195088102950175088101'
    '95067508150025650507190029658100c0')


class KeyboardTests(unittest.TestCase):
    def test_boot_array_and_modifiers(self):
        parser = KeyboardReports(BOOT)
        self.assertEqual(parser.decode(0, bytes([2, 0, 4, 5, 0, 0, 0, 0])),
                         {'kind': 'keyboard', 'keys': [4, 5, 225], 'consumer': []})
        self.assertEqual(parser.decode(0, bytes(8))['keys'], [])

    def test_rollover_preserves_previous_state(self):
        parser = KeyboardReports(BOOT)
        parser.decode(0, bytes([0, 0, 4, 0, 0, 0, 0, 0]))
        self.assertIsNone(parser.decode(0, bytes([0, 0, 1, 1, 1, 1, 1, 1])))
        self.assertEqual(parser.held[0], {4})

    def test_separate_report_ids_and_consumer_keys(self):
        parser = KeyboardReports(bytes.fromhex(
            '8501' + BOOT.hex() + '8502050c09e915002501750195018102750795018101'))
        parser.decode(1, bytes([1, 0, 4, 0, 0, 0, 0, 0]))
        self.assertEqual(parser.decode(2, b'\x01'),
                         {'kind': 'keyboard', 'keys': [4, 224], 'consumer': [0xe9]})
        self.assertEqual(parser.decode(2, b'\0')['keys'], [4, 224])

    def test_nkro_bitmap(self):
        parser = KeyboardReports(bytes.fromhex('05071904290b15002501750195088102'))
        self.assertEqual(parser.decode(0, b'\x81')['keys'], [4, 11])

    def test_truncated_and_unknown(self):
        parser = KeyboardReports(BOOT)
        with self.assertRaises(ValueError):
            parser.decode(0, bytes(2))
        with self.assertRaises(ValueError):
            parser.decode(7, bytes(8))


if __name__ == '__main__':
    unittest.main()
