#!/bin/zsh
set -eu
cd "${0:A:h}"
touch driver.stop
echo 'Stop requested. The Bluetooth adapter will be released.'
