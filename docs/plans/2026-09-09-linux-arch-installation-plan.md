# Linux and Arch installation plan

Status: M0 complete and the first Arch/KDE runtime slice verified on
`feat/customizable-collapsible-notch`; native packaging remains planned.

## Goal

Ship a useful Linux build without forking the product into a third independent
implementation. The first supported target is Arch Linux on x86_64, with KDE
Plasma as the reference desktop. X11/XWayland is the reliable MVP path; native
Wayland remains best effort until its window-management limits are measured on
KDE, GNOME, and a wlroots compositor.

The Linux MVP should:

- install and launch as an ordinary desktop application;
- render the transparent edge notch and keep it above normal windows;
- expose a tray menu;
- read Claude Code, Codex, Cursor, and Antigravity usage from the existing
  read-only sources;
- observe local Claude/Codex/Cursor/Antigravity activity where Linux exposes
  enough information;
- install and remove the Claude Code hook without overwriting user hooks;
- start at login through the XDG autostart mechanism;
- provide `codenotch doctor` diagnostics;
- uninstall cleanly through the package manager.

Feature parity with the larger native macOS provider set is explicitly not an
MVP requirement. The Rust/Tauri port currently implements the four providers
listed above, and Linux should make that implementation reliable before more
providers are ported.

## Evidence from the current repository

The repository contains two application implementations:

1. `Sources/` and `Tests/` are the native Swift/AppKit application. It depends
   on macOS-only APIs, Sparkle, XcodeGen, signing, and notarization. It is not a
   realistic Linux compilation target.
2. `windows/` is a Rust workspace containing a Tauri 2 application and a small
   Claude hook client. Despite its directory name, much of it is already
   portable: provider HTTP parsing, persisted snapshots, the HTML/CSS UI,
   filesystem watching, SQLite access, the local HTTP server, and most state
   handling compile on Linux.

The first native check on Arch reached Tauri's generated context and failed
only because Unix builds require a PNG window icon while the bundle listed
only `icons/icon.ico`. Adding the existing 512 px PNG asset to
`bundle.icon` makes this command pass:

```sh
cd windows
CARGO_TARGET_DIR=/tmp/codenotch-linux-check \
  cargo check --workspace --all-targets --locked
```

Reference environment for that result:

- Arch Linux, x86_64;
- Rust/Cargo 1.98.0;
- KDE Plasma on Wayland with XWayland available;
- `webkit2gtk-4.1` 2.52.6;
- GTK 3.24.52;
- OpenSSL 3.6.4;
- librsvg 2.62.3.

The initial check proved source-level portability. Since then the Arch build has
also been run on KDE Plasma in a Wayland session through XWayland, including the
tray, fixed edge placement, persistent notch preferences, pin/hover behavior,
and detached terminal launch. Remaining Linux gaps are called out below.

### Verified development baseline (2026-09-11)

- Arch Linux x86_64 with KDE Plasma and Wayland; the app selects XWayland when
  both `WAYLAND_DISPLAY` and `DISPLAY` are present.
- Both `just arch build` and `just arch release` produce `codenotch` and
  `codenotch-hook`.
- The Rust suite contains 13 passing tests, including Linux geometry, scaling,
  input-region, animation, configuration round-trip, and hover-exit coverage.
- A release binary was installed in `~/.local/bin`, launched detached, and
  validated with `codenotch doctor`.
- Hover exit was exercised against the real X11 window: an open panel uses the
  transparent shell as a temporary exit guard, then restores the pill-only
  input region after the details close.

## Recommended architecture

Use the Rust/Tauri application as the shared Windows/Linux desktop port. Do not
attempt to compile the AppKit app on Linux, and do not copy the Rust source into
a new `linux/` tree.

Keep the existing `windows/` path during the first milestones so the functional
changes remain reviewable and the port can still be synchronized with its
upstream Windows repository. Once Linux runtime parity is established, a
separate mechanical change can rename it to `desktop/` or `ports/desktop/`.

Introduce a narrow platform boundary instead of spreading additional
`cfg(target_os)` blocks throughout provider code:

```text
Rust/Tauri application
├── shared: providers, parsing, state, watcher, server, UI
└── platform
    ├── windows: registry, Win32 focus, Credential Manager, process I/O
    └── linux: XDG autostart, open/focus helpers, procfs, Secret Service
```

The first extraction candidates are:

- external URL and directory opening from `main.rs` and `tray.rs`;
- autostart from `autostart.rs`;
- process/window focus and foreground detection from `focus.rs`;
- executable and application discovery from `codex.rs` and `glyphs.rs`;
- hook paths and process spawning from `hooks_install.rs` and
  `codenotch-hook/src/main.rs`;
- locale detection from `i18n.rs`;
- native credential access from `antigravity.rs`.

## Linux runtime decisions

### Windowing

The notch depends on four behaviors that compositors treat differently:
absolute placement, transparency, always-on-top, and non-activating input.
Tauri currently has unresolved upstream limitations for always-on-top windows
on Wayland. Therefore:

