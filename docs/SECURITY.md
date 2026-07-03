# Security Review

This review covers the contracts, Tenderly Action, deployment scripts, and browser-driven automation
flow in this repository.

## Current Deployments

- Ethereum router: `0xae6bC9700c838828870C2e950fa457308BfEEa40`
- Gnosis receiver singleton: `0x9C9790A9fcd56398a96a415439bEa1be6D6dcF99`
- Gnosis receiver factory: `0x0D53e8be621d280151B664c62A52EF4194bc5531`
- Tenderly Action: `Deterministic-Bridger`

The deployed router is wired to DAI on Ethereum, the canonical Ethereum xDai bridge, and the Gnosis
factory/singleton above. Sourcify reported exact matches for all three contracts after deployment.

## Trust Boundaries

- Users trust the configured Ethereum token and foreign bridge pair to relay the configured token to
  Gnosis.
- Users trust the Gnosis factory and singleton addresses embedded in the Ethereum router.
- Users trust the configured Savings xDAI adapter used by the receiver singleton.
- The Tenderly Action is an untrusted executor. It cannot redirect funds because registration derives
  jobs from router events and conversion pays the stored `deterministicReceiver`.
- The public webhook is callable by anyone. This is required for a browser-only frontend and is safe
  only because the Action validates fresh on-chain events before storing jobs.

## Controls

- `op=register` fetches the Ethereum receipt through `MAINNET_RPC_URL`.
- `op=register` rejects missing, reverted, unrelated, stale, or malformed receipts.
- `op=register` only accepts `BridgeRequested` logs emitted by configured `ROUTER`.
- `op=register` verifies `factory.predict(deterministicReceiver) == gnosisReceiver`.
- Pending jobs are deduped by `gnosisReceiver.toLowerCase()`.
- `WATCHTOWER_MAX_AGE_SECONDS` bounds both newly registered receipt age and pending job lifetime.
- `WATCHTOWER_BATCH_SIZE` bounds conversion attempts per public `op=process` call.
- Tenderly execution is sequential, reducing storage write races.
- The contracts have no admin sweep, pause, upgrade, or arbitrary recipient path.
- ERC-20 recovery on receiver clones always sends to the bound `deterministicReceiver`.

## Residual Risks

- Public callers can still trigger Action executions and logs. Keep the Action cheap, maintain a small
  `WATCHTOWER_BATCH_SIZE`, and monitor Tenderly usage.
- Public callers can trigger `op=process` earlier than the frontend would. This can spend executor gas,
  but only on permissionless `deployAndConvert` calls for validated pending jobs.
- The executor key should be separate from deployment/admin keys and hold only enough xDAI for
  operations. It is not a funds custodian, but leaked key material could be abused to burn its gas
  balance.
- A compromised or misconfigured `MAINNET_RPC_URL` could lie about receipts. Use a reliable Ethereum RPC
  provider and monitor Action errors.
- A bridge or adapter upgrade outside this repository can change assumptions. Re-run fork smoke tests
  and deployed wiring checks after upstream bridge/adapter upgrades.

## Operational Checklist

- Keep `Deterministic-Bridger` as a public webhook; do not expose Tenderly API keys in frontend code.
- Store `MAINNET_RPC_URL`, `GNOSIS_RPC_URL` or `TENDERLY_GNOSIS_RPC_URL`, `ROUTER`,
  `SAVINGS_XDAI_RECEIVER_FACTORY`, and `WATCHTOWER_PRIVATE_KEY` as Tenderly Action secrets.
- Set `WATCHTOWER_BATCH_SIZE` to a small value, such as `25` or lower if usage spikes.
- Set `WATCHTOWER_MAX_AGE_SECONDS` to the maximum bridge-finalization window you are willing to service.
- Keep the executor account funded with a limited xDAI balance, and do not reuse the deployment key as
  `WATCHTOWER_PRIVATE_KEY`.
- Run `npm run test:actions` before Action deployment; it validates deployed wiring and fork-backed
  conversion behavior without mutating production state.
- Run `forge test` and fork smoke checks before contract deployment and after bridge/adapter upgrades.
