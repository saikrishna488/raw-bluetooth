"""Direct USB HCI BLE scan; no CoreBluetooth. Defaults to CSR 0a12:0001."""
import argparse
import struct
import time
import sys
import usb.core
import usb.util
import libusb_package


def parse_ads(event):
    if len(event) < 4 or event[0] != 0x3e or event[2] != 0x02:
        return
    pos = 4
    for _ in range(event[3]):
        if pos + 9 > len(event):
            return
        kind, addr_type = event[pos:pos + 2]
        address = ':'.join(f'{x:02X}' for x in event[pos + 2:pos + 8][::-1])
        length = event[pos + 8]
        end = pos + 9 + length
        if end >= len(event):
            return
        payload = event[pos + 9:end]
        rssi = struct.unpack('b', event[end:end + 1])[0]
        name = ''
        offset = 0
        while offset < len(payload):
            size = payload[offset]
            if not size or offset + size >= len(payload):
                break
            if payload[offset + 1] in (8, 9):
                name = payload[offset + 2:offset + 1 + size].decode('utf-8', 'replace')
            offset += size + 1
        print(f'ADV {address} type={addr_type} event={kind} RSSI={rssi} name={name!r} data={payload.hex()}', flush=True)
        pos = end + 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vid', type=lambda s: int(s, 0), default=0x0a12)
    parser.add_argument('--pid', type=lambda s: int(s, 0), default=0x0001)
    parser.add_argument('--seconds', type=int, default=45)
    args = parser.parse_args()
    dev = libusb_package.find(idVendor=args.vid, idProduct=args.pid)
    if dev is None:
        raise RuntimeError('Target USB adapter not found')
    print(f'USB {args.vid:04x}:{args.pid:04x} found; claiming HCI interface directly.', flush=True)
    claimed = detached = reset = False
    endpoint = None
    try:
        config = dev.get_active_configuration()
        interface = config[(0, 0)]
        endpoint = next((ep.bEndpointAddress for ep in interface
                         if usb.util.endpoint_direction(ep.bEndpointAddress) == usb.util.ENDPOINT_IN
                         and usb.util.endpoint_type(ep.bmAttributes) == usb.util.ENDPOINT_TYPE_INTR), None)
        if endpoint is None:
            raise RuntimeError('No HCI interrupt IN endpoint on interface 0')
        try:
            usb.util.claim_interface(dev, 0)
        except usb.core.USBError:
            print('Interface occupied; attempting authorized USB driver detach.', flush=True)
            dev.detach_kernel_driver(0)
            detached = True
            usb.util.claim_interface(dev, 0)
        claimed = True

        def command(opcode, payload=b''):
            packet = struct.pack('<HB', opcode, len(payload)) + payload
            print(f'HCI TX {opcode:04x} {payload.hex()}', flush=True)
            dev.ctrl_transfer(0x20, 0, 0, 0, packet, timeout=2000)
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                try:
                    event = bytes(dev.read(endpoint, 260, timeout=500))
                except usb.core.USBTimeoutError:
                    continue
                print(f'HCI RX {event.hex()}', flush=True)
                if len(event) >= 6 and event[0] == 0x0e and int.from_bytes(event[3:5], 'little') == opcode:
                    if event[5]:
                        raise RuntimeError(f'HCI {opcode:04x} rejected, status=0x{event[5]:02x}')
                    return event[5:]
                if len(event) >= 6 and event[0] == 0x0f and int.from_bytes(event[4:6], 'little') == opcode and event[2]:
                    raise RuntimeError(f'HCI {opcode:04x} rejected, status=0x{event[2]:02x}')
            raise RuntimeError(f'Timeout waiting for HCI {opcode:04x} completion')

        command(0x0c03)  # Reset controller only after exclusive claim.
        reset = True
        command(0x1001)  # Read local version for chipset identification.
        features = command(0x1003)
        if len(features) < 9 or not features[5] & 0x40:
            raise RuntimeError('Controller does not report LE support in local supported features')
        command(0x0c01, bytes.fromhex('ffffffffffffff3f'))  # Enable standard events including LE.
        command(0x2001, bytes.fromhex('1f00000000000000'))  # LE event mask including advertising reports.
        command(0x200b, struct.pack('<BHHBB', 1, 0x10, 0x10, 0, 0))
        command(0x200c, b'\x01\x00')
        print(f'Direct HCI scan active for {args.seconds}s. Keep M196 blinking.', flush=True)
        deadline = time.monotonic() + args.seconds
        while time.monotonic() < deadline:
            try:
                event = bytes(dev.read(endpoint, 260, timeout=500))
            except usb.core.USBTimeoutError:
                continue
            print(f'HCI RX {event.hex()}', flush=True)
            parse_ads(event)
    finally:
        if claimed and reset:
            try:
                command(0x200c, b'\x00\x00')
                command(0x0c03)
            except Exception as exc:
                print(f'Controller cleanup: {exc}', file=sys.stderr)
        if claimed:
            usb.util.release_interface(dev, 0)
        if detached:
            try:
                dev.attach_kernel_driver(0)
            except Exception as exc:
                print(f'Reattach: {exc}. Unplug/replug the USB adapter to restore macOS ownership.', file=sys.stderr)
        usb.util.dispose_resources(dev)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        print(f'STOPPED: {exc}', file=sys.stderr)
        sys.exit(1)
