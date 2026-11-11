import asyncio
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

from audio_stream import A2DPTestTone, validate_audio_file
from gui_backend import Backend


class AudioTests(unittest.IsolatedAsyncioTestCase):
    def test_only_existing_supported_local_files(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'track.wav'
            path.write_bytes(b'')
            self.assertEqual(validate_audio_file(str(path)), path.resolve())
            for value in (None, '', 'https://example.com/track.wav', str(path.with_suffix('.exe'))):
                with self.assertRaises(ValueError):
                    validate_audio_file(value)

    async def test_cleanup_releases_encoder_and_link_after_stream_failure(self):
        session = A2DPTestTone(None, None)
        session.pump = SimpleNamespace(stop=AsyncMock(side_effect=RuntimeError('closed')))
        session.process = SimpleNamespace(returncode=None, terminate=lambda: None, wait=AsyncMock(return_value=0), stderr=None)
        session.connection = SimpleNamespace(disconnect=AsyncMock())
        await session.close()
        session.process.wait.assert_awaited_once()
        session.connection.disconnect.assert_awaited_once()

    async def test_file_completion_and_encoder_failure(self):
        for status in (0, 1):
            backend = Backend.__new__(Backend)
            backend.device = None
            backend.stopping = False
            backend.resume_scan = AsyncMock()
            backend.audio_tasks = {'sink': asyncio.current_task()}
            events = []
            backend.emit = lambda event, **kwargs: events.append(event)
            pump_task = asyncio.create_task(asyncio.sleep(0))
            session = SimpleNamespace(start=AsyncMock(), close=AsyncMock(),
                                      pump=SimpleNamespace(pump_task=pump_task),
                                      process=SimpleNamespace(wait=AsyncMock(return_value=status), returncode=status))
            with patch('gui_backend.A2DPTestTone', return_value=session), patch('gui_backend.logging.exception'):
                await backend.play_audio_test('sink', None, 'track.wav')
            self.assertIn('audio_finished' if status == 0 else 'audio_error', events)
            self.assertEqual(events[-1], 'audio_disconnected')
            self.assertEqual(backend.audio_tasks, {})
            session.close.assert_awaited_once()


if __name__ == '__main__':
    unittest.main()
