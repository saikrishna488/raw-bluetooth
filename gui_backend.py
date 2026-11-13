"""Async Bumble protocol bridge for the native Raw Bluetooth backend.

The normal-user GUI writes a small command file. This worker publishes discovery
and connection events to a separate JSONL file; neither channel exposes bond keys.
"""
import argparse
import asyncio
import json
import logging
import os
from pathlib import Path
import signal
import time
from types import SimpleNamespace

from bumble import hci
from bumble.core import AdvertisingData
from bumble.device import Device
from bumble.pairing import PairingConfig, PairingDelegate
from usb_service import open_driver_transport as open_transport
from m196_driver import SocketPointer, configuration, use_mouse
from saved_devices import SavedDevices
from runtime_paths import data_directory
from adapters import select_transport, migrate_bonds, forget_bond
from bumble.keys import JsonKeyStore
from audio_stream import A2DPTestTone, validate_audio_file
from native_backend import call, EventJournal


def advertisement_info(adv, previous=None):
    name = adv.data.get(AdvertisingData.COMPLETE_LOCAL_NAME) or adv.data.get(AdvertisingData.SHORTENED_LOCAL_NAME) or ''
    if isinstance(name, bytes):
        name = name.decode('utf-8', 'replace')
    return call('advertisement', {'previous': previous or {}, 'name': name, 'raw': list(adv.data_bytes),
                                 'address': str(adv.address), 'rssi': adv.rssi, 'connectable': bool(adv.is_connectable),
                                 'scan_response': bool(getattr(adv, 'is_scan_response', False)), 'now': time.time()})


def read_command(path, last_id):
    return call('command', {'path': str(path), 'last_id': last_id})


class DisplayPasskey(PairingDelegate):
    def __init__(self, backend, address):
        super().__init__(PairingDelegate.DISPLAY_OUTPUT_ONLY)
        self.backend, self.address = backend, address

    async def display_number(self, number, digits):
        self.backend.emit('passkey', address=self.address, code=f'{number:0{digits}d}')


class DeviceOutput:
    def __init__(self, path, address):
        self.output, self.address = SocketPointer(path), address

    def apply(self, report):
        self.output.apply(dict(report, device=self.address))

    def release(self):
        self.output.apply({'kind': 'release', 'device': self.address})

    async def close(self):
        await self.output.close()


