# FCR AMB settlement vault implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking. Implementation is now authorized. Production broadcast, funding and traffic changes remain unapproved.

**Goal:** Bridge caller-funded Ethereum USDS or redeemed sUSDS into a shared Gnosis
vault and issue sDAI through authenticated, durable, at-most-once claims.

**Architecture:** The Ethereum router atomically funds a canonical USDS relay and
submits its stored claim through AMB. The Gnosis vault records that claim, checks
the exact canonical transfer's processed marker and attempts conversion in an
isolated call. A durable Gnosis executor completes delayed claims.

**Tech Stack:** Solidity 0.8.35, Foundry, existing minimal interfaces/SafeERC20,
Node.js and installed ethers 6. No new dependency.

**Spec:** [FCR AMB vault design](../specs/2026-10-09-fcr-amb-vault-design.md).

## Global constraints

- Solidity `^0.8.35`; Foundry `solc_version = "0.8.35"`; EVM target `cancun`.
- Use the existing `SafeERC20`, asset constants, adapter interface, Foundry and
  installed ethers 6 dependency. Add no package dependency.
- No arbitrary AMB forwarding, caller-supplied bridge nonce, payout override,
  delegatecall, upgrade mechanism, admin sweep or timeout refund.
- A claim can release value only after its authenticated source transaction and
  matching canonical Gnosis bridge execution have been established.
- Neither expected delivery time nor a frontend/RPC assertion authorizes payment.
- No production broadcast, buffer funding or switch of frontend routing is
  authorized by this planning document.

Read `~/.codex/policies/memory.md` before builds, fork tests, gas measurement or
bulk event replay. Apply its budgets to every execution step. Preserve unrelated
edits; commit only the files assigned to a completed task. Do not print private
keys, RPC URLs with credentials, or secret environment contents.

## Review focus

1. A source claim accidentally includes pre-existing router USDS rather than
   this payer's funding: delta-based assertions belong to Task 2.
2. A new AMB message ID, different claim fields or a resend after minimum lowering
   creates a second entitlement: identity and duplicate tests belong to Task 3.
3. A signature threshold or above-limit record is confused with actual bridge
   execution, including nonzero fees: bridge-gate tests belong to Tasks 1 and 3.
4. A gas-consuming adapter erases registration or reenters another claim:
   isolated-call and guard tests belong to Task 3, then gas checks in Task 6.
5. The executor loses pending work after a checkpoint error, reorg, lost receipt
   or RPC timeout: durable reconstruction tests belong to Task 5.

## Files and responsibility

| Files | Responsibility |
| --- | --- |
| `docs/AMB_VAULT_INTEGRATION.md` | Pin live deployment evidence and explicit go/no-go decisions |
| `src/interfaces/IAMB.sol` | Message submission and authenticated callback context |
| `src/interfaces/INonceXDaiBridge.sol` | Extend IXDaiBridge with nonce, token and implementation getters |
| `src/interfaces/IHomeXDaiBridge.sol` | Processed marker and supported configuration getters |
| `src/libraries/VaultClaimLib.sol` | Shared Claim type, domain and ID derivation |
| `src/MainnetAmbBridgeRouter.sol` | Caller funding, atomic relay/claim and immutable-payload resend |
| `src/SavingsXDaiSettlementVault.sol` | Durable claims, canonical gate, payment and recipient minimum |
| `test/mocks/MockAMB.sol`, `MockNonceXDaiBridge.sol`, `MockHomeXDaiBridge.sol` | Separate message, relay and execution fixtures |
| `test/mocks/MockVaultAdapter.sol` | Shares, revert, gas and reentrancy behavior |
| `test/VaultClaimLib.t.sol`, `test/AmbVaultFixture.sol` | Standalone protocol checks and later combined fixture |
| `test/MainnetAmbBridgeRouter.t.sol`, `SavingsXDaiSettlementVault.t.sol` | Router/vault checks |
| `test/AmbVaultInvariant.t.sol`, `test-fork/AmbVaultFork.t.sol` | State invariants and required-RPC integration checks |
| `script/vault-settler.mjs`, `script/test/vault-settler.test.mjs` | Executor and bounded recovery tests |
| `script/DeployAmbVault.s.sol`, `DeployAmbRouter.s.sol` | New deployment sequence and reciprocal configuration |
| `docs/AMB_VAULT_FRONTEND.md`, `docs/AMB_VAULT_OPERATIONS.md` | New ABI/status/operations documentation |
| `.env.example`, `package.json`, `README.md` | Names of new configuration, a new test command and route links |

