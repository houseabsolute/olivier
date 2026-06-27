# Lint and tidy via precious. Pass args through, e.g. `just lint --all` or
# `just tidy path/to/file`.

lint *args:
    mise exec -- precious lint {{ args }}

tidy *args:
    mise exec -- precious tidy {{ args }}

# Run the app on Linux through mise, so the pinned Flutter + ninja are used
# (avoids picking up a stray system/PATH ninja). Pass extra flags, e.g.
# `just run --release`.
run *args:
    mise exec -- flutter run -d linux {{ args }}

# Install the .desktop entry + themed icons into ~/.local so Olivier appears in
# the app menu. Needs a release bundle (mise exec -- flutter build linux --release).
install-desktop:
    ./scripts/install-desktop.sh

# Build the Linux release and produce dist/*.deb, *.rpm, and *.tar.gz locally
# (the same script + nfpm config the release workflow uses). Usage:
# `just package` or `just package 0.0.1`. Requires the Flutter build toolchain.
package version="0.0.0-dev":
    #!/usr/bin/env bash
    set -euo pipefail
    ver='{{ version }}'
    base="${ver%%-*}"
    mise exec -- flutter build linux --release --build-name="$base" --build-number=0
    ./scripts/stage-release.sh build/linux/x64/release/bundle "$ver" .
    VERSION="$ver" mise exec -- nfpm pkg -p deb -f packaging/nfpm.yaml -t dist/
    VERSION="$ver" mise exec -- nfpm pkg -p rpm -f packaging/nfpm.yaml -t dist/
    echo "Artifacts:"
    ls -1 dist/
