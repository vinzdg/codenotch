# desktop.just — OPTIONAL module (loaded via `mod? desktop`).
# Safe to delete this file: the root Justfile's `mod?` makes it non-fatal.

set working-directory := '../..'

# Show the Rust/Tauri desktop subcommands.
default:
    @echo "desktop subcommands: build, run, doctor"

# Build both Rust workspace binaries in release mode.
[unix]
build:
    @bash .just/scripts/unix/desktop.sh build

# Run the Rust/Tauri application.
[unix]
run:
    @bash .just/scripts/unix/desktop.sh run

# Run Codenotch's provider and environment diagnostics.
[unix]
doctor:
    @bash .just/scripts/unix/desktop.sh doctor
