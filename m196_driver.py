"""Experimental Logitech M196 USB-HCI -> BLE HID -> macOS pointer driver."""
import argparse
import asyncio
import json
import logging
import os
from pathlib import Path
import secrets
import signal
import socket

from bumble import hci
from bumble.core import AdvertisingData, UUID
from bumble.device import Device, DeviceConfiguration, Peer
from bumble.pairing import PairingConfig, PairingDelegate
from bumble.transport import open_transport
from hid_mouse import MouseReports
from hid_keyboard import KeyboardReports
from pointer import Pointer, request_accessibility

ROOT = Path(__file__).resolve().parent


class SocketPointer:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.sock.connect(path)
        self.sock.setblocking(False)
        self.queue = asyncio.Queue(maxsize=1024)
        self.failure = None
        self.sender = asyncio.create_task(self.send_reports())

    async def send_reports(self):
        while True:
            data = await self.queue.get()
            try:
                await asyncio.get_running_loop().sock_sendall(self.sock, data)
            except Exception as exc:
                self.failure = exc
            finally:
                self.queue.task_done()

    def apply(self, report):
        if self.failure:
            raise RuntimeError('Pointer helper disconnected') from self.failure
        self.queue.put_nowait(json.dumps(report).encode())

    def release(self):
        if not self.failure:
            self.apply({f'button{i + 1}': False for i in range(8)})

    async def close(self):
        try:
            await asyncio.wait_for(self.queue.join(), 1)
        except asyncio.TimeoutError:
            pass
        self.sender.cancel()
        await asyncio.gather(self.sender, return_exceptions=True)
        self.sock.close()


def configuration(classic_enabled=False):
    identity = ROOT / 'driver-identity.json'
    if not identity.exists():
        config = {
            'address': str(hci.Address.generate_static_address()),
            'irk': secrets.token_hex(16),
        }
        identity.write_text(json.dumps(config))
        identity.chmod(0o600)
    config = json.loads(identity.read_text())
    return DeviceConfiguration(
        name='M196 Raw Host', address=hci.Address(config['address']),
        irk=bytes.fromhex(config['irk']), le_enabled=True, classic_enabled=classic_enabled,
        keystore=f'JsonKeyStore:{ROOT / "driver-bonds.json"}',
    )


async def find_mouse(device, args):
    found = asyncio.get_running_loop().create_future()

    def advertisement(adv):
        name = adv.data.get(AdvertisingData.COMPLETE_LOCAL_NAME) or adv.data.get(AdvertisingData.SHORTENED_LOCAL_NAME) or ''
        if isinstance(name, bytes):
            name = name.decode('utf-8', 'replace')
        matched = bool(args.address) and str(adv.address).split('/')[0].upper() == args.address.upper()
        matched = matched or (not args.address and 'm196' in name.lower())
        if matched and adv.is_connectable and not found.done():
            print(f'FOUND {name!r} {adv.address} RSSI={adv.rssi}', flush=True)
            found.set_result(adv.address)

    device.on('advertisement', advertisement)
    try:
        print('SCANNING via USB HCI. Hold M196 pairing button until blinking.', flush=True)
        await device.start_scanning(legacy=True, active=True, scan_interval=10, scan_window=10)
        try:
            return await asyncio.wait_for(found, args.scan_timeout)
        except asyncio.TimeoutError as exc:
            raise RuntimeError('M196 not advertising within scan timeout; wake it or hold its pairing button until blinking') from exc
    finally:
        device.remove_listener('advertisement', advertisement)
        await device.stop_scanning()


