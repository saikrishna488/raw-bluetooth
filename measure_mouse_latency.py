"""Measure real M196 USB-to-socket delivery with the desktop driver stopped."""

import argparse
import asyncio
from pathlib import Path
import socket
import statistics
import struct
import tempfile
from types import SimpleNamespace

from bumble import hci
from bumble.device import Device
from bumble.keys import JsonKeyStore

from adapters import select_transport
from m196_driver import configuration, use_mouse
from native_sender import SocketPointer
from runtime_paths import data_directory
from usb_service import input_clock_ns, open_driver_transport


def summarize(label, samples):
    if len(samples) < 2:
        print(f'{label}: insufficient movement ({len(samples)} reports)', flush=True)
        return False
    arrivals, receipts = zip(*samples)
    ages = [(arrival - receipt) / 1e6 for arrival, receipt in samples]
    gaps = [(end - start) / 1e6 for start, end in zip(arrivals, arrivals[1:])]
    for metric, values in [('delivery age', ages), ('report gap', gaps)]:
        p95 = statistics.quantiles(values, n=100, method='inclusive')[94] if len(values) > 1 else values[0]
        print(f'{label} {metric}: median {statistics.median(values):.2f} ms, '
              f'p95 {p95:.2f} ms, max {max(values):.2f} ms, n={len(values)}', flush=True)
    return True


async def run(args):
    transport_name, _ = await asyncio.to_thread(select_transport, 'auto')
    with tempfile.TemporaryDirectory(prefix='raw-bt-latency-', dir='/tmp') as folder:
        path = str(Path(folder) / 'pointer.sock')
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as receiver:
            receiver.bind(path)
            receiver.setblocking(False)
            async with await open_driver_transport(transport_name) as transport:
                if not getattr(transport.source, 'timestamped', False):
                    raise RuntimeError('The USB broker must support receive timestamps')
                device = Device.from_config_with_hci(configuration(classic_enabled=True),
                                                     transport.source, transport.sink)
                device.keystore = JsonKeyStore('RawBluetooth', filename=str(data_directory() / 'driver-bonds.json'))
                address = hci.Address(args.address)
                if not await device.keystore.get(str(address)):
                    raise RuntimeError('Use the address of an already bonded mouse')
                await device.power_on()
                sender = SocketPointer(path)
                ready = asyncio.Event()

                def observe(state, **_):
                    if state == 'connected':
                        ready.set()

                connected = asyncio.create_task(use_mouse(
                    device, address, SimpleNamespace(dry_run=False, device_kind='Mouse'),
                    sender, observe))
                readiness = asyncio.create_task(ready.wait())
                launch = None
                try:
                    await asyncio.wait((connected, readiness), timeout=30,
                                       return_when=asyncio.FIRST_COMPLETED)
                    if connected.done():
                        connected.result()
                    if not ready.is_set():
                        raise TimeoutError('Mouse did not connect')
                    if args.discovery:
                        await device.start_scanning(legacy=True, active=True, scan_interval=10, scan_window=10)
                        await device.start_discovery(auto_restart=False)
                    print('Move the mouse continuously now', flush=True)
                    launch_at = None
                    if args.launch:
                        async def launch_app():
                            nonlocal launch_at
                            await asyncio.sleep(args.seconds / 2)
                            launch_at = input_clock_ns()
                            process = await asyncio.create_subprocess_exec('/usr/bin/open', '-a', args.launch)
                            if await process.wait():
                                raise RuntimeError(f'Cannot open {args.launch}')
                        launch = asyncio.create_task(launch_app())
                    samples = []
                    loop = asyncio.get_running_loop()
                    deadline = loop.time() + args.seconds
                    while loop.time() < deadline:
                        try:
                            packet = await asyncio.wait_for(loop.sock_recv(receiver, 4096),
                                                            deadline - loop.time())
                        except asyncio.TimeoutError:
                            break
                        if len(packet) == 28 and packet[:3] == b'\x01\x01\x00':
                            samples.append((input_clock_ns(), struct.unpack_from('<Q', packet, 20)[0]))
                    if launch:
                        await launch
                    if connected.done():
                        connected.result()
                        raise RuntimeError('Mouse disconnected during measurement')
                    label = 'Discovery on' if args.discovery else 'Discovery off'
                    if launch_at is None:
                        return summarize(label, samples)
                    before = summarize(f'{label}, before launch', [s for s in samples if s[0] < launch_at])
                    after = summarize(f'{label}, from launch', [s for s in samples if s[0] >= launch_at])
                    return before and after
                finally:
                    if launch:
                        launch.cancel()
                        await asyncio.gather(launch, return_exceptions=True)
                    readiness.cancel()
                    connected.cancel()
                    await asyncio.gather(readiness, connected, return_exceptions=True)
                    await sender.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('address', help='Address of the bonded mouse')
    parser.add_argument('--seconds', type=int, choices=range(4, 16), default=10, metavar='4–15')
    parser.add_argument('--discovery', action='store_true')
    parser.add_argument('--launch', metavar='APP')
    raise SystemExit(0 if asyncio.run(run(parser.parse_args())) else 1)
