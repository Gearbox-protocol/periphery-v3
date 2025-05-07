#!/bin/bash

set -e

if [ -z "$ANVIL_URL" ]; then
    ANVIL_URL="http://127.0.0.1:8545"
fi

if [ -z "$AUDITOR_PRIVATE_KEY" ]; then
    AUDITOR_PRIVATE_KEY="0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"
    echo "AUDITOR_PRIVATE_KEY is not set, using default anvil key"
fi

AUDITOR_ADDRESS=$(cast wallet address $AUDITOR_PRIVATE_KEY)
echo "auditor address is ${AUDITOR_ADDRESS}"

CCM_PROXY_ADDRESS="0xb1576bba248d48cbdf50000db84a0df8cde7b3ca"
echo "ccm proxy address is ${CCM_PROXY_ADDRESS}"

cast rpc anvil_impersonateAccount $CCM_PROXY_ADDRESS
cast rpc anvil_impersonateAccount $AUDITOR_ADDRESS

# Set balance for ccmProxy and the address corresponding to AUDITOR_PRIVATE_KEY to 100 ETH
cast rpc anvil_setBalance $CCM_PROXY_ADDRESS 0x56BC75E2D63100000
cast rpc anvil_setBalance $AUDITOR_ADDRESS 0x56BC75E2D63100000

forge script script/MockTestnetBytecodeUpload.s.sol --unlocked --broadcast --rpc-url ${ANVIL_URL}

echo "bash script executed successfully"