This branch contains the AMB vault protocol, executor, fixtures, deployment
scripts and documentation only.

## Task 1: Pin bridge semantics and define the shared protocol

**Files:** Create integration evidence, the three new interfaces, VaultClaimLib,
MockAMB, MockNonceXDaiBridge, MockHomeXDaiBridge, VaultClaimLib tests and
AmbVaultFork tests. Create the combined AmbVaultFixture in Task 3, after both
application contracts exist.

**Consumes:** Existing IXDaiBridge, IERC20, IERC4626, ChainConstants, MockERC20,
MockERC4626 and the public sources linked in the spec.

**Produces:**

```solidity
interface IAMB {
    function requireToPassMessage(address target, bytes calldata data, uint256 gasLimit)
        external returns (bytes32);
    function messageSender() external view returns (address);
    function messageSourceChainId() external view returns (uint256);
    function messageId() external view returns (bytes32);
    function maxGasPerTx() external view returns (uint256);
}
interface INonceXDaiBridge is IXDaiBridge {
    function nonce() external view returns (uint256);
    function erc20token() external view returns (address);
    function implementation() external view returns (address);
}
interface IHomeXDaiBridge {
    function numAffirmationsSigned(bytes32 transferHash) external view returns (uint256);
    function isAlreadyProcessed(uint256 count) external pure returns (bool);
    function implementation() external view returns (address);
    function feeManagerContract() external view returns (address);
    function decimalShift() external view returns (int256);
}
```

Declare a small `IAMBClaimReceiver` beside IAMB in `IAMB.sol`, importing the
shared Claim type and exposing only
`registerClaim(VaultClaimLib.Claim calldata) external returns (bytes32)`.
The router encodes this interface rather than importing the concrete vault,
so its implementation/test task does not depend on a future application contract.

VaultClaimLib defines the spec's Claim struct and
`id(address router, address foreignBridge, address homeBridge, address vault,
bytes32 bridgeNonce) internal pure returns (bytes32)` with exactly the spec's
domain/chain/address ordering. Do not derive identity from an AMB delivery ID.

- [x] Read the memory policy, then record allowlisted deployment fields at chosen
  Ethereum/Gnosis blocks: token, sUSDS asset, proxy/implementation addresses and
  code hashes, nonce, home processed API, fee manager/shift, adapter, AMB context
  APIs/max gas, source/destination chain IDs and observed lane processing modes.
  Fill integration evidence with actual public values and pinned source revisions.
  Exclude all credentials. If a field cannot be established, mark that production
  gate unverified with its specific required observation.
- [x] Write a required-RPC fork test using `vm.envString` for both URLs. Assert
  canonical token compatibility, getters,
  supported implementation, decimalShift=0 and feeManagerContract=0. This version
  intentionally supports no fee manager; a zero-rate nonzero manager needs a
  separately reviewed policy. Verify source relay logs' actual nonce against the
  getter and actual USDS movement. Record a failing compatibility assertion as a
  no-go result; do not weaken it to make the fork pass.
- [x] Write local tests for claim ID stability and domain changes. Assert changing
  any configured router/bridge/vault address or bridge nonce changes the ID, while
  resending the same claim leaves it unchanged. Define the shared struct/ID and
  mocks only after the targeted test fails for missing types.
