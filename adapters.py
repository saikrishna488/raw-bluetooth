"""Select the external USB Bluetooth adapter for raw HID sessions."""
import json
import os
from pathlib import Path
import shutil
import tempfile
import libusb_package
import usb.util


# Never claim the onboard Lite-On radio or Apple internal controllers.
EXCLUDED_IDS = {(0x04ca, 0x3018)}
HCI_CLASS = (0xe0, 0x01, 0x01)


def external_usb_ids():
    """Read macOS USB topology without opening or claiming any device.

    Unknown topology is not permission to take over an internal controller.
    Duplicate identities are excluded if any instance is internal or unknown.
    """
    import plistlib
    import subprocess
    try:
        result = subprocess.run(['/usr/sbin/ioreg', '-a', '-l', '-p', 'IOUSB'],
                                check=True, capture_output=True, timeout=10)
        root = plistlib.loads(result.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return set()
    external, excluded = set(), set()

    def visit(node):
        if isinstance(node, list):
            for child in node:
                visit(child)
        elif isinstance(node, dict):
            if 'idVendor' in node and 'idProduct' in node:
                identity = (node['idVendor'], node['idProduct'])
                removable = str(node.get('non-removable', '')).lower() == 'no'
                if node.get('Built-In') is False and removable:
                    external.add(identity)
                else:
                    excluded.add(identity)
            visit(node.get('IORegistryEntryChildren', []))

    visit(root)
    return external - excluded - EXCLUDED_IDS


def has_hci_interface(device):
    """Require the standard HCI interface and event/ACL USB endpoints."""
    for config in device:
        for interface in config:
            if (interface.bInterfaceClass, interface.bInterfaceSubClass,
                    interface.bInterfaceProtocol) != HCI_CLASS:
                continue
            endpoints = {(ep.bmAttributes & 3, bool(ep.bEndpointAddress & 0x80))
                         for ep in interface}
            if {(3, True), (2, True), (2, False)} <= endpoints:
                return True
    return False


def discover_adapters():
    """Return external standard USB HCI controllers; no firmware is loaded."""
    import usb.core
    allowed = external_usb_ids()
    adapters = []
    devices = list(libusb_package.find(find_all=True))
    identities = [(device.idVendor, device.idProduct) for device in devices]
    for device in devices:
        identity = (device.idVendor, device.idProduct)
        try:
            if (identity[0] == 0x05ac or identity in EXCLUDED_IDS or
                    identity not in allowed or identities.count(identity) != 1):
                continue
            if has_hci_interface(device):
                adapters.append('usb:%04x:%04x' % identity)
        except usb.core.USBError:
            # A busy or unreadable device cannot be validated safely.
            continue
        finally:
            usb.util.dispose_resources(device)
    return sorted(adapters)


def select_transport(requested='auto'):
    if requested != 'auto':
        # Other Bumble transports remain available to diagnostic CLI users.
        if requested.startswith('usb:'):
            import re
            match = re.fullmatch(r'usb:([0-9a-fA-F]{4}):([0-9a-fA-F]{4})', requested)
            if not match:
                raise ValueError('Use usb:VID:PID, for example usb:0a12:0001.')
            requested = requested.lower()
            if requested not in discover_adapters():
                raise ValueError('Selected USB adapter is unavailable, internal, duplicated, or lacks a standard Bluetooth HCI interface.')
        return requested, False
    adapters = discover_adapters()
    if not adapters:
        raise ValueError('No available external USB Bluetooth HCI adapter found. Connect a dongle with standard HCI firmware; firmware-only devices are not supported.')
    if len(adapters) > 1:
        raise ValueError('Multiple USB Bluetooth adapters found. Select a USB ID in Settings or use --transport: ' + ', '.join(adapters))
    return adapters[0], False


def migrate_bonds(path, peers):
    """Preserve the private host identity's bonds across a controller change."""
    path = Path(path)
    if not path.exists():
        return
    database = json.loads(path.read_text())
    target = dict(database.get('RawBluetooth', {}))
    changed = False
    for peer in peers:
        if peer in target:
            continue
        for namespace, records in database.items():
            if namespace != 'RawBluetooth' and isinstance(records, dict) and peer in records:
                target[peer] = records[peer]
                changed = True
                break
    if changed:
        backup = path.with_name('driver-bonds.pre-dual-adapter.json')
        if not backup.exists():
            shutil.copy2(path, backup)
            backup.chmod(0o600)
        database['RawBluetooth'] = target
        temporary = path.with_suffix('.migration.tmp')
        temporary.write_text(json.dumps(database, indent=2))
        temporary.chmod(0o600)
        os.replace(temporary, path)


def forget_bond(path, peer):
    """Remove this peer's pairing keys from every migrated controller namespace."""
    path = Path(path)
    try:
        database = json.loads(path.read_text())
    except (OSError, ValueError):
        return False
    changed = False
    for records in database.values():
        if isinstance(records, dict) and peer in records:
            del records[peer]
            changed = True
    if not changed:
        return False
    owner = path.stat()
    with tempfile.NamedTemporaryFile('w', dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        json.dump(database, handle, indent=2)
    temporary.chmod(0o600)
    if os.geteuid() == 0:
        os.chown(temporary, owner.st_uid, owner.st_gid)
    os.replace(temporary, path)
    return True
