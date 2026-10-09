# AMB settlement router deployment and operations

Implementation and fork verification do not authorize production deployment,
seed funding or changing traffic. The application contracts have **no deployed
address**.

## Reciprocal deployment

Use separate, funded, dedicated router and settlement router deployment accounts. The settlement router
deployer must have the **same nonce on Ethereum and Gnosis**: its Ethereum CREATE
deploys the return receiver at the Gnosis settlement router's address. Fund that account for
both the Ethereum receiver and Gnosis settlement router transactions. Both accounts must have
no pending transactions and remain idle between dry-run and broadcast. Supply
`MAINNET_RPC_URL`, `GNOSIS_RPC_URL`,
`MAINNET_DEPLOYER_PRIVATE_KEY`, `GNOSIS_DEPLOYER_PRIVATE_KEY`, a reviewed
`MAINNET_PAUSE_AUTHORITY` and the reviewed `SAVINGS_XDAI_ADAPTER` through private
environment configuration. Use a reviewed Ethereum Safe with threshold at least two
for the bridge council and recovery authority. Its address is immutable; it can
deprecate/resume, acknowledge a bridge implementation and transfer returned
DAI/USDS. Independently verify the Safe address, owners and threshold; the script
checks only that the configured contract reports a threshold of at least two.
Set positive
`MAINNET_MAX_DEPLOYMENT_COST_WEI` and `GNOSIS_MAX_DEPLOYMENT_COST_WEI` to reviewed
per-transaction gas ceilings; the script fixes the fee fields at the checked
quote and rejects a quote above either ceiling. Never put a production key in a
command argument, checked-in file or shared shell history.
The script uses the fixed canonical bridge and AMB addresses in its source.

1. Run `node --env-file=.env script/deploy-amb.mjs`. This compiles the contracts,
   checks both chain IDs, idle deployer nonces, current bridge/AMB configuration
   and code, adapter code, predicted CREATE addresses on both chains, gas estimates
   and deployer balances. Review the printed addresses, three nonces, token and
   adapter code hashes, Safe threshold, compiled contract hashes and maximum gas costs. Keep the
   `planHash` only after accepting the reviewed dependencies, pause authority and fixed addresses.
2. Set `DEPLOY_PLAN_HASH` to that exact hash and run
   `node --env-file=.env script/deploy-amb.mjs --broadcast` after deployment
   authorization. The script rechecks the reviewed plan, deploys and verifies
   the Ethereum return receiver first, then the Gnosis settlement router and Ethereum router.
   Record all three transaction hashes, addresses and creation blocks. The hash
   excludes changing fee quotes but includes deployer nonces, addresses, cost
   ceilings, compiled creation bytecode hashes, current bridge implementation
   addresses and token/adapter code hashes.
   The bridge implementation address is reviewed for this deployment and the
   router can later acknowledge a compatible upgrade; no bridge code hash is pinned.
   Never rerun broadcast after an ambiguous RPC
   response until both expected addresses and deployer
   nonces have been checked on chain; there is no automatic replacement.
3. Set `AMB_GNOSIS_ROUTER` and `AMB_GNOSIS_ROUTER_DEPLOYMENT_BLOCK` to the verified settlement router
   address and creation block for the executor. Independently verify reciprocal
   addresses on each chain: receiver.recoveryAuthority, router.gnosisRouter,
   router.homeBridge, router.foreignBridge, router.foreignAMB,
   router.pauseAuthority, gnosisRouter.sourceRouter,
   gnosisRouter.foreignBridge, gnosisRouter.homeBridge, gnosisRouter.homeAMB and gnosisRouter.adapter. Verify
   the receiver and settlement router addresses match, and chain IDs, local token and adapter
   code, zero home fee manager/shift and source AMB gas maximum >=700000. Review
   current bridge implementation changes for compatibility with nonce, transfer
   and processed-marker semantics. Confirm
   sUSDS reports USDS as its ERC-4626 asset. The foreign AMB endpoint reports
   source/destination 1/100; the home endpoint reports 100/1, while an incoming
   Ethereum callback must report message source chain 1. Verify bytecode and
   constructor arguments through Sourcify and publish the resulting ABIs.
   Do this before routing user deposits. The router starts deprecated; the Safe
   calls `resume()` only after the initial compatibility review.

