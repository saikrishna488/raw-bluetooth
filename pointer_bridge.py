"""Run as the logged-in user; receive mouse reports from the USB driver."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import stat
import time
from pointer import Pointer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--duration', type=int, default=300)
    parser.add_argument('--socket-path', type=Path, help='Private socket for a GUI session')
    args = parser.parse_args()
    pointer = Pointer()
    path = args.socket_path or Path(__file__).resolve().parent / 'pointer.sock'
    if path.exists():
        metadata = path.lstat()
        if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise RuntimeError('Unexpected file at pointer socket path')
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            probe.connect(str(path))
        except (ConnectionRefusedError, FileNotFoundError):
            path.unlink(missing_ok=True)
        else:
            raise RuntimeError('Another pointer helper is already running')
        finally:
            probe.close()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    stopping = False

    def stop(*_):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    os.umask(0o077)
    count = 0
    try:
        sock.bind(str(path))
        path.chmod(0o600)
        sock.settimeout(0.5)
        print(f'POINTER READY socket={path}', flush=True)
        (path.parent / 'pointer.ready').write_text(str(os.getpid()))
        deadline = time.monotonic() + args.duration
        while not stopping and time.monotonic() < deadline:
            try:
                data = sock.recv(4096)
            except socket.timeout:
                continue
            report = json.loads(data)
            if not isinstance(report, dict):
                continue
            filtered = {}
            for key, value in report.items():
                if key in ('x', 'y', 'wheel', 'pan') and isinstance(value, int) and -32768 <= value <= 32767:
                    filtered[key] = value
                elif key in {f'button{i}' for i in range(1, 9)} and isinstance(value, bool):
                    filtered[key] = value
            pointer.apply(filtered)
            count += 1
            if count <= 5:
                print(f'POSTED {filtered}', flush=True)
    finally:
        pointer.release()
        sock.close()
        path.unlink(missing_ok=True)
        (path.parent / 'pointer.ready').unlink(missing_ok=True)
        print(f'Pointer helper stopped after {count} reports', flush=True)


if __name__ == '__main__':
    main()
