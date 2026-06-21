#!/usr/bin/env bash
# Rasterise the SVG masters into every PNG the app icon needs. Re-runnable;
# the generated PNGs are committed so a clean checkout has them without
# needing rsvg-convert.
set -euo pipefail

cd "$(dirname "$0")/.."
svg="assets/icon/olivier.svg"
fg="assets/icon/olivier_foreground.svg"
out="assets/icon"

for n in 16 24 32 48 64 128 256 512; do
    mkdir -p "$out/hicolor/${n}x${n}"
    rsvg-convert -w "$n" -h "$n" "$svg" -o "$out/hicolor/${n}x${n}/olivier.png"
done

rsvg-convert -w 256 -h 256 "$svg" -o "$out/olivier_256.png"
rsvg-convert -w 1024 -h 1024 "$svg" -o "$out/olivier_1024.png"
rsvg-convert -w 1024 -h 1024 "$fg" -o "$out/olivier_foreground_1024.png"

echo "Generated app icons under $out"