The older single-chain Foundry scripts are simulation-only fork regression tests. They
require `PRIVATE_KEY` and explicit expected Ethereum nonce/router values. The
paired script above is the operational path. Its `--broadcast` flag and matching
review hash are required for transactions; dry-run sends none. No sponsor funding
or user traffic is part of this script. A failed deployment can leave a receiver
or a receiver plus Gnosis settlement router without the Ethereum source router;
inspect both chains and plan a new pair before activation.

## Executor setup

Use a **separate Gnosis gas account** and only one process per signer and state
file. Independent executors may use separate accounts/files; at-most-once payout
is enforced by the Gnosis settlement router. Do not concurrently run another bot or manually submit
transactions from the executor account while its nonce is outstanding.

Required environment:

```text
GNOSIS_RPC_URL
AMB_GNOSIS_ROUTER
AMB_GNOSIS_ROUTER_DEPLOYMENT_BLOCK
ROUTER_SETTLER_PRIVATE_KEY
```

Optional fields: `ROUTER_SETTLER_STATE_PATH` (defaults to a chain and router scoped file
under `.tmp`), `ROUTER_SETTLER_POLL_MS` (2000), `ROUTER_SETTLER_RANGE` (2000 blocks),
`ROUTER_SETTLER_CONFIRMATIONS` (2), `ROUTER_SETTLER_BATCH_SIZE` (25 status checks) and
`ROUTER_SETTLER_BACKOFF_MS` (1000, capped at 5 minutes). These are Gnosis block
confirmations, separate from Ethereum FCR.

Run with environment supplied securely, for example
`node --env-file=.env script/router-settler.mjs` on Node with env-file support.
Use private persistent storage for the checkpoint; `.tmp` is a development
default, not a reliable volume after a deployment/container replacement.
Provision its persistent parent directory before starting the process. The
executor requires that existing directory and directory-fsync support; it
does not create a tree of directories whose durability it cannot establish.

The checkpoint records the scope, scanned block hash/cursor, pending IDs,
backoff, and any signed raw transaction/hash/nonce. It stores no private key or
RPC error text; mode is 0600. Signed transactions can be broadcast by anyone
with the checkpoint, so keep backups private. Writes sync the file, rename it,
then sync its directory before broadcasting. Fixed-category diagnostics report
claim ID, transaction hash/nonce and unresolved submissions without RPC messages
or secrets. Investigate `broadcast_failed`, `submission_unresolved`,
`settlement_reverted`, `prepare_failed` and read-failure categories; nonce stalls
remain operator-action conditions.
Paid/Unknown reconciliation is anchored to the scanned block; a cursor reorg
resets discovery to the deployment block. Work is replayed in bounded ranges.

Before persisting or rebroadcasting a submission, the executor decodes its signed
transaction and validates signer, chain, settlement router, nonce, hash, zero value and exact
`settle(claimId)` calldata. It requires the fixed 700,000 gas limit and transaction
type 0, 1 or 2, rejecting blob and account-authorization transactions. Startup and
iteration validation precede cursor writes and rebroadcast. Invalid stored
transactions or multiple unresolved submissions fail closed without replacing
the checkpoint. Existing version-one checkpoints remain compatible: their signed
pending transaction is checked against the currently configured signer.

These checks do not replace exclusive process/account ownership: the executor
has no interprocess lock or automatic nonce replacement. Fee quotes come from the
configured RPC with no application fee ceiling; use a trusted endpoint and keep
only the intended operational gas budget in the dedicated account.

Corrupt or mismatched state stops startup. Preserve it privately and replay into
a new file after inspecting any in-flight transaction and signer nonce. Do not
delete an unresolved signed transaction merely because an RPC request timed
out. Restart with the original checkpoint to rebroadcast the same hash. If the
transaction is priced too low, nonce serialization stalls later submissions:
review and replace/cancel that nonce using the same account and reconcile it;
this v1 has no automatic fee replacement. Confirmation policy cannot promise
immunity to all deep reorgs.

## Failure runbook