- [x] Build mocks with distinct actions: `MockNonceXDaiBridge` pulls tokens,
  increments nonce and can reject relay; `MockHomeXDaiBridge.setProcessed(hash,
  bool)` changes only execution status; an above-limit fixture leaves that status
  false. `MockAMB` records submissions and provides `deliver(target, sourceSender,
  sourceChainId, data)` with temporary message context. Source rejection and
  callback failure are separate switches. These controls exist only in local
  test fixtures.
- [x] Run `forge test --match-contract VaultClaimLibTest` and the explicitly
  configured bridge-getter fork checks. These tests use existing chain contracts
  and protocol types only; they do not import application contracts from later
  tasks. Record
  their commands/block numbers/outcomes. Do not equate fork mint emulation with
  observed consensus minting. Commit the protocol/mocks/evidence once consistent.

Gate: correct public-source selectors alone are insufficient. Confirmed live
semantics are required before Tasks 2-3 are treated as production-compatible.
Unverified FCR lane speed affects the latency claim; incompatible identity,
execution-marker or fee semantics block this protocol version.

## Task 2: Implement atomic caller-funded relay and stored-claim resend

**Files:** Create MainnetAmbBridgeRouter and its test. Reuse existing token helpers.

**Consumes:** Task 1 Claim/ID and foreign bridge/AMB interfaces/mocks.

**Produces:** All six source methods specified in the design. Constructor takes
`INonceXDaiBridge foreignBridge, IAMB foreignAMB, address homeBridge,
address gnosisVault`. Local assets remain hardcoded USDS/sUSDS. Configuration is
immutable; snapshot and check the supported foreign implementation/code hash.

```solidity
bridge(uint256 amount, uint256 minShares) returns (bytes32 claimId, uint256 assets);
bridgeTo(address recipient, uint256 amount, uint256 minShares)
    returns (bytes32 claimId, uint256 assets);
bridgeSavingsUSDS(uint256 shares, uint256 minShares)
    returns (bytes32 claimId, uint256 assets);
bridgeSavingsUSDSTo(address recipient, uint256 shares, uint256 minShares)
    returns (bytes32 claimId, uint256 assets);
resendClaim(bytes32 claimId) returns (bytes32 ambMessageId);
getClaim(bytes32 claimId) view returns (VaultClaimLib.Claim memory);
```

- [x] Build the source-only test fixture with `usds`, `susds`, `foreign`, `amb`,
  `router`, `payer`, `recipient`, a nonzero remote `homeBridge` and a nonzero
  remote `vault` address. Install assets using the current test's etch pattern.
  On simulated Ethereum chain 1, `_bridgeUSDS(amount, minimum)` and
  `_bridgeSavings(shares, minimum)` fund/approve the payer, call the respective
  `To` entry point and return its claim ID. No Gnosis application is needed here.
- [x] Write source tests for both assets and both recipient variants. For sUSDS,
  check the caller's shares burn, observed USDS assets match the claim, bridge
  destination is the configured vault, nonce matches the bridge event and allowance
  finishes at zero. Fund pre-existing router USDS separately and prove it is excluded.
  A representative assertion cycle is:

  ```solidity
  function testSavingsClaimUsesActualCallerRedemption() external {
      susds.setAssetsPerShare(2);
      bytes32 id = _bridgeSavings(4 ether, 0);
      VaultClaimLib.Claim memory c = router.getClaim(id);
      assertEq(c.payer, payer);
      assertEq(c.recipient, recipient);
      assertEq(c.amount, 8 ether);
      assertEq(foreign.lastReceiver(), address(vault));
      assertEq(foreign.lastAmount(), c.amount);
      assertEq(usds.allowance(address(router), address(foreign)), 0);
  }
  ```

- [x] Run `forge test --match-contract MainnetAmbBridgeRouterTest` to establish
  the failing behavior before implementation.
