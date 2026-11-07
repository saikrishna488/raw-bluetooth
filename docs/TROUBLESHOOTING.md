# Troubleshooting

## Build or launch

| Symptom | Check / recovery |
| --- | --- |
| `xcrun` / `swiftc` missing | Install Xcode Command Line Tools with `xcode-select --install`. |
| Missing Python module | Install `requirements-lock.txt` into the checkout's `.venv`; confirm you are using `.venv/bin/python`. |
| App fails after moving the checkout | Run `./gui/build.command` from the new location; the app embeds the source path. |
| Build on Apple Silicon | The supplied script targets Intel x86_64. Native arm64 support has not been validated. |
| Signing fails | Keep the local `.signing/` directory intact and inspect the specific `security`/`codesign` error. Do not share its password or keychain. |

The installed app depends on this checkout and its virtual environment. Copying only the `.app` to another Mac is not a supported installation method.

## Adapter cannot be opened

Confirm the external device appears in macOS **System Information → USB**, with vendor/product ID `0a12:0001`. The GUI defaults to that ID; it does not fall back to the internal Lite-On radio. A different dongle is not automatically supported.

Release the adapter in the GUI and stop any CLI session before another tool tries to claim it. Authenticate when macOS requests administrator access. If a previous session crashed, wait for its heartbeat lease cleanup, then restart the session. If macOS or the app still cannot reclaim the controller, unplug/replug the dongle.

Only one stack can use the adapter at a time. Devices managed by macOS on that same adapter cannot use it concurrently with Raw Bluetooth.

## Device appears but will not connect

Use the correct device pairing mode and connect action. A non-connectable advertisement cannot be paired; a BLE audio advertisement also does not imply that an A2DP sink is available. HID support is for BLE mice/keyboards, not arbitrary GATT devices or proprietary wireless receivers.

For a keyboard passkey, type all six digits on the keyboard being paired and press Enter. Allow up to two minutes. If the device was re-paired elsewhere or cleared its keys, forget its entry in the app and pair again. Forgetting requires pairing again; do not delete the entire bond database as a first troubleshooting step.

## Connected, but no pointer or keyboard output

Grant **Raw Bluetooth** Accessibility access in System Settings and retry. The GUI emits input as the normal desktop user. For the separate CLI pointer helper, permission belongs to its Python host, so granting the GUI alone is insufficient. Avoid running the pointer helper as root.

Use the keyboard's local test field or the CLI mouse `--dry-run` workflow to distinguish incoming Bluetooth reports from permission/output problems. Absolute pointing devices and vendor-specific keys may not map to the supported event path.

## Automatic reconnection does not happen

Keep the app running and ensure **Reconnect automatically** is enabled. Wake the device with normal input so it advertises. An intentional Disconnect pauses retries for that session. Hold the pairing button only when you intend to establish a new bond. After deep sleep or a USB reset, release and restart the adapter session.

## Audio device found, but no sound or macOS output

Audio is experimental. The peer must be discoverable over Bluetooth Classic and expose a compatible SBC A2DP sink. The audio test sends an app-generated tone; it does not register a macOS Sound output or microphone. Browser playback, system audio routing, and HFP/SCO calls are not implemented.

## Reporting an issue

Include the macOS version, Mac architecture, Python version, dongle USB ID, device model, exact action, expected result, actual result, and a short sanitized error excerpt. Note whether the failure occurs during discovery, pairing, HID subscription, output, or cleanup.

Do not attach host identity, bond databases, `.signing/`, or an entire virtual environment. Redact device addresses and identifying names from logs. Run the [development checks](../CONTRIBUTING.md#validation) and report their results, while keeping hardware observations separate from unit-test results.
