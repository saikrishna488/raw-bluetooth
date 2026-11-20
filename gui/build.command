#!/bin/zsh
set -eu
cd "${0:A:h}/.."
app="$HOME/Applications/Raw Bluetooth.app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
cp packaging/usb-service-install.sh "$app/Contents/Resources/usb-service-install.sh"
cp gui/RawBluetooth.icns "$app/Contents/Resources/RawBluetooth.icns"
cp gui/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :DriverSourceDirectory $PWD" "$app/Contents/Info.plist"
if [[ -n "${RAW_BT_BUNDLE_IDENTIFIER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $RAW_BT_BUNDLE_IDENTIFIER" "$app/Contents/Info.plist"
fi
xcrun swiftc -O -parse-as-library gui/RawBluetooth.swift gui/PointerServer.swift gui/KeyboardOutput.swift gui/VirtualHIDServer.swift gui/SystemAudioCapture.swift gui/SessionChannel.swift -o "$app/Contents/MacOS/RawBluetooth" -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement -framework ScreenCaptureKit -framework CoreMedia -target x86_64-apple-macosx13.0
.venv/bin/python gui/sign_app.py "$app"
echo "Built $app"
