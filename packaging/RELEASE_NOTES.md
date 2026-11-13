## What’s new in v0.7.0

- Moves USB brokering, IOKit/libusb adapter discovery, device classification, reconnect policy, private state persistence, event journaling, CLI pointer output, and ordered input delivery to C++17.
- Keeps the Swift GUI and Bumble Bluetooth protocol behavior. A Python async bridge and runtime are bundled in the app; no Python installation is required.
- Launchd runs the C++ USB broker directly after a one-time service update. No administrator prompt is needed for normal sessions.
- Preserves existing pairing files and saved-device formats. Optional diagnostic failures cannot disconnect HID devices.
- Adds native packet-framing, private-state, event-recovery, and real datagram-backpressure tests, plus sanitizer checks.

## Installation and limitations

Download the Intel macOS DMG, open it, and drag Raw Bluetooth to Applications. Python and a source checkout are not required. The installer bundles the C++ backend and USB broker, Python/Bumble protocol bridge, libusb, FFmpeg, third-party notices, and a SHA-256 checksum.

Requires Intel macOS 13+, a logged-in desktop session, and an external USB Bluetooth controller exposing a standard HCI interface. CSR `0a12:0001` remains the only hardware-verified adapter. Other vendors are detected by interface, but pairing, HID, and audio still require real-hardware validation. Vendor firmware loading and nonstandard interfaces are not supported; a detected controller may still fail initialization. Audio requires a BR/EDR-capable controller and compatible A2DP sink.

**Experimental and not notarized:** the app is ad-hoc signed. macOS may require Open Anyway in System Settings → Privacy & Security. Grant Accessibility permission and install/update USB access once in Settings. Normal sessions need no administrator prompt. Experimental system audio routing also requires Screen & System Audio Recording permission. Classic Bluetooth HID, login-screen input, and microphones remain unsupported. Development-checkout pairings are not migrated automatically.

## Validation

61 contract and integration tests passed. Native packet-framing and policy tests passed under AddressSanitizer and UndefinedBehaviorSanitizer. The installer passed read-only signature, bundled-runtime, USB-library, FFmpeg, and private-data checks without a checkout or Python on PATH. Live mouse input was verified through the native USB broker and C++ backend. The user confirmed sleep/wake reconnection without another administrator prompt on the development setup. Other adapters and macOS versions still require independent hardware testing.

Full changelog: https://github.com/saikrishna488/raw-bluetooth/compare/v0.6.0...v0.7.0
