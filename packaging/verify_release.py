"""Exercise a mounted installer without Python on PATH or access to a checkout."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


def verify(dmg):
    mounted = plistlib.loads(subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', str(dmg)]))
    volume = next(Path(item['mount-point']) for item in mounted['system-entities'] if 'mount-point' in item)
    try:
        app = volume / 'Raw Bluetooth.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        assert 'DriverSourceDirectory' not in info
        forbidden = {'driver-identity.json', 'driver-bonds.json', 'saved-devices.json', '.signing', '.venv'}
        for path in app.rglob('*'):
            assert path.name not in forbidden, f'Private development data in installer: {path}'
            if path.is_symlink():
                assert path.resolve().is_relative_to(app.resolve()), f'External symlink: {path}'
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        with tempfile.TemporaryDirectory() as folder:
            env = {'PATH': '/usr/bin:/bin', 'HOME': folder, 'TMPDIR': folder}
            worker = app / 'Contents/Helpers/backend.app/Contents/MacOS/raw-bluetooth-backend'
            subprocess.run([str(worker), '--self-test'], env=env, cwd=folder, check=True, timeout=60)
        print('Read-only installer verification passed; no checkout, private data, or Python on PATH')
    finally:
        subprocess.run(['hdiutil', 'detach', str(volume)], check=True)


if __name__ == '__main__':
    verify(Path(sys.argv[1]).resolve())