- MVP support is X11 and XWayland. When a Wayland session also provides
  `DISPLAY`, start the GTK backend as X11 before Tauri initializes.
- Native Wayland is opt-in/best effort until tested. The app must report the
  selected backend in `run.log` and `doctor`.
- Do not claim full Wayland support merely because the window opens.
- Add an environment override so developers can force `x11` or `wayland`
  without rebuilding.
- Test 100%, 125%, 150%, and 200% scaling. The current DPR correction was
  written around WebView2 behavior and must be verified independently under
  WebKitGTK.

The first runtime spike should render fixed demo data. It isolates compositor
behavior from credential and network problems.

### Dragging and pointer behavior

`left_button_down()` currently returns `false` outside Windows, so the custom
vertical drag ends immediately on Linux. Prefer Tauri's native window dragging
for Linux, followed by a move-event clamp to the primary monitor. If that does
not preserve the edge constraint under Wayland, keep constrained dragging for
X11 and expose reset-to-center in the tray on native Wayland.

The pointer watchdog uses portable Tauri cursor and window coordinates, but it
must be tested with fractional scaling and with transparent regions under both
backends.

### Opening URLs and folders

Replace direct `cmd /C start` and `explorer` calls with one shared helper:

- Windows: retain the current commands or use the same cross-platform API;
- Linux: use the XDG opener (`xdg-open`) or Tauri's official opener plugin;
- surface spawn failures in `run.log` instead of silently ignoring them.

If `xdg-open` is used directly, declare `xdg-utils` as a runtime dependency.

### Start at login

Keep the Windows registry implementation. On Linux, create and remove:

```text
$XDG_CONFIG_HOME/autostart/com.immidi.codenotch.desktop
```

falling back to `~/.config/autostart` when `XDG_CONFIG_HOME` is unset. The
desktop entry should use the packaged executable, include `--silent`, be
created atomically, and contain no shell interpolation. `is_enabled()` should
validate the entry rather than only testing that the file exists.

### Claude hook

The hook protocol and Unix parent-PID implementation are already portable.
The remaining fixes are mechanical:

- use `codenotch-hook` rather than `codenotch-hook.exe` on Linux;
- read the port from the XDG config path instead of `%APPDATA%`;
- spawn `codenotch` rather than `codenotch.exe`;
- package both binaries together so sibling discovery remains deterministic;
- retain backup-before-write behavior for `~/.claude/settings.json`;
- add tests for paths containing spaces and quotes.

### Provider compatibility

Expected MVP status after platform fixes:

| Provider | Linux data path | Expected status |
|---|---|---|
| Claude Code | `~/.claude/.credentials.json` and `~/.claude/projects/**/*.jsonl` | Mostly portable |
| Codex | `~/.codex/auth.json`, rollout logs, and state SQLite | Mostly portable; add `codex` on `PATH` discovery |
| Cursor | `$XDG_CONFIG_HOME/Cursor/User/globalStorage/state.vscdb` | Likely portable; validate AppImage and native installs |
| Antigravity | `ps`, `lsof`, local bridge, and transcript fallback | Partial; document `lsof` and validate process matching |

The Codex request currently sends a `(Windows)` user-agent string; it should
be generated from the target OS. `find_executable()` also searches Windows
filenames on `PATH` and needs a plain `codex` candidate on Unix.

Antigravity's non-Windows credential reader returns no credential. Keep the
local bridge and count fallback for the MVP. A later milestone can read Linux
Secret Service/keyring data if Antigravity actually stores a supported token
there; this must be observed, not guessed.

Claude Desktop's Windows process-I/O activity heuristic has no Linux
implementation. Report this capability as unavailable and rely on transcript
watching until a source-backed Linux signal is identified.

### Focus and activation

Arbitrary focus stealing is intentionally restricted on Wayland. Treat this as
a capability, not a hidden failure:

- X11/XWayland: map the session PID ancestry to a window and activate it with
  an X11 helper or native Xlib implementation;
- Wayland: attempt supported desktop-specific activation only when a reliable
  token/API exists; otherwise return an explicit unsupported result and keep
  notification/tray affordances working;
- `doctor` must print the backend and focus capability.

## Arch Linux packaging

Arch is the primary distribution target. Provide a repository-owned
`packaging/arch/PKGBUILD` first; submit an AUR package only after the source and
runtime checks are repeatable.

Build dependencies should match the current Tauri and Arch guidance:

```text
base-devel
cargo
webkit2gtk-4.1
openssl
libayatana-appindicator
librsvg
xdotool
```

The final list must be derived from `ldd`/`namcap`, not copied blindly from a
generic Tauri template. Candidate runtime additions are `xdg-utils`, `lsof`,
and an AppIndicator implementation. `xdotool` is only justified if the X11
focus/drag implementation uses it.

The package should install:

```text
/usr/bin/codenotch
/usr/bin/codenotch-hook
/usr/share/applications/com.immidi.codenotch.desktop
/usr/share/icons/hicolor/512x512/apps/com.immidi.codenotch.png
/usr/share/licenses/codenotch/LICENSE
```

