# Olivier (Linux x86_64)

A bilingual-aware music player.

## Running from the tarball

This archive contains a self-contained build. Run it with:

    ./olivier

## Runtime requirement: libmpv

Audio playback uses libmpv, which is **not** bundled. Install it from your
distribution:

- Debian/Ubuntu: `sudo apt install libmpv2` (or `libmpv1` on older releases)
- Fedora: `sudo dnf install mpv-libs`

## Desktop integration (optional)

`org.urth.olivier.desktop` and the icons under `icons/hicolor/` can be copied
into `~/.local/share/applications` and `~/.local/share/icons/hicolor`
respectively. The `.deb`/`.rpm` packages do this for you.

## License

Apache-2.0. See `LICENSE`.
