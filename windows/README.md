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

### Updates

Codenotch looks for a newer release about twenty seconds after it starts, and again whenever
**Check for updates** is pressed in Settings → General. The feed is `latest.json` on the newest
release, written by the Windows Package workflow beside the installer it describes, so publishing
a release is the whole of shipping an update.

Nothing about this nags. A check that fails — no network, an unreachable feed — leaves the app
as it was and says so only next to the version. There is no dialogue and no badge.

The download is a minisign-signed archive, and the signature is checked against the public key in
`tauri.conf.json` before anything is run. This is what stands in for code signing here: the
installer itself is unsigned, so SmartScreen still warns on a first manual install, but an update
delivered to an already-installed copy is verified.

Before the first signed release, the key has to exist:

```powershell
npx --yes @tauri-apps/cli@2.11.4 signer generate -w $env:USERPROFILE\.tauri\codenotch.key
```

Put the **private** key in the repository secret `TAURI_SIGNING_PRIVATE_KEY` and its password in
`TAURI_SIGNING_PRIVATE_KEY_PASSWORD`, and paste the **public** key into `plugins.updater.pubkey`
in `desktop/codenotch/tauri.conf.json`, replacing `REPLACE_WITH_TAURI_PUBLIC_KEY`. Until that is done the
app skips the check entirely rather than reporting a failure nobody can act on; the packaging job
builds an ordinary installer and warns that it made no feed, and a `v*` release fails loudly rather
than going out with an update path nobody can use.

Keep the private key. Losing it means no installed copy can be updated again, because every one of
them checks against the public key it shipped with — they would all have to reinstall by hand.

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
