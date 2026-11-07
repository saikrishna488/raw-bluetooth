Self-contained Intel macOS community preview. Download the `.dmg`, open it, and drag Raw Bluetooth to Applications. Python and a source checkout are no longer required.

- Bundles the Python backend, libusb, and FFmpeg.
- Stores installed-app preferences and pairing data in `~/Library/Application Support/Raw Bluetooth`.
- Includes background operation, scroll page length, multi-monitor pointer fixes, and a dedicated heartbeat that avoids App Nap throttling.
- Includes third-party notices and a SHA-256 checksum.

**Experimental and not notarized:** this build is ad-hoc signed. macOS may require Open Anyway in System Settings → Privacy & Security. Grant Accessibility access, then authorize USB access when scanning. Requires an Intel Mac, macOS 13+, a logged-in user session, and a supported external USB Bluetooth adapter (tested: `0a12:0001`).

Hardware compatibility still needs independent testing. Existing development-checkout pairings are not migrated automatically. Classic Bluetooth HID, login-screen input, system audio output, and microphones remain unsupported. See the included READ ME FIRST for installation and limitations.
