#!/bin/bash
# Records the demo clips: one take with spaceflick off, one with it on.
#
# You supply the fingers; everything else is automatic. Each take is written
# twice — a retina-resolution MP4 for the website and a smaller GIF for the
# README. No labels are burned in; those belong in the page, not the pixels.
#
#   ./assets/record-demo.sh [seconds] [both|before|after]
#
# Outputs, into assets/:
#   demo-before.mp4  demo-before.gif      spaceflick off
#   demo-after.mp4   demo-after.gif       spaceflick on
set -euo pipefail
cd "$(dirname "$0")/.."

SECS="${1:-5}"
WHICH="${2:-both}"
MP4_WIDTH=1440        # ~2x a 720px slot: retina on the site, still sane to host
GIF_WIDTH=560
GIF_FPS=12
TMP="$(mktemp -d)"

command -v ffmpeg >/dev/null || { echo "needs ffmpeg: brew install ffmpeg"; exit 1; }
[[ -x build/spaceflick ]] || ./build.sh

# If spaceflick is running as a brew service, launchd restarts it the moment we
# kill it, which would silently ruin the "off" take. Park it for the duration.
SERVICE_WAS_UP=false
if brew services list 2>/dev/null | grep -qE "^spaceflick +started"; then
  SERVICE_WAS_UP=true
fi

cleanup() {
  rm -rf "$TMP"
  pkill -f "spaceflick run" 2>/dev/null || true
  if [[ "$SERVICE_WAS_UP" == true ]]; then
    echo "• restarting the spaceflick brew service"
    brew services start spaceflick >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "$SERVICE_WAS_UP" == true ]]; then
  echo "• pausing the spaceflick brew service for the recording"
  brew services stop spaceflick >/dev/null 2>&1 || true
fi

capture() { # $1 = raw output path, $2 = prompt
  echo ""
  echo "  $2"
  for i in 3 2 1; do printf "\r  starting in %d… " "$i"; sleep 1; done
  printf "\r  RECORDING — swipe now! (%ss)          \n" "$SECS"
  screencapture -v -V "$SECS" -x "$1" 2>/dev/null || {
    echo ""
    echo "screencapture failed. Grant Screen Recording to this terminal in"
    echo "System Settings → Privacy & Security → Screen Recording, then rerun."
    exit 1
  }
  echo "  ✓ captured $(ffprobe -v error -show_entries stream=width,height \
        -of csv=p=0:s=x "$1" | head -1)"
}

encode() { # $1 = raw .mov, $2 = basename without extension
  local raw="$1" out="assets/$2"

  # Retina MP4 for the site. Even dimensions, yuv420p, streamable.
  ffmpeg -y -v error -i "$raw" \
    -vf "scale=${MP4_WIDTH}:-2:flags=lanczos" \
    -c:v libx264 -preset slow -crf 21 -pix_fmt yuv420p \
    -movflags +faststart -an "$out.mp4"

  # GIF for the README, palette-optimised.
  ffmpeg -y -v error -i "$raw" \
    -filter_complex "fps=${GIF_FPS},scale=${GIF_WIDTH}:-2:flags=lanczos,setsar=1,\
split[s0][s1];[s0]palettegen=max_colors=128:stats_mode=diff[p];\
[s1][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
    -loop 0 "$out.gif"

  echo "  → $out.mp4 ($(du -h "$out.mp4" | cut -f1))  $out.gif ($(du -h "$out.gif" | cut -f1))"
}

if [[ "$WHICH" == both || "$WHICH" == before ]]; then
  pkill -f "spaceflick run" 2>/dev/null || true
  sleep 1
  capture "$TMP/before.mov" "spaceflick OFF — swipe 4 fingers left, then right."
  echo "• encoding"
  encode "$TMP/before.mov" demo-before
fi

if [[ "$WHICH" == both || "$WHICH" == after ]]; then
  ./build/spaceflick run >/dev/null 2>&1 &
  sleep 1
  capture "$TMP/after.mov" "spaceflick ON — same two swipes, same rhythm."
  pkill -f "spaceflick run" 2>/dev/null || true
  echo "• encoding"
  encode "$TMP/after.mov" demo-after
fi

echo ""
echo "done."
