#!/bin/bash
# Exercise the Makefile without touching a keychain or invoking Xcode. A
# certificate-only fixture catches the case that broke contributor builds.
set -euo pipefail

cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT

cat > "$fixture_dir/security" <<'EOF'
#!/bin/bash
case "$1" in
    find-identity) printf '%s\n' "$SIGNING_IDENTITIES" ;;
    find-certificate) printf '%s\n' 'certificate without a private key' ;;
esac
EOF
cat > "$fixture_dir/openssl" <<'EOF'
#!/bin/bash
cat > /dev/null
printf '%s\n' 'subject=OU = ORPHAN1234, CN = Apple Development: Contributor'
EOF
chmod +x "$fixture_dir/security" "$fixture_dir/openssl"
export PATH="$fixture_dir:$PATH"

check_signing() {
    local label="$1" expected="$2" target output
    for target in build test run; do
        output=$(make -n "$target")
        if [[ "$output" != *"$expected"* ]]; then
            printf 'FAIL: %s (%s)\n%s\n' "$label" "$target" "$output"
            exit 1
        fi
    done
    printf 'PASS: %s\n' "$label"
}

export SIGNING_IDENTITIES='    0 valid identities found'
check_signing 'certificate without a valid identity uses ad-hoc' \
    'Debug CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic'

SIGNING_IDENTITIES='  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Contributor (TEAM123456)"
     1 valid identities found'
check_signing 'valid development identity falls back to ad-hoc' \
    'Debug CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic'

SIGNING_IDENTITIES='  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Contributor (TEAM123456)"
  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Another Contributor (TEAM654321)"
     2 valid identities found'
check_signing 'multiple development identities fall back to ad-hoc' \
    'Debug CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic'

SIGNING_IDENTITIES='  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Maintainer (6WFPL8B9FB)"
  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Contributor (TEAM123456)"
     2 valid identities found'
check_signing 'Developer ID preserves project signing settings' 'Debug  '
