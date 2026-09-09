# Codenotch — Justfile workflow

A cross-platform [`just`](https://just.systems) setup that keeps OS-specific logic
out of your recipes. Generated from **JustfileConfigurator**.

## Quick start

```bash
just setup        # create .env, check tools
just doctor       # full diagnostics
just --list       # see every recipe
```

Requires `just` ≥ 1.52 (optional modules use `mod?`).

## Five-layer architecture

```text
Justfile                      entry point (imports + mods)
   ↓
Functional modules (.just/modules)   WHAT to do
   ↓
Bash / PowerShell scripts (.just/scripts)
   ↓
OS adapters (.just/adapters)         HOW to do it
   ↓
Declarative manifests (.just/manifests)   data, not code
```

- **Modules** define *what*: `config`, `tests`, and the optional Rust/Tauri
  `desktop` and Arch-specific `arch` modules.
- **Adapters** define *how*: Arch → `pacman`, Debian → `apt-get`, macOS → `brew`, Windows → `winget`.
- OS-sensitive recipes use the `[unix]` / `[windows]` attributes (never the deprecated `windows-shell`).
- Each module sets its own working directory, so namespaced commands execute
  consistently from the project root.

## Layout

```text
.
├── Justfile
├── .env.example
├── .just/
│   ├── modules/      project, config, tests, desktop?, arch?
│   ├── manifests/    commands.tsv, tools.tsv, runtime-packages.tsv,
│   │                 platforms.tsv, env.required
│   ├── scripts/      unix/ (bash), windows/ (ps1 placeholders)
│   └── adapters/     arch.sh, debian.sh, macos.sh, windows.ps1
├── backups/db/       reserved by the base scaffold; no project database detected
└── reports/          reserved for future coverage/report output
```

## Commands

| Command | Category | What it does |
|---|---|---|
| `just run` | safe | Run the project entry point |
| `just setup` | modifying | Create `.env`, check tools |
| `just check` / `just ci` | safe | Static checks / full pipeline |
| `just status` | safe | Project + platform status |
| `just platform` / `just platforms` | safe | Detect / list platforms |
| `just health` / `just health-all` | safe | Check required tools |
| `just cure-plan` / `just cure` | safe / confirm | Plan / install missing tools |
| `just doctor` | safe | Full diagnostics |
| `just config init｜check｜diff` | mixed | Manage `.env` vs `env.required` |
| `just tests all` | safe | Run tests |
| `just desktop build｜run｜doctor` | safe | Build, run, or diagnose the Rust/Tauri port |
| `just arch build` | safe | Build debug binaries on Arch Linux |
| `just arch release` | safe | Build optimized release binaries on Arch Linux |

`desktop` and `arch` are optional (`mod?`). The latter rejects non-Arch hosts
before invoking Cargo.

## Adding a new OS

1. Add a row to `.just/manifests/platforms.tsv` (keep Arch → Debian → macOS → Windows order).
2. Add a package column to `.just/manifests/tools.tsv`.
3. Create `.just/adapters/<os>.sh` implementing `pkg_mgr` / `pkg_check` / `pkg_install` / `pkg_install_cmd`.
4. Extend `detect_platform()` in `.just/scripts/unix/lib.sh`.
5. Add `[<os>]` recipe variants where behaviour differs.

## Customising

The Unix lifecycle scripts are wired to `windows/Cargo.toml`. Native macOS
Make/Xcode workflows remain listed in `pending.tsv` until they are configured
on a macOS host. The manifests are the single source of truth for tooling and
the generated dashboard.
