#!/bin/zsh
set -eu
cd "${0:A:h}/.."
app="$HOME/Applications/Raw Bluetooth.app"
mkdir -p "$app/Contents/MacOS"
cp gui/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :DriverSourceDirectory $PWD" "$app/Contents/Info.plist"
xcrun swiftc -O -parse-as-library gui/RawBluetooth.swift gui/PointerServer.swift gui/KeyboardOutput.swift gui/SystemAudioCapture.swift -o "$app/Contents/MacOS/RawBluetooth" -framework SwiftUI -framework AppKit -framework ServiceManagement -framework ScreenCaptureKit -framework CoreMedia -target x86_64-apple-macosx13.0
.venv/bin/python gui/sign_app.py "$app"
echo "Built $app"
