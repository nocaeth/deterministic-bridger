#!/usr/bin/env bash
set -euo pipefail

: "${MAINNET_RPC_URL:?Set MAINNET_RPC_URL}"
: "${MAINNET_TOKEN:?Set MAINNET_TOKEN}"
: "${SAVINGS_XDAI_RECEIVER_FACTORY:?Set SAVINGS_XDAI_RECEIVER_FACTORY}"
: "${GNOSIS_SINGLETON:?Set GNOSIS_SINGLETON}"
: "${PRIVATE_KEY:?Set PRIVATE_KEY}"

forge script script/DeployMainnetRouter.s.sol:DeployMainnetRouter \
  --rpc-url "$MAINNET_RPC_URL" \
  --broadcast \
  --verify \
  --verifier sourcify \
  --retries "${FOUNDRY_VERIFY_RETRIES:-10}" \
  --delay "${FOUNDRY_VERIFY_DELAY:-10}" \
  "$@"
