#!/bin/bash
set -eu

# Check delegation without making RPC calls or deploying contracts.
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/bash" <<'EOF'
#!/bin/bash
set -eu
test "$DEPLOY_ON_DEMAND" = false
test "$DS_TOKEN" = test-token
test "$1" = "$EXPECTED_SCRIPT"
test "$2" = test-argument
exit 42
EOF
chmod +x "$test_dir/bash"

export EXPECTED_SCRIPT="$(dirname "$0")/deploy-securitize.sh"
status=0
PATH="$test_dir:$PATH" DEPLOY_ON_DEMAND=true DS_TOKEN=test-token \
    /bin/bash "$(dirname "$0")/deploy-securitize-default.sh" test-argument || status=$?
test "$status" -eq 42
echo "Default Securitize wrapper check passed"
