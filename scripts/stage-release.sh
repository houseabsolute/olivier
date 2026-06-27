#!/usr/bin/env bash
# Build the Olivier release install tree (FHS layout, consumed by nfpm) and a
# relocatable tarball, from a finished `flutter build linux --release` bundle.
#
# Usage: scripts/stage-release.sh <bundle_dir> <version> <out_dir>
#   bundle_dir  e.g. build/linux/x64/release/bundle
#   version     e.g. 0.0.1 (no leading "v")
#   out_dir     created if needed; populated with <out_dir>/staging and
#               <out_dir>/dist/olivier-<version>-linux-x64.tar.gz
set -euo pipefail

bundle_dir=${1:?usage: stage-release.sh <bundle_dir> <version> <out_dir>}
version=${2:?usage: stage-release.sh <bundle_dir> <version> <out_dir>}
out_dir=${3:?usage: stage-release.sh <bundle_dir> <version> <out_dir>}

cd "$(dirname "$0")/.."
repo="$PWD"

if [[ ! -x "$bundle_dir/olivier" ]]; then
    echo "release bundle not found at $bundle_dir/olivier" >&2
    echo "build it first: mise exec -- flutter build linux --release" >&2
    exit 1
fi

staging="$out_dir/staging"
dist="$out_dir/dist"
rm -rf "$staging"
mkdir -p "$staging" "$dist"

# 1. Whole app bundle -> /usr/lib/olivier
install -d "$staging/usr/lib/olivier"
cp -a "$bundle_dir/." "$staging/usr/lib/olivier/"

# 2. Desktop entry -> /usr/share/applications (Exec=olivier resolves via the
#    /usr/bin/olivier symlink that nfpm adds).
install -d "$staging/usr/share/applications"
install -m 0644 "$repo/linux/org.urth.olivier.desktop" \
    "$staging/usr/share/applications/org.urth.olivier.desktop"

# 3. Themed icons -> /usr/share/icons/hicolor
for n in 16 24 32 48 64 128 256 512; do
    install -d "$staging/usr/share/icons/hicolor/${n}x${n}/apps"
    install -m 0644 "$repo/assets/icon/hicolor/${n}x${n}/olivier.png" \
        "$staging/usr/share/icons/hicolor/${n}x${n}/apps/olivier.png"
done
install -d "$staging/usr/share/icons/hicolor/scalable/apps"
install -m 0644 "$repo/assets/icon/olivier.svg" \
    "$staging/usr/share/icons/hicolor/scalable/apps/olivier.svg"

# 4. License + README -> /usr/share/doc/olivier
install -d "$staging/usr/share/doc/olivier"
install -m 0644 "$repo/LICENSE" "$staging/usr/share/doc/olivier/LICENSE"
install -m 0644 "$repo/packaging/README.tarball.md" \
    "$staging/usr/share/doc/olivier/README"

# 5. Relocatable tarball: olivier-<version>-linux-x64/
top="olivier-${version}-linux-x64"
tarroot="$dist/$top"
rm -rf "$tarroot"
mkdir -p "$tarroot/icons"
cp -a "$bundle_dir/." "$tarroot/"
install -m 0644 "$repo/linux/org.urth.olivier.desktop" \
    "$tarroot/org.urth.olivier.desktop"
cp -a "$staging/usr/share/icons/hicolor" "$tarroot/icons/hicolor"
install -m 0644 "$repo/LICENSE" "$tarroot/LICENSE"
install -m 0644 "$repo/packaging/README.tarball.md" "$tarroot/README"
tar -C "$dist" -czf "$dist/${top}.tar.gz" "$top"
rm -rf "$tarroot"

echo "staged:  $staging"
echo "tarball: $dist/${top}.tar.gz"
