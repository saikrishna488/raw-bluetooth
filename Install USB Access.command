#!/bin/zsh
set -eu
cd "${0:A:h}"
worker="$PWD/build/release/image/Raw Bluetooth.app/Contents/Helpers/backend.app"
[[ -d "$worker" ]] || { echo 'Build the packaged app first: .venv/bin/python packaging/build_release.py'; exit 1; }
/usr/bin/osascript - "$PWD/packaging/usb-service-install.sh" "$UID" "$worker" "$PWD" <<'APPLESCRIPT'
on run argv
    do shell script "/bin/zsh " & quoted form of item 1 of argv & " install " & quoted form of item 2 of argv & " " & quoted form of item 3 of argv & " " & quoted form of item 4 of argv with administrator privileges
end run
APPLESCRIPT
