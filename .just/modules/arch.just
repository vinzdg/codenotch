# arch.just — Arch Linux-specific builds for the Rust/Tauri desktop port.

set working-directory := '../..'

# Show the Arch Linux build subcommands.
default:
    @echo "arch subcommands: build, release"

# Build debug binaries for a quick development cycle.
[unix]
build:
    @bash .just/scripts/unix/arch-build.sh debug

# Build optimized release binaries suitable for manual installation.
[unix]
release:
    @bash .just/scripts/unix/arch-build.sh release
