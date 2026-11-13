"""Keep installed-app state outside its read-only application bundle."""
import os
import logging
from pathlib import Path


def data_directory():
    override = os.environ.get('RAW_BLUETOOTH_DATA_DIR')
    return Path(override) if override else Path(__file__).resolve().parent


def write_diagnostic(name, text):
    """Replace legacy root-owned dumps without making diagnostics fatal to HID."""
    from native_backend import call
    try:
        call('diagnostic', {'path': str(data_directory() / name), 'text': text})
    except OSError:
        logging.warning('Could not save diagnostic %s; continuing connection', name, exc_info=True)
