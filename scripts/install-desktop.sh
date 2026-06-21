#!/usr/bin/env bash
# Install the Olivier .desktop entry + themed icons into the user's XDG dirs so
# Olivier appears in the application menu / dock. Requires a release bundle
# (build it with: mise exec -- flutter build linux --release). Re-run after a
# rebuild if the bundle path changes.
set -euo pipefail

cd "$(dirname "$0")/.."
repo="$PWD"
bin="$repo/build/linux/x64/release/bundle/olivier"

if [[ ! -x $bin ]]; then
    echo "Release bundle not found at: $bin" >&2
    echo "Build it first: mise exec -- flutter build linux --release" >&2
    exit 1
fi

apps="$HOME/.local/share/applications"
icons="$HOME/.local/share/icons/hicolor"
mkdir -p "$apps"

for n in 16 24 32 48 64 128 256 512; do
    dir="$icons/${n}x${n}/apps"
    mkdir -p "$dir"
    cp "$repo/assets/icon/hicolor/${n}x${n}/olivier.png" "$dir/olivier.png"
done
mkdir -p "$icons/scalable/apps"
cp "$repo/assets/icon/olivier.svg" "$icons/scalable/apps/olivier.svg"

exec_line="${bin//&/\\&}"
sed "s|^Exec=.*|Exec=$exec_line %U|" "$repo/linux/org.urth.olivier.desktop" >"$apps/org.urth.olivier.desktop"

gtk-update-icon-cache -f -t "$icons" 2>/dev/null || true
update-desktop-database "$apps" 2>/dev/null || true

echo "Installed Olivier desktop entry + icons. Look for it in your app menu."
