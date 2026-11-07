"""Decode relative mouse fields from the device's HID report descriptor."""
from dataclasses import dataclass


@dataclass
class Field:
    offset: int
    size: int
    page: int
    usage: int
    signed: bool
    relative: bool
    variable: bool = True


class MouseReports:
    def __init__(self, descriptor):
        self.fields = {}
        offsets = {}
        state = dict(page=0, size=0, count=0, report=0, minimum=0)
        stack, usages = [], []
        usage_min = usage_max = None
        pos = 0
        while pos < len(descriptor):
            prefix = descriptor[pos]
            pos += 1
            if prefix == 0xfe:
                if pos + 2 > len(descriptor):
                    raise ValueError('Truncated long HID item')
                length = descriptor[pos]
                pos += 2 + length
                if pos > len(descriptor):
                    raise ValueError('Truncated long HID payload')
                continue
            length = (0, 1, 2, 4)[prefix & 3]
            raw = descriptor[pos:pos + length]
            if len(raw) != length:
                raise ValueError('Truncated HID item')
            pos += length
            value = int.from_bytes(raw, 'little')
            kind, tag = (prefix >> 2) & 3, prefix >> 4
            if kind == 1:
                key = {0: 'page', 1: 'minimum', 7: 'size', 8: 'report', 9: 'count'}.get(tag)
                if key:
                    state[key] = int.from_bytes(raw, 'little', signed=True) if tag == 1 else value
                elif tag == 10:
                    stack.append(state.copy())
                elif tag == 11:
                    if not stack:
                        raise ValueError('Unbalanced HID global pop')
                    state = stack.pop()
            elif kind == 2:
                if tag == 0:
                    usages.append(value)
                elif tag == 1:
                    usage_min = value
                elif tag == 2:
                    usage_max = value
            elif kind == 0:
                if tag == 8:
                    report = state['report']
                    offset = offsets.get(report, 0)
                    if state['size'] > 32 or state['count'] > 1024:
                        raise ValueError('Unsupported HID field dimensions')
                    choices = usages[:]
                    if usage_min is not None and usage_max is not None:
                        if usage_max - usage_min > 1024:
                            raise ValueError('Excessive HID usage range')
                        choices.extend(range(usage_min, usage_max + 1))
                    for index in range(state['count']):
                        if not value & 1 and choices:
                            usage = choices[min(index, len(choices) - 1)] if value & 2 else choices[0]
                            page = usage >> 16 if usage > 0xffff else state['page']
                            self.fields.setdefault(report, []).append(Field(
                                offset, state['size'], page, usage & 0xffff,
                                state['minimum'] < 0, bool(value & 4), bool(value & 2)))
                        offset += state['size']
                    offsets[report] = offset
                usages = []
                usage_min = usage_max = None
        self.lengths = {report: (bits + 7) // 8 for report, bits in offsets.items()}

    def decode(self, report_id, data):
        if report_id not in self.lengths:
            raise ValueError(f'Unknown report ID {report_id}')
        if len(data) < self.lengths[report_id]:
            raise ValueError(f'Short report {report_id}: {len(data)} bytes')
        bits = int.from_bytes(data, 'little')
        result = {}
        for field in self.fields.get(report_id, []):
            if not field.size or not field.variable:
                continue
            value = (bits >> field.offset) & ((1 << field.size) - 1)
            if field.signed and value & (1 << (field.size - 1)):
                value -= 1 << field.size
            if field.page == 9 and 1 <= field.usage <= 8:
                result[f'button{field.usage}'] = bool(value)
            elif field.relative and field.page == 1:
                key = {0x30: 'x', 0x31: 'y', 0x38: 'wheel'}.get(field.usage)
                if key:
                    result[key] = value
            elif field.relative and field.page == 0x0c and field.usage == 0x238:
                result['pan'] = value
        return result
