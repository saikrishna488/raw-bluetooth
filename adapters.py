"""Select the external USB Bluetooth adapter for raw HID sessions."""
import json
import os
from pathlib import Path
import shutil
import tempfile
import libusb_package
import usb.util


def select_transport(requested='auto'):
    if requested != 'auto':
        return requested, False
    external = libusb_package.find(idVendor=0x0a12, idProduct=0x0001)
    present = external is not None
    if external is not None:
        usb.util.dispose_resources(external)
    # Keep the internal Lite-On combo card out of the raw Bluetooth path.
    # In particular, never load firmware onto or claim the 04ca:3018 radio.
    return 'usb:0a12:0001', False


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
