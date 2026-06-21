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
