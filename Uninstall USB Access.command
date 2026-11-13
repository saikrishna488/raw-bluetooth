#!/bin/zsh
set -eu
cd "${0:A:h}"
/usr/bin/osascript - "$PWD/packaging/usb-service-install.sh" "$UID" <<'APPLESCRIPT'
on run argv
    do shell script "/bin/zsh " & quoted form of item 1 of argv & " uninstall " & quoted form of item 2 of argv with administrator privileges
end run
APPLESCRIPT
