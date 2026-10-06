# macos/ — building Herdr.app

Builds a standalone, codesigned `Herdr.app` from this checkout's own herdr
source, wrapped in a pinned/verified copy of the official Ghostty.app. Always
builds from source (never a downloaded/released `herdr` binary), so the
result is reproducible on any Mac that clones this repo — nothing here
depends on a symlink back into a particular checkout.

## Requirements

- macOS, full **Xcode** (not just Command Line Tools — `ibtool` needs it to
  recompile the rebranded menu bar). `sudo xcode-select -s
  /Applications/Xcode.app/Contents/Developer` and accept the license
  (`sudo xcodebuild -license`) if `xcode-select -p` still points at the CLT.
- **Ghostty.app** installed at `/Applications/Ghostty.app`, exact version
  pinned in `install.sh` (`ghostty_version`) — official build only, checked
  by bundle id, version, and Apple Developer Team ID before anything runs.
- **Rust** via rustup (`rust-toolchain.toml` pins the exact version) and
  **zig@0.15** (`brew install zig@0.15`; CI uses the same pin, see
  `../.github/workflows/release.yml`).
- `minisign` (`brew install minisign`) to verify the downloaded Ghostty
  source tarball.

## Use

```sh
git checkout feat/app-border   # or whichever branches you want built in
cd macos
./install.sh                   # build + activate ~/Applications/Herdr.app
./install.sh --verify           # check the active app is intact
./install.sh --rollback         # reactivate the previous release
./install.sh --rollback ID      # reactivate a specific release (see
                                 #   ~/Library/Application Support/Herdr/installer/activations.tsv)
```

Builds whatever is currently checked out — branch selection is your call,
not the script's. Bumping Ghostty means re-pinning `ghostty_version`,
`ghostty_sha256` in `install.sh` (the minisign key and team id are Ghostty's
own long-lived constants, not per-version).

## What it does and doesn't touch

- **Isolates Ghostty's own config** under `~/Library/Application Support/
  Herdr/installer/xdg`, generated from `app/herdr.ghostty.in`. Its native
  launch path explicitly passes `--config-file` to Ghostty: macOS did not
  reliably apply `LSEnvironment` when launching the bundle, leaving a plain
  shell instead of herdr. This avoids depending on `~/.config/ghostty/`.
- **Shares herdr's configuration, not its server.** The bundled binary has
  `XDG_CONFIG_HOME` explicitly unset before exec, so it reads your real
  `~/.config/herdr/config.toml`. `HERDR_SESSION=app` gives it separate socket,
  panes and saved state under `~/.config/herdr/sessions/app/`, leaving the
  default server and its live sessions untouched while testing.
- **Never edits your herdr config.** `app/herdr-keys.toml` documents the
  `[keys]`/`[ui]` additions this app's Ghostty-side keybinds expect (and the
  fork-only `app_border`/`tab_caps` keys) — `install.sh` prints it after a
  build. Add them by hand; your config is hand-curated and git-tracked, and
  already has its own `[keys]`/`[ui]` tables an automated merge could corrupt.

## Mechanics

Atomic activate/rollback (`~/Applications/Herdr.app` is always either the
fully-verified new release or the untouched prior one — never
half-swapped), release store + `current`/`previous` symlinks, and
`verify_app` checks are adapted from
[`benngarcia/herdr-macos`](https://github.com/benngarcia/herdr-macos).
