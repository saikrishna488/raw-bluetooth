## What’s new in v0.6.0

- Detects external standard USB Bluetooth HCI adapters beyond the previously hardcoded CSR USB ID.
- Adds a saved USB ID selection under Settings → USB adapter for setups with several dongles.
- Shows the selected adapter in the sidebar and adds automatic selection to the mouse and audio CLIs.
- Excludes internal/unknown controllers, Apple radios, and ambiguous duplicate USB IDs; validates standard HCI event/ACL endpoints before selection.
- Makes Settings scrollable on smaller displays.

## Installation and limitations

Download the Intel macOS DMG, open it, and drag Raw Bluetooth to Applications. Python and a source checkout are not required. The installer bundles the Python backend, native C++ HID decoder, libusb, FFmpeg, third-party notices, and a SHA-256 checksum.

Requires Intel macOS 13+, a logged-in desktop session, and an external USB Bluetooth controller exposing a standard HCI interface. CSR `0a12:0001` remains the only hardware-verified adapter. Other vendors are detected by interface, but pairing, HID, and audio still require real-hardware validation. Vendor firmware loading and nonstandard interfaces are not supported; a detected controller may still fail initialization. Audio requires a BR/EDR-capable controller and compatible A2DP sink.

**Experimental and not notarized:** the app is ad-hoc signed. macOS may require Open Anyway in System Settings → Privacy & Security. Grant Accessibility permission and authorize USB access when starting a session. Experimental system audio routing also requires Screen & System Audio Recording permission. Classic Bluetooth HID, login-screen input, and microphones remain unsupported. Development-checkout pairings are not migrated automatically.

## Validation

49 Python tests and Swift compilation passed. Installer verification checks the signature, bundled backend, USB library, FFmpeg, and private-data exclusions. These checks do not establish compatibility with untested adapters.

Full changelog: https://github.com/saikrishna488/raw-bluetooth/compare/v0.5.0...v0.6.0
