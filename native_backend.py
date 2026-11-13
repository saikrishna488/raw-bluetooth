"""Small CPython boundary; application policy and private I/O live in C++."""
import json
import _driver_native


def call(operation, payload):
    return json.loads(_driver_native.execute(operation, json.dumps(payload)))


class EventJournal:
    def __init__(self, path, limit=2 * 1024 * 1024):
        self._handle = _driver_native.journal_create(str(path), limit)

    def emit(self, state, details):
        _driver_native.journal_emit(self._handle, state, json.dumps(details))

    def close(self):
        _driver_native.journal_close(self._handle)
