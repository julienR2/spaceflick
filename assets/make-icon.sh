#!/bin/bash
# Regenerates AppIcon.icns / icon.png from make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -o /tmp/spaceflick-make-icon make-icon.swift
/tmp/spaceflick-make-icon .
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset /tmp/spaceflick-make-icon
echo "done → assets/AppIcon.icns, assets/icon.png"
