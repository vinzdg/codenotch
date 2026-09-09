# tests.just — test suites.

set working-directory := '../..'

_unix := '.just/scripts/unix'

# Show the tests subcommands.
default:
    @echo "tests subcommands: all"

# Run every test suite.
all:
    @bash {{_unix}}/tests.sh all
