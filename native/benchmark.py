"""Compare in-process decode throughput; excludes Bluetooth and IPC latency."""
from pathlib import Path
import sys
from timeit import repeat

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from hid_mouse import MouseReports as PythonMouse
from hid_keyboard import KeyboardReports as PythonKeyboard
from native_hid import MouseReports, KeyboardReports


def main():
    cases = [
        ('mouse', PythonMouse, MouseReports,
         '05010902a1010901a10005091901290315002501950375018102'
         '95017505810105010930093109381581257f750895038106c0c0',
         bytes([5, 255, 2, 255])),
        ('keyboard', PythonKeyboard, KeyboardReports,
         '05010906a101050719e029e715002501750195088102950175088101'
         '95067508150025650507190029658100c0',
         bytes([2, 0, 4, 5, 0, 0, 0, 0])),
    ]
    for name, reference, compiled, descriptor, data in cases:
        baseline, native = reference(bytes.fromhex(descriptor)), compiled(bytes.fromhex(descriptor))
        assert baseline.decode(0, data) == native.decode(0, data)
        times = [min(repeat(lambda: parser.decode(0, data), number=100000, repeat=5))
                 for parser in (baseline, native)]
        print(f'{name}: Python {times[0]:.3f}s, C++ {times[1]:.3f}s, {times[0]/times[1]:.2f}x throughput')


if __name__ == '__main__':
    main()
