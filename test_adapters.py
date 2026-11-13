"""External controller selection without opening a real USB controller."""
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import adapters
from native_backend import call


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
        self.assertEqual(call('topology', root['IORegistryEntryChildren']), [[0x0bda, 0x8771]])

    def test_topology_failure_does_not_claim_unknown_controllers(self):
        self.assertEqual(call('topology', []), [])

    def test_internal_duplicate_excludes_identity(self):
        nodes = [{'idVendor': 1, 'idProduct': 2, 'Built-In': flag, 'non-removable': 'yes' if flag else 'no'} for flag in (False, True)]
        self.assertEqual(call('topology', nodes), [])

    def test_hci_requires_interface_and_all_endpoint_directions(self):
        self.assertTrue(adapters.has_hci_interface(device()))
        self.assertFalse(adapters.has_hci_interface(device(interface_class=(3, 1, 1))))
        self.assertFalse(adapters.has_hci_interface(device(endpoints=[(3, 0x81), (2, 0x02)])))

    def test_discovery_uses_native_iokit_and_libusb(self):
        with patch('adapters.call', return_value=['usb:0bda:8771']) as native:
            self.assertEqual(adapters.discover_adapters(), ['usb:0bda:8771'])
            native.assert_called_once_with('discover_adapters', {})

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
