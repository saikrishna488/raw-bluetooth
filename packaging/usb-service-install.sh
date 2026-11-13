#!/bin/zsh
# Invoked once through the macOS administrator dialog. No sudoers changes.
set -eu
[[ $EUID == 0 ]] || { echo 'Administrator authorization is required for installation.' >&2; exit 1; }
action=${1:?Missing action}
client_uid=${2:?Missing user ID}
[[ "$client_uid" == <-> && "$client_uid" -gt 0 ]] || exit 1
label="local.rawbluetooth.usb.$client_uid"
base="/Library/PrivilegedHelperTools/$label"
plist="/Library/LaunchDaemons/$label.plist"
if [[ "$action" == uninstall ]]; then
    /bin/launchctl bootout "system/$label" 2>/dev/null || true
    /bin/rm -f "$plist"
    /bin/rm -rf "$base" "/var/run/raw-bluetooth-$client_uid"
    exit 0
fi
[[ "$action" == install ]] || exit 1
worker=${3:?Missing packaged backend app}
state=${4:-}
/usr/bin/codesign --verify --deep --strict "$worker"
/bin/mkdir -p /Library/PrivilegedHelperTools
[[ ! -L "$base" ]] || exit 1
/bin/mkdir -p "$base"
/usr/sbin/chown root:wheel "$base"
/bin/chmod 755 "$base"
staged="$base/staged.app"
/bin/rm -rf "$staged"
/usr/bin/ditto --noqtn "$worker" "$staged"
# A persistent root runtime must not reference files outside its installed copy.
while IFS= read -r link; do
    resolved=${link:A}
    [[ "$resolved" == "$staged"/* ]] || { echo "External runtime symlink rejected" >&2; exit 1; }
done < <(/usr/bin/find "$staged" -type l)
/usr/sbin/chown -R -P root:wheel "$staged"
/bin/chmod -R go-w "$staged"
/usr/bin/codesign --verify --deep --strict "$staged"
[[ -x "$staged/Contents/Frameworks/native/raw-bluetooth-usb" ]] || { echo 'Native USB broker missing; rebuild the app first.' >&2; exit 1; }
/bin/launchctl bootout "system/$label" 2>/dev/null || true
/bin/rm -rf "$base/backend.app"
/bin/mv "$staged" "$base/backend.app"
/bin/mkdir -p /Library/LaunchDaemons
/bin/cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array>
<string>$base/backend.app/Contents/Frameworks/native/raw-bluetooth-usb</string>
<string>$client_uid</string>
</array>
<key>WorkingDirectory</key><string>$base</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>Umask</key><integer>63</integer>
<key>StandardErrorPath</key><string>/var/log/$label.log</string>
</dict></plist>
PLIST
/usr/sbin/chown root:wheel "$plist"
/bin/chmod 644 "$plist"
/bin/launchctl bootstrap system "$plist"
# The old worker wrote these private files as root. Transfer only known state
# files so the desktop worker can preserve existing bonds and preferences.
if [[ -n "$state" && -d "$state" ]]; then
    state=${state:A}
    [[ $(/usr/bin/stat -f %u "$state") == "$client_uid" ]] || exit 1
    for name in driver-identity.json driver-bonds.json saved-devices.json driver.stop; do
        [[ ! -e "$state/$name" ]] || /usr/sbin/chown -h "$client_uid" "$state/$name"
    done
fi
echo 'USB access installed. New driver sessions no longer need administrator authorization.'
