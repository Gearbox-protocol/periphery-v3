#!/bin/bash

set -euo pipefail

SYMBOL="${1:-}"

if [ -z "${SYMBOL}" ]; then
    echo "Usage: $0 <SYMBOL>"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required but not installed"
    exit 1
fi

response="$(curl -s "https://public-feed.securitize.io/asset-info?symbol=${SYMBOL}")"

if ! echo "$response" | jq -e . >/dev/null 2>&1; then
    echo "Failed to parse API response as JSON"
    exit 1
fi

if [ "$(echo "$response" | jq -r 'has("data") and (.data | type == "array")')" != "true" ]; then
    echo "$response" | jq -r '.message // "query failed"'
    exit 1
fi

ZERO_ADDRESS=$(cast address-zero)

on_ramp="$(echo "$response" | jq -r '
    .data[]
    | select(.chainId == 1 or .chainId == "1")
    | .onramp
    | if type == "array" then .[] else empty end
    | select(.coin == "USDC")
    | .address
    ' | head -n 1)"

redemption_wallet="$(echo "$response" | jq -r '
    .data[]
    | select(.chainId == 1 or .chainId == "1")
    | .RedemptionWalletAddress
    ' | head -n 1)"

if [ -z "$on_ramp" ] || [ "$on_ramp" = "null" ]; then
    on_ramp="$ZERO_ADDRESS"
fi

if [ -z "$redemption_wallet" ] || [ "$redemption_wallet" = "null" ]; then
    redemption_wallet="$ZERO_ADDRESS"
fi

jq -cn \
    --arg onRamp "$on_ramp" \
    --arg redemptionWallet "$redemption_wallet" \
    '{onRamp: $onRamp, redemptionWallet: $redemptionWallet}'
