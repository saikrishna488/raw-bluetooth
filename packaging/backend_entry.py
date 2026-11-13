"""Frozen worker entry point; no USB access during --self-test."""
import argparse
import os
from pathlib import Path
import runpy
import sys


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--data-dir', type=Path)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--usb-service', type=int, metavar='UID')
    args, remaining = parser.parse_known_args()
    if args.usb_service is not None:
        if remaining or args.data_dir or args.self_test:
            parser.error('--usb-service cannot be combined with other options')
        broker = Path(sys._MEIPASS) / 'native/raw-bluetooth-usb'
        os.execv(str(broker), [str(broker), str(args.usb_service)])
    if args.data_dir:
        if not args.data_dir.is_absolute() or not args.data_dir.is_dir():
            parser.error('--data-dir must be an existing absolute directory')
        os.environ['RAW_BLUETOOTH_DATA_DIR'] = str(args.data_dir)
    elif not args.self_test:
        parser.error('--data-dir is required for the packaged worker')
    if args.self_test:
        import ctypes
        import _hid_native
        import _driver_native
        from native_backend import call
        assert call('clamp_pointer', {'x': -1, 'y': 4, 'displays': [[0, 0, 10, 10]]}) == [0, 4]
        from hid_backend import MouseReports
        assert MouseReports.__module__ == "native_hid"
        assert MouseReports(bytes.fromhex("050109301581750895018106")).decode(0, b"\xff") == {"x": -1}
        import gui_backend
        import bumble.transport.usb
        import libusb_package
        from audio_stream import ffmpeg_executable
        import subprocess
        ctypes.CDLL(libusb_package.get_library_path())
        subprocess.run([ffmpeg_executable(), '-version'], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([str(Path(sys._MEIPASS) / 'native/raw-bluetooth-usb'), '--self-test'], check=True)
        print('Bundled C++ backend, native USB broker, Bumble, and FFmpeg checks passed')
        return
    sys.argv = [sys.argv[0], *remaining]
    runpy.run_module('gui_backend', run_name='__main__')


if __name__ == '__main__':
    main()
