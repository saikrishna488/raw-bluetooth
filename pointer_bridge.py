"""Launch the native macOS pointer relay as the logged-in user."""
import argparse
from pathlib import Path
import _driver_native


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--duration', type=int, default=300)
    parser.add_argument('--socket-path', type=Path)
    args = parser.parse_args()
    path = args.socket_path or Path(__file__).resolve().parent / 'pointer.sock'
    _driver_native.pointer_bridge(str(path), args.duration)


if __name__ == '__main__':
    main()
