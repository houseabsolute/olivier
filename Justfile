# Lint and tidy via precious. Pass args through, e.g. `just lint --all` or
# `just tidy path/to/file`.

lint *args:
    mise exec -- precious lint {{ args }}

tidy *args:
    mise exec -- precious tidy {{ args }}
