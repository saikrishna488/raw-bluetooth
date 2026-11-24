"""Standalone A2DP playback helpers for classic Bluetooth audio sinks."""
import asyncio
import logging
from pathlib import Path
import sys

from bumble import a2dp, avdtp
from bumble.device import PhysicalTransport

log = logging.getLogger(__name__)


def sbc_configuration():
    info = a2dp.SbcMediaCodecInformation
    return avdtp.MediaCodecCapabilities(
        media_type=avdtp.AVDTP_AUDIO_MEDIA_TYPE,
        media_codec_type=a2dp.A2DP_SBC_CODEC_TYPE,
        media_codec_information=info(
            sampling_frequency=info.SamplingFrequency.SF_44100,
            channel_mode=info.ChannelMode.JOINT_STEREO,
            block_length=info.BlockLength.BL_16,
            subbands=info.Subbands.S_8,
            allocation_method=info.AllocationMethod.LOUDNESS,
            minimum_bitpool_value=2,
            maximum_bitpool_value=53,
        ),
    )


async def _read_exact(stream, size):
    result = bytearray()
    while len(result) < size:
        chunk = await stream.read(size - len(result))
        if not chunk:
            break
        result.extend(chunk)
    if len(result) != size:
        log.info('A2DP encoder reached EOF after %d of %d requested bytes', len(result), size)
    return bytes(result)


