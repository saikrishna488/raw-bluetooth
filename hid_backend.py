"""Select the compiled HID implementation when installed."""
import os

if os.environ.get('RAW_BLUETOOTH_PYTHON_HID') == '1':
    from hid_mouse import MouseReports
    from hid_keyboard import KeyboardReports
else:
    try:
        import _hid_native
    except ModuleNotFoundError as exc:
        if exc.name != '_hid_native':
            raise
        from hid_mouse import MouseReports
        from hid_keyboard import KeyboardReports
    else:
        from native_hid import MouseReports, KeyboardReports
