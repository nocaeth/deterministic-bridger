# Tenderly Actions Watchtower

This Tenderly Web3 Actions setup uses one public webhook Action, `Deterministic-Bridger`.
It is idle by default: there is no block trigger, periodic trigger, or polling loop inside Tenderly.
The frontend wakes it only after a bridge transaction is mined and while the browser session still has
active bridges to finalize.

## Action

- `Deterministic-Bridger`: unauthenticated webhook that dispatches `register`, `process`, and `inspect`
  payloads through `receiverQueue:handle`.

The Action stores only pending jobs. Completion, waiting, stale removal, and errors are visible in
Action execution logs rather than retained as completed history in Tenderly Storage.

State shape:

```json
{
  "status": "idle",
  "pending": [],
  "updatedAt": 0,
  "lastRunAt": 0
}
```

## Secrets

Set these Tenderly Action secrets:

```text
MAINNET_RPC_URL=<Ethereum RPC URL used to read mined receipts>
TENDERLY_GNOSIS_RPC_URL=<Tenderly Virtual Environment, fork, or Gnosis RPC URL>
GNOSIS_RPC_URL=<fallback Gnosis RPC URL when TENDERLY_GNOSIS_RPC_URL is unset>
ROUTER=<MainnetStablecoinBridgeRouter on Ethereum>
SAVINGS_XDAI_RECEIVER_FACTORY=<SavingsXDaiReceiverFactory on Gnosis>
WATCHTOWER_PRIVATE_KEY=<funded executor private key>
WATCHTOWER_BATCH_SIZE=25
WATCHTOWER_MAX_AGE_SECONDS=604800
```

`WATCHTOWER_PRIVATE_KEY` should be a dedicated low-balance executor key, not the deployment key.

The webhook is unauthenticated because it is called directly from the browser. Do not put Tenderly API
credentials in frontend code. `op=register` is safe to expose because it only stores work after
validating a mined router event. `op=process` is also public, so it should stay cheap and bounded by
`WATCHTOWER_BATCH_SIZE`; callers cannot redirect funds because `deployAndConvert` is permissionless
and derives the receiver from stored event data.

For fork or VNet tests, set `TENDERLY_GNOSIS_RPC_URL` to the Tenderly environment. For production,
point it at Gnosis or omit it and use `GNOSIS_RPC_URL`.

## Webhook Payloads

Register a mined mainnet bridge transaction:

```json
{
  "op": "register",
  "mainnetTxHash": "0x...",
  "logIndex": 123
}
```

`logIndex` is optional. When present, only that router `BridgeRequested` log is registered. When
omitted, every `BridgeRequested(address,address,address,uint256)` log emitted by `ROUTER` in the
transaction is registered.

Process pending receivers:

```json
{
  "op": "process"
}
```

Inspect current storage state:

```json
{
  "op": "inspect"
}
```

## Register Validation

`op=register` does not trust caller-supplied receiver data. It:

1. Fetches the mainnet transaction receipt through `MAINNET_RPC_URL`.
2. Rejects missing, reverted, or unrelated transactions.
3. Rejects receipts older than `WATCHTOWER_MAX_AGE_SECONDS`.
4. Requires a `BridgeRequested` log emitted by configured `ROUTER`.
5. Reads `payer`, `deterministicReceiver`, `gnosisReceiver`, and `amount` from the event.
6. Verifies `SavingsXDaiReceiverFactory.predict(deterministicReceiver) == gnosisReceiver`.
7. Stores or refreshes one pending job, deduped by `gnosisReceiver.toLowerCase()`.

Stored jobs contain:

```json
{
  "id": "0x...",
  "deterministicReceiver": "0x...",
  "gnosisReceiver": "0x...",
  "mainnetTxHash": "0x...",
  "logIndex": 123,
  "amount": "1000000000000000000",
  "payer": "0x...",
  "registeredAt": 0,
  "updatedAt": 0,
  "attempts": 0,
  "lastCheckedAt": null,
  "lastError": null
}
```

