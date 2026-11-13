"""Bumble transport adapter for native IOKit/libusb discovery and bond storage."""
from native_backend import call

EXCLUDED_IDS = {(0x04ca, 0x3018)}
HCI_CLASS = (0xe0, 0x01, 0x01)


def external_usb_ids():
    return {tuple(identity) for identity in call('external_usb_ids', {})}


def has_hci_interface(device):
    interfaces = [{'class': [interface.bInterfaceClass, interface.bInterfaceSubClass, interface.bInterfaceProtocol],
                   'endpoints': [[ep.bmAttributes, ep.bEndpointAddress] for ep in interface]}
                  for config in device for interface in config]
    return call('hci_interface', interfaces)


def discover_adapters():
    return call('discover_adapters', {})


def select_transport(requested='auto'):
    available = discover_adapters() if requested == 'auto' or requested.startswith('usb:') else []
    return tuple(call('select_transport', {'request': requested, 'adapters': available}))


def migrate_bonds(path, peers):
    call('migrate_bonds', {'path': str(path), 'peers': list(peers)})


def forget_bond(path, peer):
    return call('forget_bond', {'path': str(path), 'peer': peer})
