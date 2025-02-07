#!/bin/bash

ANVIL_URL=${1:-http://localhost:8545}

forge script script/V30Fix.sol:V30Fix --rpc-url ${ANVIL_URL} --unlocked --sender 0x0000000000000000000000000000000000000000 --ffi --broadcast
forge script script/V31Install.sol:V31Install --rpc-url ${ANVIL_URL} --broadcast

# SHARED_DIR is set on testnets
if [ -n "$SHARED_DIR" ] && [ -f "addresses.json" ]; then
    echo "Copying addresses.json to ${SHARED_DIR}"
    cp addresses.json ${SHARED_DIR}
fi
