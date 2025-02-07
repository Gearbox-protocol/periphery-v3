#!/bin/bash

if [ -z "$ANVIL_URL" ]; then
    ANVIL_URL="http://127.0.0.1:8545"
fi

forge script script/V30Fix.sol:V30Fix --rpc-url ${ANVIL_URL} --unlocked --sender 0x0000000000000000000000000000000000000000 --ffi --broadcast
forge script script/V31Install.sol:V31Install --rpc-url ${ANVIL_URL} --broadcast

# SHARED_DIR is set on testnets
if [ -n "$SHARED_DIR" ] && [ -f "addresses.json" ]; then
    echo "Copying addresses.json to ${SHARED_DIR}"
    cp addresses.json ${SHARED_DIR}
fi
