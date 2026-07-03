# Security Model

This review covers the deployed contracts, Tenderly webhook Action, deployment scripts, and browser-driven
frontend flow in this repository.

## Deployed Contracts

- Ethereum router: `0xae6bC9700c838828870C2e950fa457308BfEEa40`
- Gnosis receiver singleton: `0x9C9790A9fcd56398a96a415439bEa1be6D6dcF99`
- Gnosis receiver factory: `0x0D53e8be621d280151B664c62A52EF4194bc5531`
- Gnosis Savings xDAI adapter: `0xD499b51fcFc66bd31248ef4b28d656d67E591A94`
- Tenderly Action: `Deterministic-Bridger`

These are the live trust anchors the frontend and watchtower depend on.

## Trust Boundaries

- Users trust the configured Ethereum token and canonical xDai bridge pair to deliver the bridged asset to the
  predicted Gnosis receiver.
- Users trust the Gnosis factory and singleton embedded in the router; if either address changes, the
  deterministic address path changes.
- Users trust the Savings xDAI adapter used by the receiver singleton.
- The Tenderly Action is an untrusted executor. It may observe state, register jobs, and call public conversion
  paths, but it cannot redirect funds to an arbitrary recipient.
- The public webhook is intentionally unauthenticated. Any caller may trigger it, so all safety must come from
  receipt validation, deterministic address checks, and bounded execution.
- RPC providers are trusted for receipt retrieval and block timestamps. A bad RPC can mislead the Action, so use
  a reliable provider and monitor failures.

## Security Controls

- `op=register` fetches the Ethereum receipt from `MAINNET_RPC_URL`.
- `op=register` rejects missing, reverted, unrelated, malformed, or stale receipts.
- `op=register` only accepts `BridgeRequested` logs emitted by the configured router.
- `op=register` rejects multi-receiver receipts unless the caller provides the
  intended `logIndex`.
- `op=register` verifies `factory.predict(deterministicReceiver) == gnosisReceiver`.
- Pending jobs are deduped by `gnosisReceiver.toLowerCase()`.
- `WATCHTOWER_MAX_AGE_SECONDS` bounds both receipt age and pending job lifetime.
- `WATCHTOWER_BATCH_SIZE` bounds conversion attempts per public `op=process` call.
- `op=process` only calls `deployAndConvert` when the receiver already holds xDAI.
- Tenderly execution is sequential, which reduces storage write races.
- The contracts have no admin sweep, pause, upgrade, or arbitrary-recipient path.
- ERC-20 recovery on receiver clones always sends to the bound deterministic receiver.

## Secret Handling

- Keep `MAINNET_RPC_URL`, `GNOSIS_RPC_URL` or `TENDERLY_GNOSIS_RPC_URL`, `ROUTER`,
  `SAVINGS_XDAI_RECEIVER_FACTORY`, and `WATCHTOWER_PRIVATE_KEY` in Tenderly Action secrets.
- Keep deployment-only `PRIVATE_KEY` separate from `WATCHTOWER_PRIVATE_KEY`.
- Do not ship Tenderly API keys, private keys, or authenticated RPC URLs to frontend code.
- Keep the executor wallet funded with only the xDAI needed for operations; it is not a custody key.

## Residual Risks

- Public callers can still trigger webhook executions and logs. That can consume Tenderly quota or executor gas,
  but it cannot redirect funds if the receipt and factory checks pass.
- A compromised or misconfigured RPC can lie about receipts or timestamps. Re-run fork smoke checks after RPC
  or bridge changes.
- The public webhook increases noise and DoS surface. Keep `WATCHTOWER_BATCH_SIZE` small and monitor webhook
  volume.
- Upstream bridge or adapter changes can invalidate assumptions. Re-check deployed wiring and receiver
  conversions after any such upgrade.

## Operational Controls

- Keep `Deterministic-Bridger` public; do not add frontend-authenticated secrets as a workaround.
- Run `forge test`, `forge build`, `node --check script/watchtower.mjs`, `node --check actions/receiverQueue.js`,
  and `npm run test:actions` before deployment.
- Use a low-balance dedicated executor account and rotate it separately from deployment keys.
- Disable or delete older prefixed Tenderly Actions after the new Action is live.
