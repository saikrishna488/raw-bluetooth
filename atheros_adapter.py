"""AR3012 volatile RAM firmware setup for the onboard Lite-On 04ca:3018.

USB protocol reference: Linux drivers/bluetooth/ath3k.c. Firmware is supplied by
the upstream linux-firmware distribution; see firmware/manifest.json and license.
No persistent flash is written.
"""
import hashlib
import json
from pathlib import Path
import struct
import time
import libusb_package
import usb.core
import usb.util

ROOT = Path(__file__).resolve().parent


def version(device):
    raw = bytes(device.ctrl_transfer(0xc0, 9, 0, 0, 20, timeout=2000))
    if len(raw) != 20:
        raise RuntimeError('Incomplete AR3012 firmware version response')
    return struct.unpack('<IIIB7x', raw)


def state(device):
    return int(device.ctrl_transfer(0xc0, 5, 0, 0, 1, timeout=2000)[0])


def payload(name):
    metadata = json.loads((ROOT / 'firmware/manifest.json').read_text())[name]
    data = (ROOT / 'firmware' / name).read_bytes()
    if hashlib.sha256(data).hexdigest() != metadata['sha256']:
        raise RuntimeError('AR3012 firmware integrity check failed')
    return data


def download(device, data):
    sent = device.ctrl_transfer(0x40, 1, 0, 0, data[:20], timeout=3000)
    if sent != min(20, len(data)):
        raise RuntimeError('Short AR3012 firmware header transfer')
    for offset in range(20, len(data), 4096):
        time.sleep(0.0001)
        block = data[offset:offset + 4096]
        if device.write(0x02, block, timeout=3000) != len(block):
            raise RuntimeError('Short AR3012 firmware payload transfer')


def prepare():
    device = libusb_package.find(idVendor=0x04ca, idProduct=0x3018)
    if device is None:
        return False
    claimed = False
    try:
        # A higher revision indicates firmware already loaded, per ath3k.
        if device.bcdDevice > 1:
            return True
        usb.util.claim_interface(device, 0)
        claimed = True
        rom, build, ram, clock = version(device)
        if rom != 0x31010100 or clock != 1:
            raise RuntimeError(f'Unsupported onboard controller ROM/clock: {rom:08x}/{clock}')
        flags = state(device)
        if not flags & 0x80:
            data = payload('ar3k/AthrBT_0x31010100.dfu')
            patch_rom, patch_build = struct.unpack('<II', data[-8:])
            if patch_rom != rom or patch_build <= build:
                raise RuntimeError('AR3012 patch does not match the controller')
            download(device, data)
        if not state(device) & 0x40:
            download(device, payload('ar3k/ramps_0x31010100_40.dfu'))
        if state(device) & 0x3f != 0x0e:
            device.ctrl_transfer(0x40, 7, 0, 0, b'', timeout=2000)
        print(f'Onboard firmware prepared: state=0x{state(device):02x}', flush=True)
        try:
            device.ctrl_transfer(0x40, 10, 0, 0, b'', timeout=2000)
        except usb.core.USBError:
            # Switching to the operational USB identity may disconnect the handle.
            pass
        return True
    finally:
        if claimed:
            try:
                usb.util.release_interface(device, 0)
            except usb.core.USBError:
                pass
        usb.util.dispose_resources(device)


if __name__ == '__main__':
    print('Onboard controller available:', prepare())