class Backend:
    def __init__(self, folder, transport, saved_path=None):
        self.folder, self.transport_name = folder, transport
        self.events = EventJournal(folder / 'events.jsonl')
        self.device = None
        self.devices, self.addresses, self.last_emitted = {}, {}, {}
        self.scanning = False
        self.connection_tasks = {}
        self.stopping = False
        self.pointer = None
        self.scan_lock = asyncio.Lock()
        self.saved = SavedDevices(saved_path or data_directory() / 'saved-devices.json')
        self.manual_pause = set()
        self.retry_at, self.retry_count = {}, {}
        self.connecting_key = None
        self.audio_tasks = {}

    def emit(self, state, **details):
        self.events.emit(state, details)

    def advertisement(self, adv):
        key = str(adv.address)
        previous = self.devices.get(key) or self.saved.devices.get(key)
        info = advertisement_info(adv, previous)
        # Discard anonymous broadcast-only beacons. Keep known devices and
        # audio candidates so a Classic inquiry can identify them separately.
        if not info['name'] and key not in self.saved.devices:
            self.devices.pop(key, None)
            self.addresses.pop(key, None)
            return
        self.devices[key] = info
        # Keep the Classic inquiry address object for A2DP when the same AirPods
        # also send BLE advertisements.
        if previous is None or previous.get('category') != 'Audio':
            self.addresses[key] = adv.address
        now = time.monotonic()
        changed = previous is None or info['name'] != previous['name'] or info['category'] != previous['category']
        if changed or now - self.last_emitted.get(key, 0) > 1:
            self.last_emitted[key] = now
            self.emit('device', **info)

    def inquiry_result(self, address, class_of_device, data, rssi):
        name = data.get(AdvertisingData.COMPLETE_LOCAL_NAME) or data.get(AdvertisingData.SHORTENED_LOCAL_NAME) or ''
        if isinstance(name, bytes):
            name = name.decode('utf-8', 'replace')
        key = str(address)
        info = call('inquiry', {'name': name, 'address': key, 'class': class_of_device, 'rssi': rssi, 'now': time.time()})
        if info is not None:
            self.devices[key], self.addresses[key] = info, address
            self.emit('device', **info)

    async def audio_test(self, key, audio_file=None, system_fifo=None):
        if key not in self.addresses or self.devices.get(key, {}).get('category') != 'Audio':
            raise ValueError('Select a discovered Bluetooth audio device first.')
        if key in self.audio_tasks and not self.audio_tasks[key].done():
            return
        if audio_file is not None:
            audio_file = validate_audio_file(audio_file)
        # The USB controller cannot reliably maintain BLE discovery while
        # opening a BR/EDR A2DP ACL. Stop both scan modes before connecting.
        await self.pause()
        # LE reports may represent a public identity address with type 0x02.
        # BR/EDR connection commands require the same six bytes as a public
        # device address (type 0x00).
        classic_address = hci.Address(key.split('/')[0], hci.Address.PUBLIC_DEVICE_ADDRESS)
        task = asyncio.create_task(self.play_audio_test(key, classic_address, audio_file, system_fifo))
        self.audio_tasks[key] = task

    async def play_audio_test(self, key, address, audio_file=None, system_fifo=None):
        session = A2DPTestTone(self.device, address, audio_file, system_fifo)
        self.emit('audio_connecting', address=key)
        try:
            await session.start()
            self.emit('audio_connected', address=key, message='System audio routed over A2DP' if system_fifo else 'A2DP connected · playing audio' if audio_file else 'A2DP connected · playing test tone')
            await session.pump.pump_task
            pump_exc = session.pump.pump_task.exception() if session.pump.pump_task.done() and not session.pump.pump_task.cancelled() else None
            logging.info('A2DP pump finished: exc=%s, ffmpeg returncode=%s', pump_exc, session.process.returncode if session.process else None)
            if system_fifo:
                # System-audio FIFO: the pump ends when the capture stops or the
                # user disconnects — not an error.
                self.emit('audio_finished', address=key)
            elif audio_file and await asyncio.wait_for(session.process.wait(), 3) == 0:
                self.emit('audio_finished', address=key)
            else:
                encoder_status = session.process.returncode if session.process else 'unknown'
                stream_state = getattr(session.stream, 'state', 'unknown')
                if encoder_status is None:
                    raise RuntimeError(f'The AirPods stopped the A2DP stream (stream state {stream_state}). Check that system-audio recording is allowed and try again.')
                raise RuntimeError(f'A2DP media sender stopped unexpectedly (encoder status {encoder_status}, stream state {stream_state}).')
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logging.exception('A2DP connection failed')
            self.emit('audio_error', address=key, message=f'Could not start Bluetooth audio: {exc}')
        finally:
            try:
                await session.close()
            finally:
                self.audio_tasks.pop(key, None)
                self.emit('audio_disconnected', address=key)
                if not self.stopping:
                    await self.resume_scan()

    async def disconnect_audio(self, key=None):
        keys = [key] if key else list(self.audio_tasks)
        tasks = [self.audio_tasks[k] for k in keys if k in self.audio_tasks]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    async def forget_device(self, key):
        if not key:
            raise ValueError('Choose a saved device to forget.')
        await self.disconnect_audio(key)
        await self.disconnect(key)
        self.saved.forget(key)
        forget_bond(data_directory() / 'driver-bonds.json', key)
        self.manual_pause.discard(key)
        self.retry_at.pop(key, None)
        self.retry_count.pop(key, None)
        self.emit('forgotten', address=key)

    async def scan(self):
        async with self.scan_lock:
            if self.stopping:
                return
            if not self.scanning:
                await self.device.start_scanning(legacy=True, active=True, scan_interval=10, scan_window=10)
                self.scanning = True
            if self.device.classic_enabled and not self.device.discovering:
                # A continuous BR/EDR inquiry loop conflicts with this adapter's
                # audio ACL sessions. Run one inquiry per explicit Scan action.
                await self.device.start_discovery(auto_restart=False)

    def expire_devices(self):
        for key in call('expire', {'devices': self.devices, 'saved': self.saved.devices, 'now': time.time()}):
            self.devices.pop(key, None)
            self.addresses.pop(key, None)
            self.emit('device_removed', address=key)

    async def stop_classic_inquiry(self):
        if self.device and self.device.discovering:
            self.device.auto_restart_inquiry = False
            await self.device.send_command(hci.HCI_Inquiry_Cancel_Command(), check_result=True)
            self.device.discovering = False
        self.emit('scanning')

    async def pause(self):
        async with self.scan_lock:
            if self.scanning:
                await self.device.stop_scanning()
                self.scanning = False
            await self.stop_classic_inquiry()

    async def resume_scan(self):
        try:
            await self.scan()
        except Exception as exc:
            self.emit('error', message=f'Could not resume discovery: {exc}')

    async def disconnect(self, address=None, manual=True):
        targets = [address] if address is not None else list(self.connection_tasks)
        if manual:
            self.manual_pause.update(targets)
        tasks = [self.connection_tasks[key] for key in targets if key in self.connection_tasks]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        for key in targets:
            self.connection_tasks.pop(key, None)
            self.emit('disconnected', address=key)

    async def connect(self, key, automatic=False):
        if key not in self.addresses:
            raise ValueError('Device is no longer in this scan. Scan again and select it.')
        if not self.devices[key]['connectable']:
            raise ValueError('This device is broadcasting only and does not accept connections.')
        if key in self.connection_tasks and not self.connection_tasks[key].done():
            return
        if self.connecting_key is not None:
            raise ValueError('Another input device is still connecting')
        if not automatic:
            self.manual_pause.discard(key)
            self.retry_count.pop(key, None)
        self.connecting_key = key
        try:
            await self.pause()
        except Exception:
            self.connecting_key = None
            raise
        self.connection_tasks[key] = asyncio.create_task(self.connection(key, automatic))

    def remember(self, key, enabled=None):
        info = self.devices.get(key) or self.saved.devices.get(key)
        if not info or info['category'] not in ('Mouse', 'Keyboard'):
            raise ValueError('Connect this input device before saving it')
        record = self.saved.remember(info, enabled)
        if enabled:
            self.manual_pause.discard(key)
        self.emit('saved', **record)

    def reconnect_candidates(self, now=None):
        return call('reconnect', {'now': time.time() if now is None else now, 'saved': self.saved.devices,
                                  'devices': self.devices, 'paused': list(self.manual_pause),
                                  'tasks': list(self.connection_tasks), 'retry_at': self.retry_at})

    async def auto_reconnect(self):
        if self.stopping or not self.scanning or self.connecting_key or not (self.folder / 'pointer.sock').exists():
            return
        for key in self.reconnect_candidates():
            # Reconnect only known bonds; never auto-pair an unknown advertiser.
            keys = await self.device.keystore.get(key)
            if not keys or (keys.ltk is None and keys.ltk_central is None):
                self.emit('reconnect_wait', address=key, message='Pair this device again to restore its saved bond')
                self.retry_at[key] = time.time() + 60
                continue
            self.emit('reconnecting', address=key)
            try:
                await self.connect(key, automatic=True)
            except Exception:
                self.retry_at[key] = time.time() + 5
                self.emit('reconnect_wait', address=key, message='Waiting to retry the connection')
            break

    def pairing_config(self, connection):
        key = str(connection.peer_address)
        keyboard = self.devices.get(key, {}).get('category') == 'Keyboard'
        return PairingConfig(sc=True, mitm=keyboard, bonding=True,
                             delegate=DisplayPasskey(self, key) if keyboard else PairingDelegate(PairingDelegate.NO_OUTPUT_NO_INPUT))

    async def connection(self, key, automatic=False):
        pointer = None
        try:
            pointer = DeviceOutput(str(self.folder / 'pointer.sock'), key)
            args = SimpleNamespace(dry_run=False, device_kind=self.devices[key]['category'])
            def observe(state, **details):
                details.setdefault('address', key)
                self.emit(state, **details)
                if state == 'connected':
                    self.connecting_key = None
                    self.retry_count.pop(key, None)
                    self.remember(key)
                if state == 'pairing' and not self.stopping:
                    # LE scanning resumes after link establishment, so another
                    # input device can be discovered while this one stays connected.
                    asyncio.create_task(self.resume_scan())
            await use_mouse(self.device, self.addresses[key], args, pointer, observe)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logging.exception('Connection failed')
            if automatic:
                self.emit('reconnect_wait', address=key, message='Waiting for the device to wake or become available')
            else:
                self.emit('error', address=key, message=f'Could not connect this device: {exc}')
        finally:
            if pointer:
                await pointer.close()
            self.connection_tasks.pop(key, None)
            if self.connecting_key == key:
                self.connecting_key = None
            attempts = self.retry_count.get(key, 0) + 1
            self.retry_count[key] = attempts
            self.retry_at[key] = time.time() + min(30, 2 ** min(attempts, 5))
            self.emit('disconnected', address=key)
            if not self.stopping:
                await self.resume_scan()

    async def run(self):
        # The command-line driver may be running; request its normal cleanup first.
        (data_directory() / 'driver.stop').touch()
        self.emit('starting', message='Taking control of the USB Bluetooth adapter…')
        self.transport_name, native_audio = await asyncio.to_thread(select_transport, self.transport_name)
        self.emit('adapter', transport=self.transport_name, native_audio=native_audio)
        transport = None
        for attempt in range(30):
            try:
                transport = await open_transport(self.transport_name)
                break
            except Exception:
                if attempt == 29:
                    raise
                await asyncio.sleep(0.5)
        async with transport:
            self.device = Device.from_config_with_hci(configuration(classic_enabled=True), transport.source, transport.sink)
            bonds = data_directory() / 'driver-bonds.json'
            migrate_bonds(bonds, self.saved.devices)
            self.device.keystore = JsonKeyStore('RawBluetooth', filename=str(bonds))
            self.device.pairing_config_factory = self.pairing_config
            self.device.on('advertisement', self.advertisement)
            self.device.on('inquiry_result', self.inquiry_result)
            try:
                await asyncio.wait_for(self.device.power_on(), 20)
                self.emit('ready')
                for key, info in self.saved.devices.items():
                    self.emit('saved', **info)
                    self.devices[key] = dict(info, rssi=-127, connectable=True, last_seen=0)
                    self.addresses[key] = hci.Address(key)
                    self.emit('device', **self.devices[key])
                await self.scan()
                last_id = None
                last_heartbeat = time.monotonic()
                while not self.stopping:
                    # A closed/crashed GUI stops renewing this lease. Release USB.
                    heartbeat = self.folder / 'heartbeat'
                    try:
                        if heartbeat.stat().st_mtime > time.time() - 10:
                            last_heartbeat = time.monotonic()
                    except FileNotFoundError:
                        pass
                    if time.monotonic() - last_heartbeat > 15:
                        self.emit('session_ending', reason='heartbeat_expired',
                                  message='Adapter released because the app heartbeat expired')
                        break
                    command = read_command(self.folder / 'command.json', last_id)
                    if command:
                        last_id = command['id']
                        try:
                            action = command['action']
                            if action == 'stop':
                                self.emit('session_ending', reason='stop_command',
                                          message='Adapter released by an app Stop command')
                                break
                            if action == 'scan':
                                await self.scan()
                            elif action == 'pause':
                                await self.pause()
                                self.emit('paused')
                            elif action == 'connect':
                                await self.connect(command.get('address'))
                            elif action == 'disconnect':
                                await self.disconnect(command.get('address'))
                                await self.scan()
                            elif action == 'remember':
                                if not isinstance(command.get('enabled'), bool):
                                    raise ValueError('Reconnect preference must be true or false')
                                self.remember(command.get('address'), command['enabled'])
                            elif action == 'audio_test':
                                await self.audio_test(command.get('address'))
                            elif action == 'audio_play':
                                await self.audio_test(command.get('address'), validate_audio_file(command.get('path')))
                            elif action == 'audio_system':
                                fifo = Path(command.get('path', ''))
                                if self.folder not in fifo.parents:
                                    raise ValueError('Invalid system-audio stream path')
                                await self.audio_test(command.get('address'), system_fifo=fifo)
                            elif action == 'audio_disconnect':
                                await self.disconnect_audio(command.get('address'))
                            elif action == 'forget':
                                await self.forget_device(command.get('address'))
                        except Exception as exc:
                            self.emit('error', message=str(exc))
                    await self.auto_reconnect()
                    self.expire_devices()
                    await asyncio.sleep(0.2)
            finally:
                self.stopping = True
                await self.disconnect_audio()
                await self.disconnect(manual=False)
                try:
                    await self.pause()
                    await asyncio.wait_for(self.device.host.send_command(hci.HCI_Reset_Command(), check_result=True), 4)
                except Exception:
                    logging.exception('Controller cleanup')
                self.emit('stopped')


async def main(args):
    os.umask(0o077)
    backend = Backend(args.session, args.transport)
    task = asyncio.create_task(backend.run())
    for sig in (signal.SIGTERM, signal.SIGINT):
        asyncio.get_running_loop().add_signal_handler(sig, task.cancel)
    try:
        await task
    except asyncio.CancelledError:
        backend.emit('session_ending', reason='signal', message='Adapter worker received a shutdown signal')
    except Exception as exc:
        backend.emit('error', message=str(exc))
        raise
    finally:
        backend.events.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session', type=Path, required=True)
    parser.add_argument('--transport', default='auto')
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO)
    asyncio.run(main(args))
