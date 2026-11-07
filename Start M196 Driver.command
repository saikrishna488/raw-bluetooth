#!/bin/zsh
set -eu
cd "${0:A:h}"
stop_file="$PWD/driver.stop"
rm -f "$stop_file"
rm -f pointer.ready
.venv/bin/python -u pointer_bridge.py --duration 86460 &
bridge_pid=$!
cleanup() {
    touch "$stop_file"
    kill "$bridge_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
for attempt in {1..50}; do
    kill -0 "$bridge_pid" 2>/dev/null || exit 1
    [[ -f pointer.ready ]] && break
    sleep 0.1
done
[[ -f pointer.ready ]] || exit 1
echo 'Starting M196 driver. Authenticate in the macOS dialog. Ctrl-C stops it.'
osascript - "$PWD" <<'APPLESCRIPT'
on run argv
    set driverFolder to item 1 of argv
    set pythonPath to quoted form of (driverFolder & "/.venv/bin/python")
    set driverPath to quoted form of (driverFolder & "/m196_driver.py")
    set socketPath to quoted form of (driverFolder & "/pointer.sock")
    set stopPath to quoted form of (driverFolder & "/driver.stop")
    set logPath to quoted form of (driverFolder & "/driver-live.log")
    do shell script pythonPath & " -u " & driverPath & " --event-socket " & socketPath & " --stop-file " & stopPath & " --duration 86400 > " & logPath & " 2>&1" with administrator privileges
end run
APPLESCRIPT