class A2DPTestTone:
    """Connect to a classic A2DP sink and stream a local file or test tone."""

    def __init__(self, device, address, audio_file=None, system_fifo=None):
        self.audio_file = validate_audio_file(audio_file) if audio_file is not None else None
        self.system_fifo = Path(system_fifo) if system_fifo else None
        self.device = device
        self.address = address
        self.connection = None
        self.protocol = None
        self.stream = None
        self.process = None
        self.pump = None
        self.packet_count = 0
        self.prefetched_sbc = bytearray()

    async def packets_with_diagnostics(self, packets):
        async for packet in packets:
            self.packet_count += 1
            if self.packet_count == 1 or self.packet_count % 100 == 0:
                log.info('Sending A2DP RTP packet #%d', self.packet_count)
            yield packet

    async def read_sbc(self, size):
        """Read encoder bytes, consuming the pre-stream startup buffer first."""
        prefix = bytes(self.prefetched_sbc[:size])
        del self.prefetched_sbc[:len(prefix)]
        if len(prefix) == size:
            return prefix
        return prefix + await _read_exact(self.process.stdout, size - len(prefix))

    async def start(self):
        log.info('Opening BR/EDR A2DP link to %s', self.address)
        self.connection = await self.device.connect(
            self.address, transport=PhysicalTransport.BR_EDR, timeout=20
        )
        await self.connection.authenticate()
        await self.connection.encrypt()
        log.info('A2DP link authenticated and encrypted for %s', self.address)
        self.protocol = await avdtp.Protocol.connect(self.connection)
        endpoints = await self.protocol.discover_remote_endpoints()
        sink = self.protocol.find_remote_sink_by_codec(
            avdtp.AVDTP_AUDIO_MEDIA_TYPE, a2dp.A2DP_SBC_CODEC_TYPE
        )
        if sink is None:
            codecs = [
                str(cap.media_codec_type)
                for endpoint in endpoints
                for cap in endpoint.capabilities
                if isinstance(cap, avdtp.MediaCodecCapabilities)
            ]
            raise RuntimeError(
                'The device did not offer an available SBC A2DP audio sink'
                + (f' (reported codecs: {", ".join(codecs)})' if codecs else '')
            )

        ffmpeg = ffmpeg_executable()
        if self.system_fifo:
            # Live FIFO: no -re (data already arrives in real-time; -re would
            # throttle reads, back-pressure the writer, and stall callbacks).
            input_args = ['-f', 'f32le', '-ar', '48000', '-ac', '2', '-i', str(self.system_fifo)]
            rate_flags = []
        elif self.audio_file:
            input_args = ['-i', str(self.audio_file)]
            rate_flags = ['-re']
        else:
            input_args = ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100']
            rate_flags = ['-re']
        self.process = await asyncio.create_subprocess_exec(
            ffmpeg,
            '-hide_banner', '-loglevel', 'warning', *rate_flags, *input_args,
            '-vn',
            '-ac', '2', '-ar', '44100', '-c:a', 'sbc', '-f', 'sbc', 'pipe:1',
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        log.info('Started SBC encoder pid=%s for %s', self.process.pid, self.address)
        self.stderr_task = asyncio.create_task(self._drain_stderr())
        # Some sinks suspend after a few seconds without RTP. Prime the
        # encoder before negotiating A2DP, then the first RTP packet is ready
        # as soon as the stream enters STREAMING.
        self.prefetched_sbc.extend(await asyncio.wait_for(
            _read_exact(self.process.stdout, 4), timeout=8
        ))
        if len(self.prefetched_sbc) != 4:
            raise RuntimeError('SBC encoder ended before producing an audio frame')
        log.info('SBC encoder primed before A2DP stream setup')
        packets = a2dp.SbcPacketSource(
            self.read_sbc, mtu=672
        )
        self.pump = avdtp.MediaPacketPump(self.packets_with_diagnostics(packets.packets))
        source = self.protocol.add_source(sbc_configuration(), self.pump)
        source.on(source.EVENT_SUSPEND, lambda: log.warning('Audio sink requested A2DP suspend'))
        source.on(source.EVENT_ABORT, lambda: log.warning('Audio sink aborted the A2DP stream'))
        self.connection.on('disconnection', lambda reason: log.warning('A2DP Bluetooth link ended: %s', reason))
        self.stream = await self.protocol.create_stream(source, sink)
        await self.stream.start()
        log.info('A2DP stream started: state=%s', self.stream.state)

    async def _drain_stderr(self):
        try:
            while self.process and self.process.returncode is None:
                line = await self.process.stderr.readline()
                if not line:
                    break
                text = line.decode(errors='replace').strip()
                if text:
                    log.warning('ffmpeg: %s', text)
        except asyncio.CancelledError:
            pass
        except Exception:
            log.debug('stderr drain failed', exc_info=True)

    async def close(self):
        # Release every resource even if the peer has already disconnected.
        log.info('Closing A2DP session: stream_state=%s encoder_status=%s packets=%d',
                 getattr(self.stream, 'state', 'none'),
                 self.process.returncode if self.process else 'none', self.packet_count)
        if getattr(self, 'stderr_task', None):
            self.stderr_task.cancel()
        try:
            if self.pump:
                await self.pump.stop()
            if self.stream and self.stream.state == avdtp.State.STREAMING:
                await asyncio.wait_for(self.stream.stop(), 3)
            if self.stream and self.stream.state in (avdtp.State.OPEN, avdtp.State.CONFIGURED):
                await asyncio.wait_for(self.stream.close(), 3)
        except Exception:
            log.debug('Audio stream already closed', exc_info=True)
        finally:
            if self.process and self.process.returncode is None:
                try:
                    self.process.terminate()
                except ProcessLookupError:
                    pass
                try:
                    await asyncio.wait_for(self.process.wait(), 2)
                except asyncio.TimeoutError:
                    self.process.kill()
                    await self.process.wait()
            if self.process and self.process.stderr:
                try:
                    err = await asyncio.wait_for(self.process.stderr.read(), 1)
                    if err:
                        log.warning('ffmpeg: %s', err.decode(errors='replace').strip())
                except Exception:
                    pass
            if self.connection:
                try:
                    await asyncio.wait_for(self.connection.disconnect(), 3)
                except Exception:
                    log.debug('Audio link already closed', exc_info=True)


def validate_audio_file(value):
    if not isinstance(value, (str, Path)) or not str(value):
        raise ValueError('Choose a local WAV, MP3, FLAC, or M4A audio file.')
    path = Path(value).expanduser().resolve()
    if path.suffix.lower() not in ('.wav', '.mp3', '.flac', '.m4a') or not path.is_file():
        raise ValueError('Choose an existing WAV, MP3, FLAC, or M4A audio file.')
    return path


def ffmpeg_executable():
    if getattr(sys, 'frozen', False):
        return str(Path(sys._MEIPASS) / 'ffmpeg')
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()
