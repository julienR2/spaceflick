#!/bin/bash
# Records the README's before/after GIF.
#
# Two takes of you swiping between the same two spaces — one with spaceflick
# off, one with it on — trimmed to the same length and stacked side by side.
# You supply the fingers; everything else is automatic.
#
#   ./assets/record-demo.sh [seconds]     default 5
set -euo pipefail
cd "$(dirname "$0")/.."

SECS="${1:-5}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; pkill -f "spaceflick run" 2>/dev/null || true' EXIT

command -v ffmpeg >/dev/null || { echo "needs ffmpeg: brew install ffmpeg"; exit 1; }
command -v magick >/dev/null || { echo "needs imagemagick: brew install imagemagick"; exit 1; }
[[ -x build/spaceflick ]] || ./build.sh

countdown() {
  echo ""
  echo "  $1"
  for i in 3 2 1; do printf "\r  starting in %d… " "$i"; sleep 1; done
  printf "\r  RECORDING — swipe now! (%ss)      \n" "$SECS"
}

take() { # $1 = output, $2 = prompt
  countdown "$2"
  screencapture -v -V "$SECS" -x "$1" 2>/dev/null || {
    echo "screencapture failed — grant Screen Recording to this terminal in"
    echo "System Settings → Privacy & Security → Screen Recording, then rerun."
    exit 1
  }
  echo "  ✓ captured"
}

pkill -f "spaceflick run" 2>/dev/null || true
sleep 1
take "$TMP/before.mov" "TAKE 1 of 2 — spaceflick OFF. Swipe 4 fingers left, then right."

./build/spaceflick run >/dev/null 2>&1 &
sleep 1
take "$TMP/after.mov" "TAKE 2 of 2 — spaceflick ON. Same two swipes, same rhythm."
pkill -f "spaceflick run" 2>/dev/null || true

echo ""
echo "• building GIF"

# Label strip. ffmpeg here has no drawtext, so the text is an image.
# Font by path: Homebrew's ImageMagick ships with no font config on macOS.
W=620; STRIP_H=56
FONT=/System/Library/Fonts/Supplemental/Arial\ Bold.ttf
[[ -f "$FONT" ]] || FONT=/System/Library/Fonts/HelveticaNeue.ttc
magick -size "${W}x${STRIP_H}" xc:'#12121a' \
        -font "$FONT" -pointsize 26 -fill '#8b8b9e' \
        -gravity center -annotate 0 'without spaceflick' "$TMP/l-before.png"
magick -size "${W}x${STRIP_H}" xc:'#12121a' \
        -font "$FONT" -pointsize 26 -fill '#a99bff' \
        -gravity center -annotate 0 'with spaceflick' "$TMP/l-after.png"
magick "$TMP/l-before.png" "$TMP/l-after.png" +append "$TMP/labels.png"

# Trim both takes to the shorter one so the halves stay in step.
dur() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
D=$(python3 -c "print(min($(dur "$TMP/before.mov"), $(dur "$TMP/after.mov")))")

ffmpeg -y -v error \
  -t "$D" -i "$TMP/before.mov" -t "$D" -i "$TMP/after.mov" -i "$TMP/labels.png" \
  -filter_complex "\
    [0:v]fps=14,scale=${W}:-2:flags=lanczos,setsar=1[a]; \
    [1:v]fps=14,scale=${W}:-2:flags=lanczos,setsar=1[b]; \
    [a][b]hstack=inputs=2[row]; \
    [2:v][row]vstack=inputs=2[stacked]; \
    [stacked]split[s0][s1]; \
    [s0]palettegen=max_colors=128:stats_mode=diff[p]; \
    [s1][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 assets/demo.gif

echo "done → assets/demo.gif  ($(du -h assets/demo.gif | cut -f1))"