- [x] Implement the source sequence exactly as in the accompaniment guarantee:
  observed funding delta, nonce capture, exact relay balance deltas, nonce +1,
  allowance clearing, immutable claim storage and AMB submission with abi.encodeCall
  of IAMBClaimReceiver.registerClaim. Reject wrong chain/config/token, zero receiver/input/assets,
  insufficient funding and unsupported implementation. Use a simple storage
  reentrancy guard around all source mutations, including resend.
- [x] Add parameterized rollback checks for redemption failure, source limits,
  wrong nonce advancement, incorrect bridge token movement and AMB submission
  failure. Snapshot payer balances/allowance, bridge nonce/balance, router balance,
  source claim and AMB recorded submissions before the call; assert the entire
  snapshot is unchanged after revert. No generic external message method exists.
- [x] Implement resend from stored Claim. Assert unknown ID fails, a valid resend
  submits byte-identical callback calldata, the AMB delivery ID changes, no shares
  are redeemed and neither bridge nonce nor bridge balances change. There is no
  recipient/amount parameter to resend and no account-wide whitelist shortcut.
- [x] Run the targeted suite and fmt check; commit the source router and tests.

## Task 3: Implement authenticated claims and isolated, gated payment

**Files:** Create SavingsXDaiSettlementVault, MockVaultAdapter, AmbVaultFixture
and vault tests.

**Consumes:** Source claim format/ID; immutable source router and foreign bridge;
Task 1 home bridge/AMB interfaces; existing savings adapter interface.

**Produces:** All vault methods/enums/events in the spec. Constructor takes
`IHomeXDaiBridge homeBridge, IAMB homeAMB, ISavingsXDaiAdapter adapter,
address sourceRouter, address foreignBridge`. It validates local contracts and
remote nonzero identities, snapshots the supported home implementation/code hash
and verifies no fee manager/zero shift. It never checks remote code on the wrong
chain. Original Claim and current minimum are stored separately.

```solidity
enum ClaimStatus { Unknown, Pending, Paid }
enum SettlementResult {
    Unknown, Paid, WaitingForBridge, WaitingForLiquidity, UnsupportedBridgeConfig, Ready
}
registerClaim(VaultClaimLib.Claim calldata claim) returns (bytes32 claimId);
settle(bytes32 claimId) returns (SettlementResult result, uint256 shares);
getClaim(bytes32 claimId) view returns (
    VaultClaimLib.Claim memory original, ClaimStatus status, uint256 minimumShares
);
settlementStatus(bytes32 claimId) view returns (SettlementResult);
lowerMinShares(bytes32 claimId, uint256 newMinimum);
receive() external payable;
```

- [x] Create the combined fixture with fields `usds`, `susds`, `foreign`, `home`,
  `amb`, `adapter`, `router`, `vault`, `payer`, `recipient`. Deploy vault on
  simulated chain 100 bound to the predicted next router CREATE address, then
  router on simulated chain 1. Deploy no intervening contract between those
  paired deployments. Each fixture helper sets the appropriate simulated chain.
  Implement `_bridgeUSDS(amount, minimum)` and `_bridgeSavings(shares, minimum)`
  to fund/approve the payer and call the corresponding To variant. `_deliver(id)`
  supplies the stored source Claim through MockAMB. `_execute(id)` sets only the
  exact home processed marker; `_credit(amount)` increases native balance without
  invoking receive. Execution and actual credit must remain separate operations.
- [x] Write registration tests for correct AMB context, each incorrect context
  field, zero payload fields, identical duplicate, conflicting duplicate, duplicate
  after Paid and duplicate after lowering the minimum. Assert native funding alone
  never creates a claim. Run the targeted suite to establish missing behavior.
- [x] Implement registerClaim with source chain/sender/caller validation and ID
  recomputation. Store original Claim, Pending status and effective minimum before
  optional settlement. Identical resends preserve the effective minimum and Paid
  state. Conflicting originals revert without overwriting any field.
