"""CLI diagnostic for Classic Bluetooth audio discovery and A2DP playback."""
import argparse
import asyncio
import logging
from pathlib import Path

from bumble import hci
from bumble.core import AdvertisingData
from bumble.device import Device, PhysicalTransport
from bumble.pairing import PairingConfig, PairingDelegate
from bumble.transport import open_transport
from bumble.keys import JsonKeyStore

from audio_stream import A2DPTestTone
from m196_driver import configuration


def local_name(data):
    name = data.get(AdvertisingData.COMPLETE_LOCAL_NAME) or data.get(AdvertisingData.SHORTENED_LOCAL_NAME) or ''
    return name.decode('utf-8', 'replace') if isinstance(name, bytes) else name


async def run(args):
    async with await open_transport(args.transport) as transport:
        device = Device.from_config_with_hci(
            configuration(classic_enabled=True), transport.source, transport.sink
        )
        device.keystore = JsonKeyStore('RawBluetooth', filename=str(Path(__file__).parent / 'driver-bonds.json'))
        device.pairing_config_factory = lambda _: PairingConfig(
            sc=True, mitm=False, bonding=True,
            delegate=PairingDelegate(PairingDelegate.NO_OUTPUT_NO_INPUT),
        )
        found = asyncio.get_running_loop().create_future()
        inquiry_complete = asyncio.Event()
        seen = set()

        def inquiry_result(address, class_of_device, data, rssi):
            name = local_name(data)
            major_class = (class_of_device >> 8) & 0x1F
            print(f'CLASSIC result: {name!r} address={address} RSSI={rssi} CoD=0x{class_of_device:06X}', flush=True)
            is_airpods = 'airpod' in name.lower()
            is_audio_class = major_class == 4
            if not (is_airpods or is_audio_class):
                return
            label = 'AirPods' if is_airpods else 'audio-class candidate'
            print(f'CLASSIC {label}: {name!r} address={address} RSSI={rssi} CoD=0x{class_of_device:06X}', flush=True)
            if not found.done():
                classic = hci.Address(str(address).split('/')[0], hci.Address.PUBLIC_DEVICE_ADDRESS)
                found.set_result((name, classic))

        def advertisement(adv):
            name = local_name(adv.data)
            if 'airpod' in name.lower():
                line = f'BLE AirPods: {name!r} address={adv.address} type={adv.address.address_type} connectable={adv.is_connectable} RSSI={adv.rssi}'
                if line not in seen:
                    seen.add(line)
                    print(line, flush=True)

        def classic_scan_complete():
            inquiry_complete.set()

        device.on('inquiry_result', inquiry_result)
        device.on('inquiry_complete', classic_scan_complete)
        device.on('advertisement', advertisement)
        await asyncio.wait_for(device.power_on(), 20)
        await device.start_scanning(legacy=True, active=True, scan_interval=10, scan_window=10)
        print(f'CLI scan active. Put AirPods in pairing mode; waiting up to {args.timeout} seconds.', flush=True)
        deadline = asyncio.get_running_loop().time() + args.timeout
        while not found.done() and asyncio.get_running_loop().time() < deadline:
            await device.start_discovery(auto_restart=False)
            inquiry_complete.clear()
            wait_found = asyncio.ensure_future(asyncio.shield(found))
            wait_complete = asyncio.create_task(inquiry_complete.wait())
            remaining = deadline - asyncio.get_running_loop().time()
            done, pending = await asyncio.wait(
                (wait_found, wait_complete), timeout=max(0.1, remaining),
                return_when=asyncio.FIRST_COMPLETED,
            )
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            if wait_found in done:
                break
            if not done:
                break
            await asyncio.sleep(1)
        if not found.done():
            print('No Classic AirPods inquiry result. BLE advertisements above are not sufficient for A2DP.', flush=True)
            return
        name, address = found.result()
        print(f'Connecting using BR/EDR PUBLIC address {address}', flush=True)
        session = A2DPTestTone(device, address)
        try:
            await session.start()
            print('A2DP/SBC stream started. The 440 Hz test tone should be audible.', flush=True)
            await session.pump.pump_task
            print('A2DP packet sender ended unexpectedly.', flush=True)
        finally:
            await session.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--transport', default='usb:0a12:0001')
    parser.add_argument('--timeout', type=int, default=45)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format='%(levelname)s %(name)s: %(message)s')
    try:
        asyncio.run(run(args))
    except Exception as exc:
        logging.exception('Audio CLI failed: %s', exc)
        raise
