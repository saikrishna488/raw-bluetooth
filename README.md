# Experimental M196 userspace driver

Direct USB HCI transport -> Google Bumble Bluetooth stack -> HID report-map
decoder -> CoreGraphics pointer events. Does not use CoreBluetooth or macOS
Bluetooth pairing. This is a userspace driver, not an installable kernel extension.

## Desktop app

Open `~/Applications/Raw Bluetooth.app`. Click **Scan devices** and authenticate
in the macOS administrator dialog. The app takes control of the CSR USB adapter
and discovers BLE devices directly, independently of System Settings.
The built-in Lite-On Bluetooth radio is excluded from raw sessions; this does
not disable or change the Mac's Wi-Fi interface.

Select a device to see its address, signal, type, and connection availability.
The sidebar's **Mouse speed** and **Scroll speed** sliders adjust raw pointer movement
and wheel scrolling independently, and keep their settings across app launches.
Use **Connect mouse** or **Connect keyboard** to pair/encrypt a BLE HID input
device. Mouse and keyboard connections can remain active together. The **Mice**,
**Keyboards**, and **Connectable** filters and name/address search narrow the list.
**Disconnect** returns to discovery; **Release adapter** gives USB back to macOS.
There is no session timer in the desktop app. Keep it running while you use the
devices. Successfully connected devices are saved with automatic reconnection
enabled by default. The **Saved** filter and per-device **Reconnect automatically**
switch control this preference. A saved device reconnects when it advertises after
waking or being powered on, using its existing bond; it does not repeat PIN pairing.
An intentional **Disconnect** pauses retries for that device until the next app
session or until you explicitly reconnect/re-enable automatic reconnection.

On a later app launch, saved devices start an adapter session automatically. macOS
may still require administrator authentication for USB access. To wake an already
paired device, move/click the mouse or press a keyboard key; do not hold the pairing
button unless you intend to pair again. If a device clears its bond or changes its
identity during re-pairing, connect it manually once to save the new identity.
The activity event stream is bounded and reconnect retries use a delay to avoid
continually retrying an unavailable device. Deep Mac sleep/USB controller resets
may require restarting the adapter session; this is not a system boot driver.

Closing the app requests cleanup; a heartbeat lease releases the adapter if the
app unexpectedly exits. Grant **Raw Bluetooth** access in Privacy & Security →
Accessibility before pointer output is available. GUI pointer events are posted
by the native app; Python Accessibility permission is not needed for the GUI.

For the Bluetooth Logitech K250, hold the Bluetooth button until its light blinks,
select it and click **Connect keyboard**. When the six-digit pairing code appears,
type it on the K250 and press Enter. Pairing can take up to two minutes. A connected
keyboard has a local test field for verifying typing. Keyboard reports support
standard key arrays, NKRO bitmaps, modifiers, repeat and common media usages.
Keypress contents are never written to the activity or driver logs.

Discovery includes BLE advertisers and Bluetooth Classic inquiry results for
audio devices. Input supports relative HID mice and BLE HID keyboards. The Audio
filter can connect to an A2DP SBC sink and play a built-in test tone directly
through the external adapter. This is standalone app playback; it does not yet
route all macOS system audio or expose the AirPods microphone as a macOS input.
HFP/SCO microphone audio and arbitrary GATT device control are not implemented.
Keyboard LED synchronization and vendor
specific Fn functions are not implemented. The GUI uses the existing saved host identity
and bonds; bond keys are never sent through GUI status events. Device preferences
are saved separately in `saved-devices.json` with owner-only permissions.

The app is locally built and signed, and depends on this source directory
and its `.venv`. Rebuild with `./gui/build.command` after moving the source or
changing the Swift UI. `gui/sign_app.py` maintains a dedicated private signing
identity in `.signing/`; the certificate's local trust policy is restricted to code
signing. Its certificate-pinned designated requirement stays stable across builds
so Accessibility authorization survives updates. Keep `.signing/` private and
preserve it across builds. Administrator authorization is requested once per
adapter session; the GUI and pointer output run as your normal user.

Implementation: `gui/RawBluetooth.swift` (native SwiftUI/AppKit),
`gui/PointerServer.swift` (native unprivileged pointer output), `gui_backend.py`
(exclusive USB HCI and BLE control), and `m196_driver.py` (pairing/HID support).
`pointer_bridge.py` remains available for the separate command-line launcher.

## Build and run

Requirements: macOS 13 or later, Xcode Command Line Tools (for `swiftc`),
Python 3.9 or later, and a supported USB Bluetooth adapter. The adapter is
exclusively controlled while a raw Bluetooth session is active.

From the checkout directory, create an environment and install the pinned
dependencies:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/pip install -r requirements-lock.txt
```

Build the desktop app with `./gui/build.command`. The script installs it under
`~/Applications/Raw Bluetooth.app` and creates a local development signing
identity in `.signing/`. This identity is specific to the local Mac and must
not be shared. The app embeds the checkout path during build, so rebuild after
moving the checkout. The command-line launcher also uses `.venv`.

## Command-line use

Double-click `Start M196 Driver.command` to start a session (up to 24 hours).
Authenticate in the macOS administrator dialog. Double-click
`Stop M196 Driver.command` to stop it and release the USB adapter. Reconnect
uses the observed mouse address as well as its advertised name.

From this directory, first verify live input without moving the system cursor:

```sh
sudo .venv/bin/python -u m196_driver.py --dry-run
```

Hold the M196 bottom button for three seconds until blinking. The program selects
connectable advertisements containing `M196`, encrypts/pairs, reads the HID report
descriptor and subscribes to input reports. Move and click the mouse after READY.
`--address ADDRESS` restricts selection to a specific device address.

To forward input into macOS:

```sh
# Terminal 1, as your normal user:
.venv/bin/python -u pointer_bridge.py --duration 3660
# Terminal 2, from this same directory:
sudo .venv/bin/python -u m196_driver.py --event-socket "$PWD/pointer.sock" --duration 3600
```

Pointer output requires macOS Accessibility permission for the normal user's Python
host. The root Bluetooth process forwards reports to the normal user's helper over
a local Unix socket restricted to its owner. Running pointer output directly as root
can be denied by macOS even when the normal user has permission. The default session
lasts 300 seconds; change with `--duration 3600`. Ctrl-C stops it. Saved host identity
and bonding keys are local files created with owner-only permissions.

To request the Accessibility permission prompt explicitly:

```sh
.venv/bin/python m196_driver.py --request-accessibility
```

First hardware test: direct USB scan, encrypted pairing, HID discovery and live
relative motion decoding succeeded with the M196 (report ID 3, six-byte payload).
End-to-end pointer output through the unprivileged helper was verified with a
five-pixel injection check and confirmed by the user moving the physical mouse.

The adapter is exclusively occupied while the driver runs; AirPods and other macOS
Bluetooth devices on that adapter cannot use it concurrently. Cleanup resets the
controller and releases USB ownership. If macOS does not reclaim it, unplug and
replug the adapter.

## Validation

```sh
.venv/bin/python -m unittest -v test_hid_mouse.py test_hid_keyboard.py test_gui_backend.py
.venv/bin/pip check
```

Unit checks cover signed axes, bit-packed reports, report IDs, buttons, scrolling,
absolute-axis exclusion, and malformed/truncated input. Hardware pairing and
pointer output must also be verified; passing parser tests does not establish
that the mouse works end to end.

Dependencies: Bumble 0.0.219, cryptography 46.0.3 (compatible binary wheel for the
installed Python 3.9), and Bumble's resolved dependencies in requirements-lock.txt.
Bumble: https://github.com/google/bumble (Apache-2.0).
