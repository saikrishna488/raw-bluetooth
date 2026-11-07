"""Small persistent device preferences; pairing keys stay in Bumble's keystore."""
import json
import os
from pathlib import Path
import tempfile
import re


def appearance(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


class SavedDevices:
    def __init__(self, path):
        self.path = Path(path)
        try:
            data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            data = {}
        self.devices = {}
        if isinstance(data, dict):
            for key, record in data.items():
                if isinstance(key, str) and re.fullmatch(r'(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}(?:/P)?', key) and isinstance(record, dict) and record.get('category') in ('Mouse', 'Keyboard'):
                    self.devices[key] = {'address': key, 'name': str(record.get('name', ''))[:255],
                                         'category': record['category'], 'appearance': appearance(record.get('appearance', 0)),
                                         'auto_reconnect': bool(record.get('auto_reconnect', True))}

    def remember(self, info, enabled=None):
        key = info['address']
        previous = self.devices.get(key, {})
        self.devices[key] = {name: info.get(name, previous.get(name, '')) for name in ('address', 'name', 'category', 'appearance')}
        self.devices[key]['appearance'] = appearance(self.devices[key]['appearance'])
        self.devices[key]['auto_reconnect'] = previous.get('auto_reconnect', True) if enabled is None else bool(enabled)
        self.save()
        return self.devices[key]

    def forget(self, key):
        existed = self.devices.pop(key, None) is not None
        if existed:
            self.save()
        return existed

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile('w', dir=self.path.parent, delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(self.devices, handle, indent=2)
        try:
            temporary.chmod(0o600)
            if os.geteuid() == 0:
                owner = self.path.parent.stat()
                os.chown(temporary, owner.st_uid, owner.st_gid)
            temporary.replace(self.path)
        finally:
            temporary.unlink(missing_ok=True)
