# Deployment Checklist

Use this as the release runbook for the router, Gnosis receiver system, and Tenderly Action.

## Preflight

- Confirm hardcoded USDS matches the live Ethereum xDai bridge token.
- Confirm hardcoded sUSDS has ERC-4626 code on Ethereum.
- Confirm the live bridge exposes `relayTokens(address,uint256)`.
- Confirm the Gnosis savings xDAI adapter has code at the expected address.
- Confirm `router.receiverFor(deterministicReceiver)` matches `factory.predict(deterministicReceiver)`.
- Prepare deployment secrets for the script runner: `MAINNET_RPC_URL`, `GNOSIS_RPC_URL`, and a dedicated
  deployment `PRIVATE_KEY`.
- Install Foundry dependencies into ignored `lib/` with `npm run install:foundry`.
- Run:
  - `forge fmt --check`
  - `forge build`
  - `forge test`
  - `node --check script/watchtower.mjs`
  - `node --check actions/receiverQueue.js`
  - `npm run test:actions`
- If RPC URLs are configured, run the fork smoke test as well.

## Deploy Gnosis Side

- Run `npm run deploy:gnosis` with `GNOSIS_RPC_URL`, `SAVINGS_XDAI_ADAPTER`, and the deployment
  `PRIVATE_KEY`.
- Deploy `SavingsXDaiReceiver` singleton and `SavingsXDaiReceiverFactory` first.
- The wrapper script broadcasts with `--verify --verifier sourcify`.
- Verify the factory points at the singleton you intended to deploy.
- Verify `factory.predict(deterministicReceiver)` returns the expected address on a fork or dry run.

## Deploy Mainnet Router

- Run `npm run deploy:mainnet` with `MAINNET_RPC_URL`,
  `SAVINGS_XDAI_RECEIVER_FACTORY`, `GNOSIS_SINGLETON`, and the deployment `PRIVATE_KEY`.
- Deploy `MainnetStablecoinBridgeRouter` after the Gnosis side is live.
- The wrapper script broadcasts with `--verify --verifier sourcify`.
- Verify the router is wired to:
  - hardcoded Ethereum USDS
  - hardcoded Ethereum sUSDS
  - the canonical Ethereum xDai bridge
  - the deployed Gnosis factory
  - the deployed Gnosis singleton
- Verify a sample bridge receipt emits `BridgeRequested` with the predicted Gnosis receiver.

## Deploy Tenderly Automation

- Deploy the single Tenderly Action `Deterministic-Bridger` from `tenderly.yaml`.
- Configure secrets:
  - `MAINNET_RPC_URL`
  - `SAVINGS_XDAI_RECEIVER_FACTORY`
  - `TENDERLY_GNOSIS_RPC_URL` or `GNOSIS_RPC_URL`
  - `WATCHTOWER_PRIVATE_KEY`
  - `WATCHTOWER_BATCH_SIZE`
  - `WATCHTOWER_MAX_AGE_SECONDS`
- Confirm the Action code hardcoded router matches the deployed router address before deploy.
- Keep `WATCHTOWER_PRIVATE_KEY` separate from deployment keys and fund it with only limited xDAI.
- Configure the frontend with the public webhook URL only. Do not ship Tenderly API keys or secrets to the browser.

## Post-Deploy Verification

- Register a fresh router receipt with `op=register`.
- Confirm Sourcify reports exact matches for the deployed contracts.
- Confirm `op=register` rejects stale, malformed, or unrelated receipts.
- Fund or simulate a receiver and confirm `op=process` calls `deployAndConvert` only for a receiver that already has xDAI.
- Confirm `WATCHTOWER_BATCH_SIZE` and `WATCHTOWER_MAX_AGE_SECONDS` behave as expected.
- Disable or delete older prefixed Tenderly Actions after the new Action is verified.