async def use_mouse(device, address, args, pointer, observer=None):
    keyboard = getattr(args, 'device_kind', 'Mouse') == 'Keyboard'
    def notify(state, **details):
        if observer:
            observer(state, **details)
    notify('connecting', address=str(address))
    connection = await device.connect(address, timeout=20)
    disconnected = asyncio.Event()
    connection.on('disconnection', lambda *_: disconnected.set())
    try:
        print('CONNECTED. Establishing encrypted BLE pairing.', flush=True)
        notify('pairing', address=str(address))
        # Reuse a saved bond when present; otherwise perform Just Works pairing.
        keys = await device.keystore.get(str(connection.peer_address))
        if keys is not None and (keys.ltk is not None or keys.ltk_central is not None):
            await asyncio.wait_for(connection.encrypt(), 30)
        else:
            await asyncio.wait_for(connection.pair(), 120 if keyboard else 45)
        if not connection.encryption:
            await asyncio.wait_for(connection.encrypt(), 30)
        print('ENCRYPTED. Discovering HID service.', flush=True)
        notify('discovering', address=str(address))
        peer = Peer(connection)
        services = await asyncio.wait_for(peer.discover_services([UUID.from_16_bits(0x1812)]), 20)
        if not services:
            raise RuntimeError('Device has no HID-over-GATT service')
        service = services[0]
        await service.discover_characteristics()
        maps = service.get_characteristics_by_uuid(UUID.from_16_bits(0x2a4b))
        if not maps:
            raise RuntimeError('HID Report Map characteristic missing')
        descriptor = await maps[0].read_value()
        (ROOT / ('keyboard-report-map.hex' if keyboard else 'm196-report-map.hex')).write_text(descriptor.hex() + '\n')
        decoder = KeyboardReports(descriptor) if keyboard else MouseReports(descriptor)
        if keyboard and not any(field.page == 7 for fields in decoder.fields.values() for field in fields):
            raise RuntimeError('This HID device does not provide keyboard input')
        if not keyboard and not any(field.relative and field.page == 1 and field.usage in (0x30, 0x31)
                   for fields in decoder.fields.values() for field in fields):
            raise RuntimeError('This HID device does not provide relative mouse movement')
        print(f'HID report sizes: {decoder.lengths}', flush=True)
        protocols = service.get_characteristics_by_uuid(UUID.from_16_bits(0x2a4e))
        if protocols:
            await protocols[0].write_value(b'\x01', with_response=False)
        count = 0
        subscriptions = 0
        last_update = 0

        def receive(report_id, value):
            nonlocal count, last_update
            try:
                decoded = decoder.decode(report_id, value)
                if decoded is None:
                    return
                count += 1
                if not keyboard and (args.dry_run or count <= 5):
                    print(f'REPORT id={report_id} raw={value.hex()} decoded={decoded}', flush=True)
                if pointer:
                    pointer.apply(decoded)
                now = asyncio.get_running_loop().time()
                if now - last_update >= 0.5:
                    notify('input', reports=count, x=decoded.get('x', 0), y=decoded.get('y', 0))
                    last_update = now
            except Exception:
                logging.exception('HID report processing failed')

        for characteristic in service.get_characteristics_by_uuid(UUID.from_16_bits(0x2a4d)):
            await characteristic.discover_descriptors()
            reference = characteristic.get_descriptor(UUID.from_16_bits(0x2908))
            if reference is None:
                continue
            data = await reference.read_value()
            if len(data) != 2 or data[1] != 1:
                continue  # Only input reports.
            report_id = data[0]
            if report_id not in decoder.fields:
                continue
            fields = decoder.fields[report_id]
            supported = any(f.page in (7, 0x0c) for f in fields) if keyboard else any(f.page == 9 or (f.relative and f.page == 1 and f.usage in (0x30, 0x31, 0x38)) or (f.relative and f.page == 0x0c and f.usage == 0x238) for f in fields)
            if not supported:
                continue
            await characteristic.subscribe(lambda value, rid=report_id: receive(rid, value))
            subscriptions += 1
        if not subscriptions:
            raise RuntimeError('No supported HID input reports found')
        print(f'READY: {subscriptions} {"keyboard" if keyboard else "mouse"} input reports subscribed.', flush=True)
        notify('connected', address=str(address), subscriptions=subscriptions)
        await disconnected.wait()
        print(f'DISCONNECTED after {count} reports', flush=True)
        notify('disconnected', reports=count)
    finally:
        if pointer:
            pointer.release()
        if not disconnected.is_set():
            try:
                await asyncio.wait_for(connection.disconnect(), 5)
            except Exception:
                logging.exception('Disconnect cleanup')


async def run(args):
    os.umask(0o077)
    pointer = None if args.dry_run else SocketPointer(args.event_socket) if args.event_socket else Pointer()
    async with await open_transport(args.transport) as transport:
        device = Device.from_config_with_hci(configuration(), transport.source, transport.sink)
        device.pairing_config_factory = lambda _: PairingConfig(
            sc=True, mitm=False, bonding=True,
            delegate=PairingDelegate(PairingDelegate.NO_OUTPUT_NO_INPUT),
        )
        try:
            await asyncio.wait_for(device.power_on(), 20)
            while True:
                try:
                    address = await find_mouse(device, args)
                    await use_mouse(device, address, args, pointer)
                except Exception:
                    if args.once:
                        raise
                    logging.exception('Connection attempt failed; retrying in two seconds')
                    await asyncio.sleep(2)
                if args.once:
                    break
        finally:
            if pointer:
                pointer.release()
            # Clear scan/connection state before libusb releases the controller.
            try:
                await asyncio.wait_for(device.host.send_command(hci.HCI_Reset_Command(), check_result=True), 4)
            except Exception:
                logging.exception('Controller reset cleanup; unplug/replug adapter if needed')
            if isinstance(pointer, SocketPointer):
                await pointer.close()


async def main(args):
    task = asyncio.create_task(run(args))
    async def stop_watch():
        while not Path(args.stop_file).exists():
            await asyncio.sleep(0.5)
        task.cancel()
    watcher = asyncio.create_task(stop_watch()) if args.stop_file else None
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, task.cancel)
    try:
        await asyncio.wait_for(task, args.duration)
    except asyncio.TimeoutError:
        print('Session timeout reached; adapter released.', flush=True)
    except asyncio.CancelledError:
        print('Stopped; adapter released.', flush=True)
    finally:
        if watcher:
            watcher.cancel()
            await asyncio.gather(watcher, return_exceptions=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--transport', default='usb:0a12:0001')
    parser.add_argument('--address', help='Only connect to this mouse address')
    parser.add_argument('--dry-run', action='store_true', help='Log reports without posting pointer events')
    parser.add_argument('--scan-timeout', type=int, default=60)
    parser.add_argument('--duration', type=int, default=300, help='Maximum session length in seconds')
    parser.add_argument('--once', action='store_true', help='Exit after first disconnection')
    parser.add_argument('--request-accessibility', action='store_true', help='Show macOS pointer permission prompt and exit')
    parser.add_argument('--event-socket', help='Forward decoded reports to the unprivileged pointer helper')
    parser.add_argument('--stop-file', help='Stop and release USB when this file appears')
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format='%(levelname)s %(name)s: %(message)s')
    if args.request_accessibility:
        print(f'Accessibility granted: {request_accessibility()}', flush=True)
    else:
        asyncio.run(main(args))