Re-registering the same deterministic Gnosis receiver refreshes the existing job instead of adding a
duplicate. This makes browser reload recovery safe.

## Process Behavior

Each `op=process` run:

1. Loads `sdai-receiver-watchtower:state` from Tenderly Storage.
2. Removes jobs older than `WATCHTOWER_MAX_AGE_SECONDS` and logs them as stale.
3. Checks up to `WATCHTOWER_BATCH_SIZE` remaining jobs.
4. Keeps a job pending while `eth_getBalance(gnosisReceiver) == 0`.
5. Calls `SavingsXDaiReceiverFactory.deployAndConvert(deterministicReceiver)` when the receiver balance is
   positive.
6. Removes the job from `pending` after a successful conversion transaction.
7. Keeps the job pending and records `lastError` after a revert or RPC failure.

When `pending` becomes empty, the Action writes `status: "idle"`. It will not execute again unless the
frontend or another public caller calls the webhook.

## Frontend Web2 Flow

1. Load config:
   - Mainnet router address.
   - Gnosis factory address.
   - Gnosis singleton address.
   - Public `Deterministic-Bridger` webhook URL.
   - Ethereum and Gnosis RPC clients.
2. Before signing:
   - Determine `deterministicReceiver`.
   - Compute and display `gnosisReceiver` with `router.receiverFor(deterministicReceiver)` or the matching
     TypeScript `CREATE2` implementation.
   - Show the manual fallback call: `factory.deployAndConvert(deterministicReceiver)`.
3. User bridges:
   - If payer equals receiver, call `router.bridge(amount)`.
   - If payer funds another receiver, call `router.bridgeTo(deterministicReceiver, amount)`.
4. After wallet submission:
   - Track the transaction hash locally.
   - Do not register with Tenderly yet.
5. After the mainnet transaction is mined successfully:
   - Parse the receipt for `BridgeRequested`.
   - If the transaction reverted or has no event, show failure and do not register.
   - Call the webhook with `{ "op": "register", "mainnetTxHash": "0x...", "logIndex": 123 }`.
6. While the page/session is active:
   - Every 40-150 seconds, call the webhook with `{ "op": "process" }`.
   - Poll Gnosis RPC for `eth_getBalance(gnosisReceiver)`, `eth_getCode(gnosisReceiver)`, and
     `ConvertedToSavingsXDai` logs when available.
7. UI status rules:
   - `mainnet tx pending`: waiting for mainnet receipt.
   - `registered / bridge finalizing`: registered and `gnosisReceiver` xDAI balance is zero.
   - `ready to convert`: `gnosisReceiver` xDAI balance is positive.
   - `converted`: receiver code exists and a `ConvertedToSavingsXDai` log is found, or xDAI balance
     returns to zero after previously being positive.
   - `needs manual claim`: automation has not resolved after timeout; show a button calling
     `factory.deployAndConvert(deterministicReceiver)`.
8. On page reload:
   - Recompute `gnosisReceiver`.
   - Re-read the mainnet transaction receipt if the transaction hash is known.
   - Re-call `op=register`; receiver dedupe makes this safe.
   - Resume `op=process` pings while the UI is open.
9. When no local active bridges remain:
   - Stop pinging the Action.
   - The Tenderly Action remains deployed but idle and costs no execution while not invoked.

## Validation

Local checks:

```bash
node --check actions/receiverQueue.js
node --test actions/test/*.test.js
tenderly actions validate
tenderly actions build
forge fmt --check
forge build
forge test
```

The Action test suite uses the deployed addresses from `.env`. It mocks Tenderly storage/secrets and
mainnet receipts for deterministic registration cases, reads the live deployed mainnet router and
Gnosis factory for wiring checks, and uses an Anvil fork of Gnosis to test funded receiver conversion
without mutating production state.

Tenderly VM smoke:

1. Register a mined or simulated valid bridge receipt.
2. Fund the predicted receiver with `tenderly_setBalance`.
3. Run `{ "op": "process" }`.
4. Verify the receiver clone exists, receiver xDAI balance is zero, and `pending` is empty.
