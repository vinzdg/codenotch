#!/usr/bin/env bash
# Build and run the shared desktop crate on Linux.
set -euo pipefail
cd "$(dirname "$0")/../desktop"
exec cargo run --release "$@"
