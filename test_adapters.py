"""External controller selection without opening a real USB controller."""
import plistlib
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import adapters


def device(vid=0x0bda, pid=0x8771, interface_class=adapters.HCI_CLASS, endpoints=None):
    class Interface(list):
        bInterfaceClass, bInterfaceSubClass, bInterfaceProtocol = interface_class
    class Device(list):
        idVendor, idProduct = vid, pid
    addresses = endpoints if endpoints is not None else [(3, 0x81), (2, 0x82), (2, 0x02)]
    return Device([[Interface([SimpleNamespace(bmAttributes=k, bEndpointAddress=a) for k, a in addresses])]])


class AdapterTests(unittest.TestCase):
    def test_topology_requires_external_and_removable(self):
        root = {'IORegistryEntryChildren': [
            {'idVendor': 0x0bda, 'idProduct': 0x8771, 'Built-In': False, 'non-removable': 'no'},
            {'idVendor': 0x8087, 'idProduct': 0x0033, 'Built-In': True, 'non-removable': 'yes'},
            {'idVendor': 0x04ca, 'idProduct': 0x3018, 'Built-In': False, 'non-removable': 'no'},
            {'idVendor': 0x1234, 'idProduct': 1},
        ]}
        with patch('subprocess.run', return_value=SimpleNamespace(stdout=plistlib.dumps(root))):
            self.assertEqual(adapters.external_usb_ids(), {(0x0bda, 0x8771)})

    def test_topology_failure_does_not_claim_unknown_controllers(self):
        with patch('subprocess.run', side_effect=OSError('unavailable')):
            self.assertEqual(adapters.external_usb_ids(), set())

    def test_internal_duplicate_excludes_identity(self):
        nodes = [{'idVendor': 1, 'idProduct': 2, 'Built-In': flag, 'non-removable': 'yes' if flag else 'no'} for flag in (False, True)]
        with patch('subprocess.run', return_value=SimpleNamespace(stdout=plistlib.dumps(nodes))):
            self.assertEqual(adapters.external_usb_ids(), set())

    def test_hci_requires_interface_and_all_endpoint_directions(self):
        self.assertTrue(adapters.has_hci_interface(device()))
        self.assertFalse(adapters.has_hci_interface(device(interface_class=(3, 1, 1))))
        self.assertFalse(adapters.has_hci_interface(device(endpoints=[(3, 0x81), (2, 0x02)])))

    def test_discovery_accepts_non_csr_and_releases_every_handle(self):
        devices = [device(), device(0x1234, 1, (3, 1, 1)), device(0x05ac, 0x8290)]
        allowed = {(d.idVendor, d.idProduct) for d in devices}
        with patch('adapters.external_usb_ids', return_value=allowed), patch('adapters.libusb_package.find', return_value=devices), patch('adapters.usb.util.dispose_resources') as dispose:
            self.assertEqual(adapters.discover_adapters(), ['usb:0bda:8771'])
            self.assertEqual(dispose.call_count, 3)

    def test_duplicate_dongles_are_not_selected_by_ambiguous_id(self):
        with patch('adapters.external_usb_ids', return_value={(0x0bda, 0x8771)}), patch('adapters.libusb_package.find', return_value=[device(), device()]), patch('adapters.usb.util.dispose_resources'):
            self.assertEqual(adapters.discover_adapters(), [])

    def test_duplicate_with_unreadable_interface_is_still_ambiguous(self):
        with patch('adapters.external_usb_ids', return_value={(0x0bda, 0x8771)}), patch('adapters.libusb_package.find', return_value=[device(), device()]), patch('adapters.has_hci_interface') as inspect, patch('adapters.usb.util.dispose_resources'):
            self.assertEqual(adapters.discover_adapters(), [])
            inspect.assert_not_called()

    def test_busy_device_is_skipped(self):
        import usb.core
        with patch('adapters.external_usb_ids', return_value={(0x0bda, 0x8771)}), patch('adapters.libusb_package.find', return_value=[device()]), patch('adapters.has_hci_interface', side_effect=usb.core.USBError('busy')), patch('adapters.usb.util.dispose_resources') as dispose:
            self.assertEqual(adapters.discover_adapters(), [])
            dispose.assert_called_once()

    def test_single_adapter_auto_and_explicit_selection(self):
        with patch('adapters.discover_adapters', return_value=['usb:0bda:8771']):
            self.assertEqual(adapters.select_transport(), ('usb:0bda:8771', False))
            self.assertEqual(adapters.select_transport('usb:0BDA:8771'), ('usb:0bda:8771', False))
            with self.assertRaisesRegex(ValueError, 'unavailable'):
                adapters.select_transport('usb:0a12:0001')

    def test_missing_multiple_and_invalid_adapters(self):
        with patch('adapters.discover_adapters', return_value=[]):
            with self.assertRaisesRegex(ValueError, 'No available'):
                adapters.select_transport()
        with patch('adapters.discover_adapters', return_value=['usb:0a12:0001', 'usb:0bda:8771']):
            with self.assertRaisesRegex(ValueError, 'Multiple'):
                adapters.select_transport()
            self.assertEqual(adapters.select_transport('usb:0bda:8771'), ('usb:0bda:8771', False))
        with self.assertRaisesRegex(ValueError, 'VID:PID'):
            adapters.select_transport('usb:0')
        self.assertEqual(adapters.select_transport('tcp-client:localhost:9000'), ('tcp-client:localhost:9000', False))
