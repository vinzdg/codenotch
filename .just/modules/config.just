# config.just — manage .env against .just/manifests/env.required.
# Relative working-directory resolves to the template root (this file lives in
# .just/modules/), so recipes run from the project root.

set working-directory := '../..'

_unix := '.just/scripts/unix'

# Show the config subcommands.
default:
    @echo "config subcommands: init, check, diff"

# Create .env from .env.example (never overwrites an existing .env).
init:
    @bash {{_unix}}/config.sh init

# Verify every variable in env.required is set.
check:
    @bash {{_unix}}/config.sh check

# Show keys that differ between .env and .env.example.
diff:
    @bash {{_unix}}/config.sh diff
