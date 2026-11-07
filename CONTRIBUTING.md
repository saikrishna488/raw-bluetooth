# Contributing

Raw Bluetooth is an experimental macOS userspace Bluetooth project. Read the [architecture](docs/ARCHITECTURE.md) before changing session ownership, pairing, input output, or shutdown behavior.

## Local setup

Follow the [README quick start](README.md#quick-start). Python dependencies belong in `.venv`; use the pinned requirements for reproducibility. Build Swift changes with `./gui/build.command`. This installs the app and updates its local signature, so do it on your development Mac with the checkout kept in place.

## Validation

```sh
.venv/bin/python -m unittest -v test_hid_mouse.py test_hid_keyboard.py test_gui_backend.py
.venv/bin/pip check
git diff --check
```

Tests cover signed and bit-packed mouse axes, buttons, scrolling, report IDs, malformed input, keyboard arrays/NKRO/modifiers, and backend discovery, passkeys, preferences, reconnection, and command handling. They do not exercise a physical controller or macOS permissions.

For Bluetooth or input changes, separately record manual results for discovery, pairing, live input, simultaneous mouse/keyboard use, reconnect after wake, intentional disconnect, and adapter release. For GUI changes, rebuild and inspect the desktop app. For audio changes, record the actual sink model, negotiation result, audible playback, and cleanup; a discovery result is not a successful playback test.

## Change guidelines

- Keep USB access in the privileged worker and desktop input output in the normal user's session.
- Preserve controller cleanup and the GUI heartbeat lease.
- Keep pairing keys out of status events and avoid logging keyboard contents.
- Keep the internal Lite-On radio excluded from default adapter selection.
- Add focused regression coverage when changing parser or backend behavior.
- Update the support table and user documentation when behavior or compatibility changes.
- Preserve bundled firmware notices and provenance metadata.

Keep commits focused and describe the trigger, changed behavior, and validation. For hardware reports, state precisely what was tested instead of claiming broad device support.

## Files to keep out of commits

Check `git status` before committing. Never include `.signing/`, identity or bond JSON, saved device data, logs, sockets, generated apps, or the virtual environment. If a change introduces a new private runtime file, update `.gitignore` accordingly.