- [x] Write ordering/gate checks: ample seed with no marker still waits; signatures
  without processed bit still wait; a marker for another amount/vault/nonce still
  waits; the exact processed marker plus enough cash permits payout. Test these
  three independent axes: authorization, canonical execution and cash.

  ```solidity
  function testCashCannotReplaceCanonicalExecution() external {
      bytes32 id = _bridgeSavings(10 ether, 0);
      _credit(100 ether);
      _deliver(id);
      (, SavingsXDaiSettlementVault.ClaimStatus status,) = vault.getClaim(id);
      assertEq(uint256(status), uint256(SavingsXDaiSettlementVault.ClaimStatus.Pending));
      assertEq(adapter.callCount(), 0);
      _execute(id);
      (SavingsXDaiSettlementVault.SettlementResult result,) = vault.settle(id);
      assertEq(uint256(result), uint256(SavingsXDaiSettlementVault.SettlementResult.Paid));
      assertEq(adapter.lastReceiver(), recipient);
      assertEq(adapter.lastValue(), 10 ether);
  }
  ```

- [x] Implement settlementStatus and settle in the specified order. Unsupported
  implementation/code hash, nonzero fee manager, nonzero shift or failed config
  reads prevent payment. Unknown/Paid/waiting conditions are no-ops. Ready claims
  pay exactly their amount under a settlement reentrancy guard. Set Paid before
  adapter call, then check positive/minimum shares so failure reverts atomically.
- [x] Write tests with claim > available cash, then credit and retry. Test both
  arrival orders, multiple independent claims, repeated callers and repeated Paid
  settlement. Assert a failed adapter deposit and an unattainable minimum preserve
  the pending claim/cash; recipient-only downward minimum adjustment permits a
  later attempt without changing the original resend payload.
- [x] Implement isolated self-call settlement in registerClaim with bounded gas
  and reserved parent gas. Catch without materializing revert bytes and emit
  SettlementAttemptFailed(ID) for a failed optional attempt. Skip optional payment
  if the budget is insufficient. Registration cannot share an active lock with
  its child settle call; prevent entry into registration/minimum mutation while
  settlement is active.
- [x] Use MockVaultAdapter to assert revert, zero shares, low shares, child gas
  exhaustion and reentrant calls leave correct state. Verify registration can
  succeed after child failure; separately simulate insufficient registration gas
  and complete recovery by resending the stored source claim. Claim payout remains
  at most once under repeated deliveries and local retries.
- [x] Add payable receive with no claim/payment side effects. Document the sponsor
  liquidity withdrawal limit using the exact shortcut comment from the design.
  Do not add a sweep, LP withdrawal, generic executor or timeout cancellation.
- [x] Run targeted router/vault tests and fmt check; commit the vault and tests.

## Task 4: Verify the combined protocol's state invariants

**Files:** Create AmbVaultInvariant tests; extend new-route fork tests only.

**Consumes:** The concrete router/vault and fixture from Tasks 1-3.

**Produces:** A bounded stateful harness with separate deposit, message delivery,
canonical execution, actual credit, settlement, resend and minimum-adjustment
actions. Keep a local independent accounting model; do not merely assert values
copied from the contract under test.

- [x] Write an invariant handler that tracks IDs, original recipients/amounts,
  independent successful adapter deposits and pending/paid state. Limit actor and
  claim counts so fuzzing respects the resource policy. Use local mocks only.
- [x] Assert each ID pays at most once; immutable identity/amount never change;
  paid IDs had authenticated registration and exact canonical execution; total
  asset payouts match successful adapter deposits; vault cash is seed/credits/
  donations less payouts. Claim minima may only move downward by the recipient.
- [x] Fuzz duplicate messages, ordering changes, limited credit, adapter failures
  and resends. Run `forge test --match-contract AmbVaultInvariantTest`. Repair
  actual contract/model discrepancies before broadening runs.
