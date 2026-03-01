#!/bin/bash

set -e

if [ -z "$ANVIL_URL" ]; then
    export ANVIL_URL="http://127.0.0.1:8545"
fi

if [ -z "$AUTHOR_PRIVATE_KEY" ]; then
    export AUTHOR_PRIVATE_KEY="0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"
    echo "AUTHOR_PRIVATE_KEY is not set, using default anvil key"
fi

AUTHOR_ADDRESS=$(cast wallet address $AUTHOR_PRIVATE_KEY)
echo "author address is ${AUTHOR_ADDRESS}"

IM_PROXY="0xBcD875f0D62B9AA22481c81975F9AE1753Fc559A"
echo "im proxy address is ${IM_PROXY}"

USDC_DONOR="0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640"
echo "usdc donor address is ${USDC_DONOR}"


cast rpc --rpc-url ${ANVIL_URL} anvil_impersonateAccount $AUTHOR_ADDRESS
cast rpc --rpc-url ${ANVIL_URL} anvil_impersonateAccount $IM_PROXY
cast rpc --rpc-url ${ANVIL_URL} anvil_impersonateAccount $USDC_DONOR

# Set balance for author, im proxy and usdc donor to 100 ETH
cast rpc --rpc-url ${ANVIL_URL} anvil_setBalance $AUTHOR_ADDRESS 0x56BC75E2D63100000
cast rpc --rpc-url ${ANVIL_URL} anvil_setBalance $IM_PROXY 0x56BC75E2D63100000
cast rpc --rpc-url ${ANVIL_URL} anvil_setBalance $USDC_DONOR 0x56BC75E2D63100000

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

# Give Docker/Loki log driver time to flush before container exits (avoids losing last lines)
sleep 2

