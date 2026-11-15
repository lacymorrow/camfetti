#!/bin/zsh
# Renders each tile in tiles.html to out/<n>-<id>.png at 1320x2868 (iPhone 6.9" App Store size).
# Put the raw shots in ./shots first (see the comment at the top of tiles.html).
set -e
cd "${0:A:h}"
mkdir -p out
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
n=1
for id in grid full recordings watch free; do
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor=1 --window-size=1320,2868 \
    --screenshot="$PWD/out/$n-$id.png" "file://$PWD/tiles.html#$id" 2>/dev/null
  magick "out/$n-$id.png" -alpha off "out/$n-$id.png"
  n=$((n + 1))
done
ls out