- [x] On pinned forks, compare the actual emitted foreign nonce with the captured
  nonce and validate home hash/processed semantics against real implementation
  code. Verify runtime supported-config checks reject simulated proxy/fee changes.
  Explicitly record that changing fee settings back cannot prove historical fees.
- [x] Re-run targeted protocol suites after fixes, then commit invariant/fork tests
  and the evidence update. No test should claim that local EVM funding reproduces
  consensus-native minting.

## Task 5: Add the durable Gnosis completion executor

**Files:** Create vault-settler.mjs and its Node tests; add `test:vault-settler` to
package.json.

**Consumes:** ClaimRegistered/ClaimPaid logs, vault deployment block, getClaim,
settlementStatus and settle. No mainnet log scan is needed for registered claims.

**Produces:** A Node ES module with importable `scanClaims`, `reconcileClaims`,
`settleReadyClaims`, `loadCheckpoint`, `saveCheckpoint` and `runOnce`; the CLI runs
the same functions. Inject provider/vault/signer/clock adapters in tests, using
existing ethers and Node standard APIs rather than another service/framework.

Checkpoint schema: `version=1`, chainId, vault address, deploymentBlock,
cursorBlock/cursorHash, pending entries with ID/nextAttemptAt/attempts and optional
submittedTxHash. It contains no credentials. Scope filenames to chain and vault,
and reject a mismatched checkpoint rather than submitting against another vault.
Write using a temporary file and rename, with mode 0600. CLI fields are
GNOSIS_RPC_URL, AMB_VAULT, AMB_VAULT_DEPLOYMENT_BLOCK, VAULT_SETTLER_PRIVATE_KEY,
VAULT_SETTLER_STATE_PATH; validate poll/range/backoff as bounded positive values.

- [x] Write Node tests for empty start, historic pending claims, duplicate logs,
  paid reconciliation, missing/corrupt/mismatched checkpoints, reorged cursors,
  interrupted write, adapter revert, RPC timeout, lost receipt and restart with
  an already-submitted transaction. Test fixture logs include block/hash/index
  information, and use actual new event ABI encoding.
- [x] Run `node --test script/test/vault-settler.test.mjs` to see missing behavior.
- [x] Implement bounded log scanning from deploymentBlock with stored cursor hash
  validation. On invalid/missing checkpoints replay bounded ranges from deployment
  until caught up, reconstruct pending IDs and reconcile via getters. Write cursor
  and pending updates atomically; failed reads never advance past unprocessed work.
- [x] Implement per-ID status checking and isolated single-claim transactions with
  one serialized signer nonce stream. Poll submitted receipts/nonce state before
  deciding to resend; record a transaction hash as soon as it is returned. Paid
  getter/receipt evidence removes work; timeouts and adapter errors retain it with
  capped backoff. Strip credential-bearing RPC details from persisted errors/logs.
- [x] Add CLI polling with graceful shutdown and runOnce import guard. Native
  balance changes are only wake-up hints. Missing source registrations are handled
  by source resend/manual frontend recovery, not fabricated local claims. Support
  multiple independent executors through the vault's idempotency, not a distributed
  lock. Gas comes from the dedicated executor account.
- [x] Add `"test:vault-settler": "node --test script/test/vault-settler.test.mjs"`;
  run that command and `node --check script/vault-settler.mjs`; commit the executor.

## Task 6: Deployment, integration docs and measured rollout gates

**Files:** New deployment scripts, new frontend/operations docs, allowlisted additions
to .env.example/README, and the integration evidence update.

**Consumes:** New contract ABIs/configuration, verified integration fields and new
executor.

**Produces:** Dry-run deployment/configuration checks, complete frontend field/event
mapping and an operations checklist with explicit production authorization required.

