"""Bumble-facing device preferences adapter; persistence is implemented in C++."""
from pathlib import Path
from native_backend import call


class SavedDevices:
    def __init__(self, path):
        self.path = Path(path)
        self.devices = call('saved_load', {'path': str(self.path)})

    def remember(self, info, enabled=None):
        record = call('remember', {'devices': self.devices, 'info': info, 'enabled': enabled})
        self.devices[info['address']] = record
        self.save()
        return record

    def forget(self, key):
        existed = self.devices.pop(key, None) is not None
        if existed:
            self.save()
        return existed

    def save(self):
        call('save', {'path': str(self.path), 'data': self.devices})
