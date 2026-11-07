"""Descriptor-driven BLE keyboard decoding, including boot arrays and NKRO."""
from hid_mouse import MouseReports


class KeyboardReports(MouseReports):
    def __init__(self, descriptor):
        super().__init__(descriptor)
        self.held = {}
        self.consumer = {}

    def decode(self, report_id, data):
        if report_id not in self.lengths or len(data) < self.lengths[report_id]:
            raise ValueError('Unknown or truncated keyboard input report')
        bits = int.from_bytes(data, 'little')
        keys, consumer = set(), set()
        for field in self.fields.get(report_id, []):
            if not field.size:
                continue
            value = (bits >> field.offset) & ((1 << field.size) - 1)
            usage = field.usage if field.variable else value
            if field.variable and not value:
                continue
            if field.page == 7:
                if usage in (1, 2, 3):
                    return None  # ErrorRollOver: retain the previous complete state.
                if 4 <= usage <= 0xe7:
                    keys.add(usage)
            elif field.page == 0x0c and usage:
                consumer.add(usage)
        self.held[report_id], self.consumer[report_id] = keys, consumer
        return {'kind': 'keyboard',
                'keys': sorted(set().union(*self.held.values())),
                'consumer': sorted(set().union(*self.consumer.values()))}