- [x] Write deployment scripts using the existing Foundry Script pattern. The
  Gnosis script reads EXPECTED_MAINNET_AMB_ROUTER and verified local HOME_XDAI_BRIDGE,
  GNOSIS_AMB, SAVINGS_XDAI_ADAPTER. The Ethereum script reads actual AMB_VAULT,
  HOME_XDAI_BRIDGE, ETHEREUM_AMB and canonical foreign bridge. Predict the dedicated
  mainnet deployer's next CREATE address before the Gnosis deployment. If its
  nonce changed, refuse activation/funding and redeploy correctly. Keep both
  directions immutable; use no initializer to repair a mismatch.
- [x] Extend .env.example with the new public/configuration names and blank
  secret placeholders. Keep executor key distinct from deployment key. Document
  Sourcify verification, chain assertions, config getters and ABI availability
  before traffic. Do not invent current deployed addresses for the new contracts.
- [x] Measure callback and real-adapter child gas on the supported configuration,
  exercising fresh/duplicate/paid registration and failed optional conversion.
  Initial budgets are 700000/350000/100000 as specified. Record measurements and
  assert budget headroom plus AMB maxGas compatibility before freezing constants.
  Check the optional call cannot exhaust the parent's completion reserve.
- [x] Document all four source methods, approval requirements, ClaimBridged ID
  extraction, original vs effective minima, AMB context validation, every frontend
  state, reload recovery, manual settle and exceptional stored-claim resend.
  Explain absence of native-mint callback and no browser duty to drive processing.
  There is no frontend application in this repository; deliver the integration
  contract/docs here and do not invent a UI project.
- [x] Document seed as sponsored/non-withdrawable and executor gas as separate;
  do not describe a withdrawable LP pool. Add limits, fees, message delivery,
  implementation changes, reorgs, executor failures and canonical non-delivery to
  the runbook. Monitor pending age/cash, processed markers, callback status and
  config changes without treating an alert as payment authority.
- [ ] Resolve the three production decisions using actual evidence: zero incoming
  fee/shift policy throughout outstanding claims, and canonical recovery preserving
  destination delivery versus a required refund protocol, and acceptance of an
  immutable implementation pin that freezes settlement on canonical upgrades.
  If continued payout across upgrades is required, design/review a narrow
  compatibility or recovery mechanism before deployment. If refund support is
  required, do not deploy this plan: specify controlled Ethereum recovery recipient,
  authenticated cancellation and repayment of an already-paid pool first. No
  timeout or today's fee getter supplies that missing proof.
- [ ] Run dry-run scripts and fork/local ordering checks. A separately authorized
  small staging transfer must observe actual reward mint timing, callback absence,
  message ordering, executor completion and restart recovery. Record source/dest
  block numbers, tx hashes, amounts and resulting shares without exposing keys.
- [x] Run `forge fmt --check`, the full `forge test`, `forge build` and
  `npm run test:vault-settler` within policy budgets. Fork verification must use
  the required-RPC suite; missing RPC configuration is a failed check. Review the whole change for authorization,
  replay, cash/fee accounting and recovery before proposing production activation.
- [x] Commit scripts/docs/config. Present evidence, outstanding gates and a
  concrete deployment/traffic-change proposal for explicit authorization.

## Completion and planning limits

Implementation, unit/stateful tests, required-RPC forks, deployment dry-runs and
setup-sensitive adapter/callback gas measurements are now present. See
[execution evidence](../../AMB_VAULT_INTEGRATION.md) and
[architecture and funds-flow diagrams](../../AMB_VAULT_ARCHITECTURE.md). The two
uncompleted checklist items retain production decisions/staging observations;
dry-run scripts and local/fork ordering checks already passed. Live FCR lanes,
consensus mint timing, and production recovery acceptance remain unverified.

Production readiness requires the listed tests with observed results and
satisfaction of deployment evidence gates. The locally verified implementation is not production activation. A compatible protocol implementation does not itself authorize a
production deployment, irreversible buffer donation or migration of users.
