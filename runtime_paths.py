"""Keep installed-app state outside its read-only application bundle."""
import os
from pathlib import Path


def data_directory():
    override = os.environ.get('RAW_BLUETOOTH_DATA_DIR')
    return Path(override) if override else Path(__file__).resolve().parent
