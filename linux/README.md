# Codenotch for Linux

A Linux front door for the shared Rust/Tauri 2 desktop port. The crate itself
lives in [`../desktop`](../desktop/README.md) — the same app Windows builds.
Linux-only behaviour is in [`desktop/codenotch/src/platform/linux.rs`](../desktop/codenotch/src/platform/linux.rs),
not a second copy of the tree.

First target: **Linux Mint / Cinnamon / X11**. The notch pins to the top edge
by default, unfolds on hover, and the Cursor cell borrows the editor session
from `~/.config/Cursor/User/globalStorage/state.vscdb` (never the lowercase
CLI directory `~/.config/cursor`). Dragging the pill slides it along the edge
it is already on; it does not hop to another side mid-drag.

## Install dependencies

```sh
./install-deps.sh
```

That installs GTK, WebKitGTK 4.1, Ayatana app indicator, X11 headers and the
usual build tools. Rust is assumed via [rustup](https://rustup.rs).

## Install / build

Download [`Codenotch.deb`](https://github.com/vinzdg/codenotch/releases/latest/download/Codenotch.deb)
from the latest release, or take the artifact from a
[Linux Package run](../../actions/workflows/linux-package.yml). It is built for
**Linux Mint / Ubuntu 24.04** (amd64) and pulls in WebKitGTK 4.1 and the Ayatana
tray library.

```sh
sudo apt install ./Codenotch.deb
codenotch            # notch on the top edge
codenotch doctor     # credentials, Cursor store, icons, hooks
```

To build the `.deb` from source:

```sh
./install-deps.sh
./package.sh         # → dist/Codenotch.deb
```

Needs Node (for the Tauri CLI) in addition to the GTK/WebKit packages. Settings,
logs and persisted readings go in `~/.config/codenotch`. Autostart writes
`~/.config/autostart/codenotch.desktop`.

## Run from a tree (no package)

```sh
./run.sh
```

Same thing, from the crate:

```sh
cd ../desktop
cargo run --release
cargo run --release -- doctor   # credentials, Cursor store, icons, hooks
```

Settings, logs and persisted readings go in `~/.config/codenotch`. Autostart
writes `~/.config/autostart/codenotch.desktop`.

## What this milestone covers

- Notch on an X11 Cinnamon session, always-on-top, hover and click-through
- Tray menu (Ayatana)
- Cursor usage from the editor's own `state.vscdb`
- Move handle that slides along the current edge

Not in this change: Wayland pointer-follow or an AppImage.

## Sending this to the community repo

The upstream is [vinzdg/codenotch](https://github.com/vinzdg/codenotch). A
branch plus a pull request is how they evaluate it — CI on that PR is the
Linux and Windows builds under `.github/workflows/`.

```sh
# from the repo root, on feat/linux-desktop (or any branch of yours)
git push -u origin HEAD

gh pr create --base main --head feat/linux-desktop \
  --repo vinzdg/codenotch \
  --title "Linux desktop port (Mint / Cinnamon / X11)" \
  --body "$(cat <<'EOF'
## Summary
- Shared Tauri crate moved to `desktop/`; `linux/` and `windows/` are front doors.
- Linux: notch, tray, Cursor session from `~/.config/Cursor`, hover, axis-locked drag.
- Windows behaviour is unchanged; platform code lives in `desktop/codenotch/src/platform/`.

## Test plan
- [ ] `cd desktop && cargo test --locked` on Linux
- [ ] Notch appears on Mint/Cinnamon/X11, unfolds on hover, tray works
- [ ] Cursor cell reads the editor session (not the CLI dir)
- [ ] Dragging the pill slides along the current edge
- [ ] Windows CI (build + package) still green
EOF
)"
```

If `origin` is not `vinzdg/codenotch` (a fork), push the branch to the fork and
open the PR against `vinzdg/codenotch:main`. The Linux workflow only runs on
that repository, including pull requests opened there.

## License

MIT — see [`../desktop/LICENSE`](../desktop/LICENSE). The Codenotch design and
name belong to the upstream author.
