# AMB vault deployment and operations

Implementation and fork verification do not authorize production deployment,
seed funding or changing traffic. The new route has **no deployed address**.
The old route's deployment scripts and automation keep their existing meaning.

## Reciprocal deployment

1. Choose a dedicated Ethereum deployer, record its next CREATE nonce and compute
   the next contract address with `cast compute-address <deployer> --nonce <nonce>`.
   Do not use this account for another transaction during deployment. Set
   `EXPECTED_MAINNET_DEPLOYER_NONCE` and `EXPECTED_MAINNET_AMB_ROUTER` from these
   actual values.
2. On Gnosis configure the canonical home/foreign bridges, reviewed home AMB,
   adapter and expected source router. Dry-run
   `forge script script/DeployAmbVault.s.sol:DeployAmbVault --rpc-url "$GNOSIS_RPC_URL"`.
   After separate deployment authorization, deploy the vault and record its
   actual address, creation transaction and block. Set `AMB_VAULT` and
   `AMB_VAULT_DEPLOYMENT_BLOCK` to that actual deployment.
3. Dry-run
   `forge script script/DeployAmbRouter.s.sol:DeployAmbRouter --rpc-url "$MAINNET_RPC_URL"`.
   The script rejects a changed deployer nonce or wrong predicted router address.
   After authorization, deploy the router. If any nonce/configuration is wrong,
   redeploy a correctly bound pair before activation; there is no initializer.
4. Independently verify reciprocal addresses on each chain: router.gnosisVault,
   router.homeBridge, router.foreignBridge, router.foreignAMB, vault.sourceRouter,
   vault.foreignBridge, vault.homeBridge, vault.homeAMB and vault.adapter. Verify
   both implementation addresses/code hashes, chain IDs, local token and adapter
   code, zero home fee manager/shift and source AMB gas maximum >=700000. Verify
   bytecode/constructor arguments through Sourcify and publish the resulting ABIs.
   Do this before funding or routing user deposits.

The scripts require a deployment key via `PRIVATE_KEY`. Test dry-runs use a fixed
test key in a local fork, not a real account. Never record production keys or RPC
credentials in artifacts. Broadcast/funding commands are intentionally absent
from the activation checklist until approval.

## Executor setup

Use a **separate Gnosis gas account** and only one process per signer and state
file. Independent executors may use separate accounts/files; at-most-once payout
is enforced by the vault. Do not concurrently run another bot or manually submit
transactions from the executor account while its nonce is outstanding.

Required environment:

```text
GNOSIS_RPC_URL
AMB_VAULT
AMB_VAULT_DEPLOYMENT_BLOCK
VAULT_SETTLER_PRIVATE_KEY
```

Optional fields: `VAULT_SETTLER_STATE_PATH` (defaults to a chain/vault-scoped file
under `.tmp`), `VAULT_SETTLER_POLL_MS` (2000), `VAULT_SETTLER_RANGE` (2000 blocks),
`VAULT_SETTLER_CONFIRMATIONS` (2), `VAULT_SETTLER_BATCH_SIZE` (25 status checks) and
`VAULT_SETTLER_BACKOFF_MS` (1000, capped at 5 minutes). These are Gnosis block
confirmations, separate from Ethereum FCR.

Run with environment supplied securely, for example
`node --env-file=.env script/vault-settler.mjs` on Node with env-file support.
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
| Source succeeds, Gnosis Unknown | Inspect AMB callback; resend stored claim on Ethereum if needed; no second bridge deposit |
| Pending, WaitingForBridge | Check exact transfer execution and bridge limits; canonical bridge operators handle delivery; no pool advance without marker |
| Pending, WaitingForLiquidity | Replenishment/existing credits unblock settlement; optional sponsor donation needs funding authorization |
| Pending, Ready, adapter reverts | Keep cash and claim; inspect adapter and retry same ID after repair |
| Minimum cannot be met | Recipient may lower minimum; executor cannot change it |
| UnsupportedBridgeConfig | Stop traffic; implementation/fee/shift change is a compatibility gate, not an executor error |
| RPC/disk/executor failure | Retain checkpoint, repair infrastructure and restart; other callers can settle safely |
| Duplicate messages or executors | Vault accepts identical payloads and pays each ID at most once |
| Canonical non-delivery/refund | Escalate canonical recovery; no timeout refund, cancellation, or Ethereum refund contract in this v1 |

Sponsor cash is a permanent donation with no withdrawal path. Outstanding claims
cannot be canceled. Do not offer withdrawable LP capital, automatic refunds or
recovery promises. If those are product requirements, extend and review the
protocol before deployment. Native bridge credit is a consensus action, so
executor polling is required even without a vault receive callback.

## Activation gates and monitoring

- Confirm actual FCR settings/latency for both xDai and **arbitrary message**
  lanes. The official FCR page names xDai/Omnibridge; a fast asset lane with a
  slower AMB lane still delays registration. Do not promise seconds based on an
  RPC safe tag or fork test alone.
- Accept the current zero fee manager/zero shift policy throughout outstanding
  claims. Today's getters cannot prove historic fees or detect a change-and-return
  episode between checks. Monitor governance changes and halt new traffic; the
  v1 assumes the reviewed configuration remains in force.
- Accept immutable bridge implementation pins: legitimate canonical upgrades can
  strand Pending claims. If uninterrupted payout across upgrades is required,
  design/review an explicit compatibility or recovery mechanism first.
- Resolve destination delivery versus canonical Ethereum refund handling. Shared
  vault refunds to the same Ethereum address are not handled here. If refunds
  are required, design authenticated cancellation and repayment accounting first.
- Authorize a small staging transfer separately and record source/destination
  hashes, execution marker, native credit block, AMB callback outcome, minted
  shares, delayed executor recovery and restart behavior. Local `vm.deal` is not
  consensus-mint evidence.

Monitor pending age and counts by status, cash versus pending amounts, bridge
limits/configuration, AMB execution failures, executor nonce/gas/checkpoint health
and unsuccessful adapter calls. Alerts and cash balances are never payment
authorization. See the [tested snapshots and gas evidence](AMB_VAULT_INTEGRATION.md)
and [architecture diagrams](AMB_VAULT_ARCHITECTURE.md).
