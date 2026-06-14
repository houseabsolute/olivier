#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=rust/tests/fixtures
mkdir -p "$OUT"

# 1s of silence as the base audio for each container/codec.
ff() { ffmpeg -y -f lavfi -i anullsrc=r=44100:cl=stereo -t 1 "$@"; }

ff -codec:a libmp3lame      "$OUT/sample.mp3"
ff -codec:a flac            "$OUT/sample.flac"
ff -codec:a aac             "$OUT/sample.m4a"
ff -codec:a alac            "$OUT/sample.alac.m4a"
ff -codec:a libvorbis       "$OUT/sample.ogg"
ff -codec:a libopus         "$OUT/sample.opus"

python3 scripts/make_fixtures.py
echo "fixtures written to $OUT"