| Symptom | Action and payment rule |
| --- | --- |
| Source bridge limit or AMB submission rejects | Entire source transaction reverts; caller retains tokens/shares; retry source after cause changes |
| Router deprecated | New deposits revert; after council review call `verifyBridgeImplementation()` if the source proxy changed, then `resume()`, or use a reviewed replacement |
| Source implementation changed | New deposits revert automatically; council reviews both chains, calls `deprecate()`, `verifyBridgeImplementation()`, then `resume()` if compatible |
| Source succeeds, Gnosis Unknown | Inspect AMB callback; resend stored claim on Ethereum if needed; no second bridge deposit |
| Pending, WaitingForBridge | Check exact transfer execution and bridge limits; canonical bridge operators handle delivery; no pool advance without marker |
| Pending, WaitingForLiquidity | Replenishment/existing credits unblock settlement; optional sponsor donation needs funding authorization |
| Pending, Ready, adapter reverts | Keep cash and claim; inspect adapter and retry same ID after repair |
| Minimum cannot be met | Recipient may lower minimum; executor cannot change it |
| UnsupportedBridgeConfig | Stop traffic; fee/shift or processed-marker getter failure is a compatibility gate, not an executor error |
| RPC/disk/executor failure | Retain checkpoint, repair infrastructure and restart; other callers can settle safely |
| Duplicate messages or executors | Settlement router accepts identical payloads and pays each ID at most once |
| Canonical above-limit return | Confirm governance chose `unlockOnForeign`, the return arrived at the Ethereum receiver, and whether the Gnosis claim was paid. Safe reviews the original payer and recovery amount before calling `recover()`; no automatic cancellation or payout |

The settlement router needs no sponsor buffer. Optional sponsor cash is a permanent donation
with no withdrawal path. Outstanding claims cannot be canceled. Do not offer
withdrawable LP capital or automatic refunds. Native bridge credit is a consensus
action, so
executor polling is required even without a settlement router receive callback.

## Activation gates and monitoring

- Confirm actual FCR settings/latency for both xDai and **arbitrary message**
  lanes. The official FCR page names xDai/Omnibridge; a fast asset lane with a
  slower AMB lane still delays registration. Do not promise seconds based on an
  RPC safe tag or fork test alone.
- Accept the current zero fee manager/zero shift policy throughout outstanding
  claims. Today's getters cannot prove historic fees or detect a change-and-return
  episode between checks. Monitor governance changes and halt new traffic; the
  v1 assumes the reviewed configuration remains in force.
- Monitor bridge and AMB governance announcements and proxy upgrade events.
  Ethereum bridge implementation changes automatically block new deposits; call
  `deprecate()` before a scheduled upgrade or immediately on any Gnosis bridge/AMB
  change. Verify token/nonce/limits, AMB routing, fee/shift and exact processed
  marker/native-credit behavior. Only the council Safe may acknowledge the
  current Ethereum implementation with `verifyBridgeImplementation()` and call
  `resume()` after documenting compatibility. If incompatible, leave deprecated
  and direct new traffic to a reviewed route. A Gnosis monitor or Safe delay
  leaves an exposure window; no Ethereum contract can read Gnosis upgrades.
- If Gnosis governance returns an above-limit transfer to the receiver, verify
  source deposit, return transaction, token/amount and any destination payout
  before the Safe recovers DAI/USDS to the rightful payer. Pooled liquidity means
  a paid claim may have used another transfer's credit. Escalate that accounting
  case; do not promise a one-click refund.
- Authorize a small staging transfer separately and record source/destination
  hashes, execution marker, native credit block, AMB callback outcome, minted
  shares, delayed executor recovery and restart behavior. Local `vm.deal` is not
  consensus-mint evidence.

Monitor pending age and counts by status, cash versus pending amounts, bridge
limits/configuration, AMB execution failures, executor nonce/gas/checkpoint health
and unsuccessful adapter calls. Alerts and cash balances are never payment
authorization. See the [tested snapshots and gas evidence](AMB_ROUTER_INTEGRATION.md)
and [architecture diagrams](AMB_ROUTER_ARCHITECTURE.md).
The [security and ownership model](AMB_ROUTER_SECURITY.md) states which failures
the application can retry and which require external operators or product
decisions.
