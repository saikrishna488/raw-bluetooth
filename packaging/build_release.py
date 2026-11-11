"""Build an Intel DMG without installing or changing the development app."""
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import sysconfig
import urllib.request
import tarfile

from build_ffmpeg import build as build_ffmpeg

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / 'dist'
BUILD = ROOT / 'build/release'


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, cwd=ROOT, **kwargs)


def main():
    if sys.platform != 'darwin' or platform.machine() != 'x86_64':
        raise SystemExit('Build on an Intel Mac with Xcode Command Line Tools installed.')
    info = plistlib.loads((ROOT / 'gui/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    BUILD.mkdir(parents=True, exist_ok=True)
    DIST.mkdir(exist_ok=True)
    run(sys.executable, ROOT / 'native/build.py')
    ffmpeg, ffmpeg_source = build_ffmpeg(BUILD / 'vendor')
    app = BUILD / 'image/Raw Bluetooth.app'
    if app.parent.exists():
        shutil.rmtree(app.parent)
    macos = app / 'Contents/MacOS'
    resources = app / 'Contents/Resources'
    macos.mkdir(parents=True)
    resources.mkdir()
    info.pop('DriverSourceDirectory', None)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    run(sys.executable, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir', '--windowed',
        '--name', 'raw-bluetooth-backend', '--target-arch', 'x86_64',
        '--distpath', BUILD / 'frozen', '--workpath', BUILD / 'pyinstaller',
        '--specpath', BUILD, '--paths', ROOT,
        '--collect-all', 'bumble', '--collect-all', 'libusb_package',
        '--exclude-module', 'imageio_ffmpeg', '--add-binary', f'{ffmpeg}:.',
        '--copy-metadata', 'bumble',
        '--hidden-import', '_hid_native', '--hidden-import', 'native_hid',
        '--hidden-import', 'gui_backend', ROOT / 'packaging/backend_entry.py')
    helpers = app / 'Contents/Helpers'
    helpers.mkdir()
    shutil.copytree(BUILD / 'frozen/raw-bluetooth-backend.app', helpers / 'backend.app', symlinks=True)
    # Preserve firmware provenance. The default external adapter does not load it.
    shutil.copytree(ROOT / 'firmware', resources / 'firmware')
    notices = resources / 'ThirdPartyNotices'
    notices.mkdir()
    shutil.copy2(ffmpeg_source, notices / ffmpeg_source.name)
    shutil.copy2(ffmpeg.parent / 'COPYING.LGPLv2.1', notices / 'FFmpeg-COPYING.LGPLv2.1')
    shutil.copy2(ROOT / 'packaging/build_ffmpeg.py', notices / 'build_ffmpeg.py')
    libusb_source = BUILD / 'vendor/libusb-1.0.26.tar.bz2'
    if not libusb_source.exists():
        urllib.request.urlretrieve('https://github.com/libusb/libusb/releases/download/v1.0.26/libusb-1.0.26.tar.bz2', libusb_source)
    if hashlib.sha256(libusb_source.read_bytes()).hexdigest() != '12ce7a61fc9854d1d2a1ffe095f7b5fac19ddba095c259e6067a46500381b5a5':
        raise RuntimeError('libusb source checksum mismatch')
    shutil.copy2(libusb_source, notices / libusb_source.name)
    with tarfile.open(libusb_source) as archive:
        (notices / 'libusb-COPYING').write_bytes(archive.extractfile('libusb-1.0.26/COPYING').read())
    python_license = Path(sysconfig.get_path('stdlib')) / 'LICENSE.txt'
    if not python_license.is_file():
        raise RuntimeError('Python runtime license not found')
    shutil.copy2(python_license, notices / 'Python-LICENSE.txt')
    records = []
    for distribution in importlib.metadata.distributions():
        name = distribution.metadata['Name']
        records.append({'name': name, 'version': distribution.version,
                        'license': distribution.metadata.get('License-Expression') or distribution.metadata.get('License', ''),
                        'home_page': distribution.metadata.get('Home-page', '')})
        for item in distribution.files or []:
            if Path(item).name.lower().startswith(('license', 'licence', 'copying', 'notice')) and '..' not in item.parts and Path(item).suffix not in ('.py', '.pyc'):
                source = Path(distribution.locate_file(item))
                if source.is_file():
                    target = notices / name / str(item).replace('..', '_')
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, target)
    (notices / 'dependencies.json').write_text(json.dumps(records, indent=2))
    shutil.copy2(ROOT / 'packaging/INSTALL.txt', app.parent / 'READ ME FIRST.txt')
    shutil.copy2(ROOT / 'packaging/INSTALL.txt', resources / 'INSTALL.txt')
    run('xcrun', 'swiftc', '-O', '-parse-as-library', 'gui/RawBluetooth.swift',
        'gui/PointerServer.swift', 'gui/KeyboardOutput.swift', 'gui/SystemAudioCapture.swift', '-o', macos / 'RawBluetooth',
        '-framework', 'SwiftUI', '-framework', 'AppKit', '-framework', 'ServiceManagement', '-framework', 'ScreenCaptureKit', '-framework', 'CoreMedia',
        '-target', 'x86_64-apple-macosx13.0')
    identity = os.environ.get('RAW_BT_SIGN_IDENTITY', '-')
    # Deep ad-hoc signing is for the unsigned preview. Developer ID distribution
    # needs nested signing and notarization before it is advertised as trusted.
    if identity != '-':
        raise SystemExit('Developer ID signing is not automated yet; use the unsigned preview build.')
    run('codesign', '--force', '--deep', '--sign', '-', app)
    run('codesign', '--verify', '--deep', '--strict', app)
    run(helpers / 'backend.app/Contents/MacOS/raw-bluetooth-backend', '--self-test')
    (app.parent / 'Applications').symlink_to('/Applications')
    dmg = DIST / f'Raw-Bluetooth-{version}-macOS-Intel.dmg'
    if dmg.exists():
        dmg.unlink()
    run('hdiutil', 'create', '-volname', f'Raw Bluetooth {version}', '-srcfolder', app.parent,
        '-format', 'UDZO', dmg)
    run('hdiutil', 'verify', dmg)
    checksum = hashlib.sha256(dmg.read_bytes()).hexdigest()
    (DIST / (dmg.name + '.sha256')).write_text(f'{checksum}  {dmg.name}\n')
    print(f'Built {dmg}')


if __name__ == '__main__':
    main()
