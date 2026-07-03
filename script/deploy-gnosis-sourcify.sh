#!/usr/bin/env bash
set -euo pipefail

: "${GNOSIS_RPC_URL:?Set GNOSIS_RPC_URL}"
: "${SAVINGS_XDAI_ADAPTER:?Set SAVINGS_XDAI_ADAPTER}"

forge script script/DeploySavingsXDaiReceiverSystem.s.sol:DeploySavingsXDaiReceiverSystem \
  --rpc-url "$GNOSIS_RPC_URL" \
  --broadcast \
  --verify \
  --verifier sourcify \
  --retries "${FOUNDRY_VERIFY_RETRIES:-10}" \
  --delay "${FOUNDRY_VERIFY_DELAY:-10}" \
  "$@"
