#!/bin/bash
set -e

# Deploy regular USDC and RLUSD markets without the on-demand market.
export DEPLOY_ON_DEMAND=false
exec bash "$(dirname "$0")/deploy-securitize.sh" "$@"