Package rules:

- build with `cargo build --release --locked`;
- fetch dependencies in `prepare()` so `build()` can run offline;
- never write user autostart or Claude settings from `package()` or an install
  script;
- let the user enable autostart and hooks from the application;
- validate the desktop entry and run `namcap` on both PKGBUILD and package;
- test installation and removal in a clean Arch chroot.

Tauri's AppImage is the second distribution target for non-Arch systems. Deb
and RPM bundles can follow. Move `nsis` into `tauri.windows.conf.json` and put
Linux bundle targets in `tauri.linux.conf.json`; leaving `nsis` in the shared
configuration will make a Linux bundling command select the wrong installer.

## Delivery milestones

### M0 — reproducible Linux build

- [x] Add a PNG application icon to Tauri's bundle inputs.
- [x] Pass `cargo check --workspace --all-targets --locked` on Arch.
- [x] Pass the Rust test command on Arch (13 tests as of 2026-09-11).
- [x] Run `codenotch doctor` on Arch with an isolated XDG config directory.
- [ ] Split Windows and Linux Tauri bundle configuration.
- [ ] Add an Arch CI compile/test job.

Exit criterion: a clean Arch environment produces both binaries from the
locked workspace without modifying `Cargo.lock`.

### M1 — visible Arch runtime

- [x] Start with live local data on KDE/XWayland.
- [x] Verify transparency, always-on-top, tray, hover, and scaling on the Arch
  development host.
- [x] Add backend selection and diagnostics.
- [x] Replace Windows-only URL/directory opening with `xdg-open`.
- [ ] Implement Linux locale detection.

Exit criterion: a developer can run the notch for an hour without focus theft,
black backgrounds, clipping, or disappearing behind normal windows.

### M2 — provider and session integration

- [x] Fix and verify Linux executable and XDG config discovery.
- [ ] Port the Claude hook paths and launch behavior.
- [ ] Validate each provider with fixtures before live credentials.
- [ ] Implement X11 session focus and explicit Wayland degradation.
- [ ] Expand `doctor` with per-capability results.

Exit criterion: the four supported providers either show source-backed data or
an honest absent/unsupported state, and hook install/uninstall round-trips a
fixture without losing user configuration.

### M3 — native Arch package

- [ ] Add desktop entry, icon installation, and PKGBUILD.
- [ ] Run `desktop-file-validate`, `ldd`, and `namcap`.
- [ ] Install, upgrade, and remove in a clean Arch chroot.
- [ ] Verify XDG config survives upgrades and is not removed as package data.

Exit criterion: `makepkg -si` installs a launchable application and `pacman -R`
removes all package-owned files while preserving user data.

### M4 — wider Linux distribution

- [ ] Add AppImage smoke tests.
- [ ] Add deb/rpm only after their runtime dependencies are audited.
- [ ] Test KDE and GNOME under X11/XWayland and native Wayland.
- [ ] Test one wlroots compositor and document limitations.

## Test matrix

| Area | Arch reference | Additional coverage |
|---|---|---|
| Build | clean chroot, x86_64 | GitHub Actions Ubuntu compile check |
| Display | KDE Wayland + XWayland | KDE X11, GNOME Wayland, Hyprland |
| Scale | 100% and 150% | mixed-DPI dual monitor |
| Packaging | PKGBUILD + namcap | AppImage |
| Providers | fixture tests, then live opt-in smoke | missing/expired credentials |
| Lifecycle | launch, second launch, logout/login | upgrade and uninstall |

No automated test should print credential values. Live provider checks remain
manual and opt-in; CI uses sanitized fixtures.

## Known risks

1. **Wayland positioning and always-on-top.** This is the largest product risk,
   because the notch form factor depends on compositor-controlled behavior.
2. **Transparent WebKitGTK windows.** GPU/backend combinations can render black
   or blur after resize. Workarounds must be gated and documented rather than
   applied globally without evidence.
3. **Tray availability.** GNOME may require an AppIndicator extension even when
   the application builds successfully.
4. **Provider drift.** Credentials and internal endpoints belong to the tools
   being observed and can change independently of Codenotch.
5. **Directory naming.** Keeping Linux code in `windows/` is temporarily odd,
   but an early rename would create large review and synchronization noise.

## Upstream references

- [Tauri Linux prerequisites](https://v2.tauri.app/start/prerequisites/)
- [Tauri configuration and platform-specific overrides](https://v2.tauri.app/reference/config/)
- [Arch Rust package guidelines](https://wiki.archlinux.org/title/Rust_package_guidelines)
- [Arch desktop entry guidance](https://wiki.archlinux.org/title/Desktop_entries)
- [Arch `webkit2gtk-4.1` package](https://archlinux.org/packages/extra/x86_64/webkit2gtk-4.1/)
- [Tauri Wayland always-on-top limitation](https://github.com/tauri-apps/tauri/issues/13121)
- [Tao Wayland always-on-top limitation](https://github.com/tauri-apps/tao/issues/1134)
