# Codenotch for Windows

The Windows app is the shared Rust/Tauri 2 crate in
[`../desktop`](../desktop/README.md). This folder is the Windows front door —
download, installer, and where to build — not a second copy of the source.

Linux has the same split: [`../linux`](../linux/README.md) is the Linux front
door; OS-specific code lives in `desktop/codenotch/src/platform/`.

## Install

Download [`Codenotch-Setup.exe`](https://github.com/vinzdg/codenotch/releases/latest/download/Codenotch-Setup.exe)
from the latest release. It installs for the current user without administrator rights, puts
`codenotch-hook.exe` beside the app where **Install hooks** looks for it, and fetches WebView2 if
Windows does not already have it. The installer is not code-signed, so SmartScreen stops it the
first time with *Windows protected your PC*: choose **More info**, then **Run anyway**.

Every Windows change also leaves an installer on its
[Windows Package run](../../actions/workflows/windows-package.yml).

## Build from source

Prerequisites: Rust (MSVC toolchain), WebView2 runtime (ships with Windows 11).

```powershell
cd ..\desktop
cargo build --release
.\target\release\codenotch.exe          # pill appears on the right edge of the primary monitor
.\target\release\codenotch.exe doctor   # self-diagnosis: credentials, data sources, icons, hooks
```

To build the installer the way the Windows Package workflow does:

```powershell
cd ..\desktop
# the hook gets its own target dir, so the bundler never copies it onto itself
cargo build --release --locked -p codenotch-hook --target-dir target/hook
cd codenotch
npx @tauri-apps/cli@2 build --config tauri.bundle.conf.json
# → ..\target\release\bundle\nsis\Codenotch_<version>_x64-setup.exe
```

Providers, translations, notch placement and the rest of the app are documented
in [`../desktop/README.md`](../desktop/README.md).

## License

MIT — see [`../desktop/LICENSE`](../desktop/LICENSE). The Codenotch design and
name belong to the upstream author.
