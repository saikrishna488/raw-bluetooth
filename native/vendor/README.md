# Native dependency sources

- nlohmann/json 3.12.0, MIT: https://github.com/nlohmann/json/tree/v3.12.0
  `single_include/nlohmann/json.hpp` SHA-256:
  `aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63`
- libusb 1.0.26 public header, LGPL-2.1-or-later:
  https://github.com/libusb/libusb/tree/v1.0.26
  `libusb/libusb.h` SHA-256:
  `ca94b99bf4ca9c588804eb0b2187f237a165d80b22054a27608abee3280b8eb0`

The libusb runtime comes from the pinned `libusb-package==1.0.26.1` dependency.
It is dynamically linked, copied without modifying the original, and bundled
with its source archive and license by `packaging/build_release.py`.
Native code requires macOS 13+ and C++17. The JSON header is compiled into the
backend and USB broker; it is not a separate runtime dependency.
