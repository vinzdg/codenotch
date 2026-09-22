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

Not in this change: Wayland pointer-follow or an AppImage. On a Wayland session
the notch still draws; `codenotch doctor` warns that pointer-follow needs X11.

## License

MIT — see [`../desktop/LICENSE`](../desktop/LICENSE). The Codenotch design and
name belong to the upstream author.
