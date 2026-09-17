# Codenotch for Linux

A Linux port of [Codenotch](https://github.com/vinzdg/codenotch) — the usage notch that
sits on the edge of your screen and answers two questions at a glance:
**how much of my AI allowance is left**, and **is Claude still working**.

Same design language as the macOS original and the [Windows](../windows/README.md) Tauri
port (inverse-rounded pill, colour-graded rings, hover card), built here as a portable
**AppImage** with Rust + Tauri 2 / WebKitGTK. This tree is the Linux work; `windows/` and
the Swift macOS app are left alone.

## Where the AppImage runs

This is **not** a “runs on every Unix” binary. It is an **x86_64 glibc AppImage** aimed at
current desktop distros. It was built on **Ubuntu 22.04** (glibc 2.35) so one file can run
on newer systems, and it was tested on **Bazzite** (Fedora Silverblue/Kinoite, KDE).

### Should work

| Distro | Notes |
| --- | --- |
| Fedora / Bazzite / Nobara | Tested on Bazzite. Install host `webkit2gtk4.1`. |
| Ubuntu 22.04, 24.04 and derivatives (Mint, Pop!_OS) | Same glibc family the binary is linked against. |
| Debian 12+ | Needs `libwebkit2gtk-4.1-0`. |

Other glibc x86_64 desktops (Arch, openSUSE Tumbleweed, …) can work **if** they ship
`webkit2gtk-4.1` (or the distro’s equivalent of that SONAME) and FUSE.

### Required on the host

The AppImage is **thin** (~5 MB). It does **not** bundle WebKitGTK. A full linuxdeploy
bundle of Ubuntu’s WebKit aborts on Fedora/Bazzite (`EGL_BAD_PARAMETER`), leaving Settings
and the notch blank. At runtime the host must provide:

- **x86_64** (amd64). No ARM / Apple Silicon VMs without x86_64, no Raspberry Pi.
- **glibc ≥ 2.35** (Ubuntu 22.04’s baseline).
- **webkit2gtk-4.1** and GTK 3, e.g.
  - Fedora / Bazzite: `webkit2gtk4.1`
  - Ubuntu / Debian: `libwebkit2gtk-4.1-0`
- **FUSE** to mount the AppImage (`fuse` / `libfuse2` depending on the distro).
- An **AppIndicator** tray: KDE usually has one; GNOME needs an AppIndicator extension.

Run it on the **host**, not inside Distrobox (`chmod +x`, then double-click or execute).

```sh
chmod +x Codenotch.AppImage
./Codenotch.AppImage
./Codenotch.AppImage doctor
```

Config: `~/.config/codenotch`. **Install hooks** copies `codenotch-hook` to
`~/.local/share/codenotch/` so Claude Code does not point into a vanished AppImage mount.

### Will not run (or is unsupported)

- **aarch64 / ARM** — this AppImage is x86_64 only.
- **musl** distros (Alpine).
- Older glibc: Ubuntu 20.04, Debian 11, and anything older.
- Machines **without** `webkit2gtk-4.1` (the process starts, then Settings/notch stay blank
  or the WebKit helper fails).

### Desktop caveats

The overlay notch is **best-effort**:

- **KDE / X11** (typical Bazzite): always-on-top pill and hover card work.
- **GNOME Wayland**: the compositor often ignores always-on-top; tray + Settings still show
  the same meters. Hover on the pill needs the window to actually be on top.
- Usage hover is a **separate opaque window** (not painted inside the transparent overlay).
  WebKitGTK’s software compositor on a transparent overlay stacked previous cards and did
  not collapse reliably.

## What it shows

Same providers as the Windows port: Claude, Codex, Cursor, Grok and Antigravity. Cells
for tools that are not installed are omitted.

## Build the AppImage

Build on **Ubuntu 22.04** (or a Distrobox of that image) so the glibc is old enough for
the distros above. A native Fedora/Bazzite host build will link a **newer** glibc and may
not run on Ubuntu 22.04.

On Bazzite / other ostree systems, do not layer GTK devel packages — use Distrobox:

```sh
distrobox create -n codenotch-build -i ubuntu:22.04
distrobox enter codenotch-build
sudo apt update
sudo apt install -y libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev \
  librsvg2-dev patchelf fuse libfuse2 pkg-config build-essential curl libssl-dev file
# rustup if needed, then from this directory:
./build-appimage.sh
# → target/release/bundle/appimage/Codenotch_1.13.1_amd64.AppImage
```

`build-appimage.sh` runs the Tauri AppImage bundler, then
`pack-appimage-host-webkit.sh`. That second step drops the Ubuntu WebKitGTK that
linuxdeploy would ship and keeps the cargo binary plus the hook sidecar.

The GitHub [Linux Package](../.github/workflows/linux-package.yml) workflow produces the
same `Codenotch.AppImage` artifact; it is **not** stored in git.

## Dev without packing

```sh
# still from Ubuntu 22.04 / Distrobox, so GTK headers are present
cargo run -p codenotch
./target/release/codenotch doctor
```

## Layout

```
.
├── build-appimage.sh              Tauri AppImage + thin repack
├── pack-appimage-host-webkit.sh   drop bundled WebKit, keep the cargo binary
├── codenotch/                     the Linux app (pill, hover card, settings, providers)
└── codenotch-hook/                tiny helper Claude Code calls to report session events
```

A pull request that touches this tree is built and tested; the check is skipped
inside forks until the pull request is opened here.

## License

MIT — see `LICENSE`. The Codenotch design and name belong to the upstream author.
