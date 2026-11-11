"""Compatibility API for the C++ HID parser and report decoder."""
import _hid_native
from hid_mouse import Field


class MouseReports:
    def __init__(self, descriptor):
        self._parser = _hid_native.create(bytes(descriptor))
        metadata = _hid_native.metadata(self._parser)
        self.lengths = {report: item[0] for report, item in metadata.items()}
        self.fields = {report: [Field(*field) for field in item[1]]
                       for report, item in metadata.items() if item[1]}

    def decode(self, report_id, data):
        if report_id not in self.lengths:
            raise ValueError(f'Unknown report ID {report_id}')
        return _hid_native.decode(self._parser, report_id, bytes(data), False)


class KeyboardReports(MouseReports):
    def __init__(self, descriptor):
        super().__init__(descriptor)
        self.held = {}
        self.consumer = {}

    def decode(self, report_id, data):
        if report_id not in self.lengths:
            raise ValueError(f'Unknown report ID {report_id}')
        state = _hid_native.decode(self._parser, report_id, bytes(data), True)
        if state is None:
            return None
        self.held[report_id], self.consumer[report_id] = state
        return {'kind': 'keyboard',
                'keys': sorted(set().union(*self.held.values())),
                'consumer': sorted(set().union(*self.consumer.values()))}
