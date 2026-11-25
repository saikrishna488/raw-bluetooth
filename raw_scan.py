"""Direct USB HCI BLE scan; no CoreBluetooth. Defaults to CSR 0a12:0001."""
import argparse
import os
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vid', type=lambda s: int(s, 0), default=0x0a12)
    parser.add_argument('--pid', type=lambda s: int(s, 0), default=0x0001)
    parser.add_argument('--seconds', type=int, default=45)
    args = parser.parse_args()
    if any(not 0 <= value <= 0xffff for value in (args.vid, args.pid)):
        parser.error('USB vendor and product IDs must fit in 16 bits')
    if not -(2**31) <= args.seconds < 2**31:
        parser.error('scan duration is outside the supported range')
    executable = Path(__file__).resolve().parent / 'build/native/raw-bluetooth-scan'
    try:
        os.execv(executable, [str(executable), str(args.vid), str(args.pid), str(args.seconds)])
    except FileNotFoundError:
        parser.exit(1, 'Build the scanner with .venv/bin/python native/build.py first.\n')


if __name__ == '__main__':
    main()
