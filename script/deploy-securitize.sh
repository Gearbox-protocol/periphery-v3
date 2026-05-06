#!/bin/bash

set -e

if [ -z "$ANVIL_URL" ]; then
    export ANVIL_URL="http://127.0.0.1:8545"
fi

if [ -z "$AUTHOR_PRIVATE_KEY" ]; then
    export AUTHOR_PRIVATE_KEY="0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"
    echo "AUTHOR_PRIVATE_KEY is not set, using default anvil key"
fi

DS_TOKENS_TO_PREPARE=""
if [ -n "$VAULT_REGISTRAR" ]; then
    IFS=',' read -r -a REGISTRARS <<< "$VAULT_REGISTRAR"
    RESOLVED_DS_TOKENS=()
    for REGISTRAR in ${REGISTRARS[@]}; do
        [ -z "$REGISTRAR" ] && continue
        RESOLVED_DS_TOKENS+=($(cast call $REGISTRAR "token() returns (address)" --rpc-url ${ANVIL_URL}))
    done
    DS_TOKENS_TO_PREPARE=$(IFS=','; echo "${RESOLVED_DS_TOKENS[*]}")
elif [ -n "$DS_TOKEN" ]; then
    DS_TOKENS_TO_PREPARE=$DS_TOKEN
fi

if [ -n "$DS_TOKENS_TO_PREPARE" ]; then
    IFS=',' read -r -a TOKENS <<< "$DS_TOKENS_TO_PREPARE"
    for TOKEN in ${TOKENS[@]}; do
        [ -z "$TOKEN" ] && continue
        OWNER=$(cast call $TOKEN "owner() returns (address)" --rpc-url ${ANVIL_URL})
        cast rpc --rpc-url ${ANVIL_URL} anvil_impersonateAccount $OWNER
        cast rpc --rpc-url ${ANVIL_URL} anvil_setBalance $OWNER 0x56BC75E2D63100000
    done
fi

AUTHOR_ADDRESS=$(cast wallet address $AUTHOR_PRIVATE_KEY)
echo "author address is ${AUTHOR_ADDRESS}"

INSTANCE_OWNER="0x1E9ec044853611F4bCD4BBcFE7657508BD1c53D3"
echo "instance owner address is ${INSTANCE_OWNER}"

CROSS_CHAIN_GOVERNANCE="0xcCCCCcCc42B7DA9fdEc1761698Fb55fdD41CDF55"
echo "cross chain governance address is ${CROSS_CHAIN_GOVERNANCE}"

USDC_DONOR="0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640"
echo "usdc donor address is ${USDC_DONOR}"

RLUSD_DONOR="0x7D98e5FD009Eb13fdD6baE736484CcD1a5A0ab9F"
echo "rlusd donor address is ${RLUSD_DONOR}"

cast rpc --rpc-url ${ANVIL_URL} anvil_impersonateAccount $INSTANCE_OWNER
cast rpc --rpc-url ${ANVIL_URL} anvil_impersonateAccount $CROSS_CHAIN_GOVERNANCE
cast rpc --rpc-url ${ANVIL_URL} anvil_impersonateAccount $USDC_DONOR
cast rpc --rpc-url ${ANVIL_URL} anvil_impersonateAccount $RLUSD_DONOR

# Set balance for instance owner, cross-chain governance and usdc donor to 100 ETH
cast rpc --rpc-url ${ANVIL_URL} anvil_setBalance $INSTANCE_OWNER 0x56BC75E2D63100000
cast rpc --rpc-url ${ANVIL_URL} anvil_setBalance $CROSS_CHAIN_GOVERNANCE 0x56BC75E2D63100000
cast rpc --rpc-url ${ANVIL_URL} anvil_setBalance $USDC_DONOR 0x56BC75E2D63100000
cast rpc --rpc-url ${ANVIL_URL} anvil_setBalance $RLUSD_DONOR 0x56BC75E2D63100000

FORGE_CMD="forge script script/DeploySecuritizeContract.s.sol --unlocked --broadcast --rpc-url ${ANVIL_URL} --slow --skip-simulation 2>&1"

# When stdout is not a TTY (e.g. Docker without -t), forge skips per-transaction output.
# Run forge under `script` to attach a pseudo-TTY so we get full logs (tx hashes, etc.).
# When we already have a TTY, run forge directly.
if [ -t 1 ]; then
    if command -v stdbuf >/dev/null 2>&1; then
        stdbuf -oL -eL eval "$FORGE_CMD"
    else
        eval "$FORGE_CMD"
    fi
else
    script -q -c "$FORGE_CMD" /dev/null
fi

echo "bash script executed successfully"

# Adds deployed MC and RWA factory to properties of testnet
notify_anvil_manager() {
    if [ -z "$ANVIL_MANAGER_API" ]; then
        echo "ANVIL_MANAGER_API is not set, skipping anvil manager registration"
        return 0
    fi

    local addresses_file="${OUTPUT_DIR:-.}/rwa-addresses.json"
    if [ ! -f "$addresses_file" ]; then
        echo "ERROR: addresses file not found: ${addresses_file}"
        return 1
    fi

    local market_configurator factory
    market_configurator=$(jq -r '.marketConfigurator' "$addresses_file")
    factory=$(jq -r '.factory' "$addresses_file")

    echo "Registering market configurator: ${market_configurator}"
    if curl -sf -X POST \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg addr "$market_configurator" '[$addr]')" \
        "${ANVIL_MANAGER_API}/market-configurators"; then
        echo "Market configurator registered successfully"
    else
        echo "WARNING: Failed to register market configurator (exit code: $?)"
    fi

    echo "Registering RWA factory: ${factory}"
    if curl -sf -X POST \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg addr "$factory" '[$addr]')" \
        "${ANVIL_MANAGER_API}/rwa-factories"; then
        echo "RWA factory registered successfully"
    else
        echo "WARNING: Failed to register RWA factory (exit code: $?)"
    fi
}

notify_anvil_manager || echo "WARNING: Failed to notify anvil manager"

# Give Docker/Loki log driver time to flush before container exits (avoids losing last lines)
sleep 2

