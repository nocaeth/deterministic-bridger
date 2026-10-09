# AMB settlement router integration evidence

Read-only observations on 2026-10-09; no transaction was broadcast. The new router
and settlement router are undeployed. RPC credentials are excluded from this document.
The pinned fork evidence is historical; the current snapshot below separately
checks proxy configuration. Neither snapshot establishes validator processing. The
[security model](AMB_ROUTER_SECURITY.md) identifies the assumptions tests cannot
establish.

| Field | Ethereum | Gnosis |
| --- | --- | --- |
| Chain ID | 1 | 100 |
| Snapshot block | 26154748 | 48668463 |
| Canonical xDai bridge | `0x4aa42145Aa6Ebf72e164C9bBC74fbD3788045016` | `0x7301CFA0e1756B71869E93d4e4Dca5c7d0eb0AA6` |
| Implementation | `0x257bDD093Cab1Bd39eBF837dCB60f33d031d7d49` | `0xe6998b0C03D3cb9ee8C04f266e573c7Fa8782846` |
| Implementation code hash | `0x264cadfbd942c81527ab9bd8494c60509fb89f95cd8dd1ebc0fec72fd64809cb` | `0xfa047c93c784231e57196bf818ec20b303dd1e9a65e4452507361858f7784ab5` |
| AMB | `0x4C36d2919e407f0Cc2Ee3c993ccF8ac26d9CE64e` | `0x75Df5AF045d91108662D8080fD1FEFAd6aA0bb59` |
| AMB implementation | `0x098f51bdfb5D6d319DD4FDf06b64773d25bD1316` | `0xA033535983d1aBcc2648af730EDCb198909903D7` |
| AMB source/destination IDs | 1 / 100 | 100 / 1 |
| AMB maxGasPerTx | 4000000 | 2000000 |

Ethereum block hash: `0x08cd7016182cab2e17f0cc210c7b8abafe50ffb072ef6e9d3907068f5e67975d`.
Gnosis block hash: `0x45f3da7785910ae76189f6f6ffc843432af8275e7ed13e97061d43ed6caa109c`.

The Ethereum bridge's nonce was 7222. Its token getter and sUSDS's asset getter
both returned USDS `0xdC035D45d973E3EC169d2276DDab16f1e407384F`. The Gnosis bridge's
feeManagerContract was zero and decimalShift was zero. The configured savings
adapter `0xD499b51fcFc66bd31248ef4b28d656d67E591A94` had 5331 bytes of runtime code.

### Current address check on 2026-10-09

At Ethereum block **26,155,898** (`0x398c3c59f165c17a04ebe9db6a6372e159e220efb682e67431b596a425d71d07`)
and Gnosis block **48,670,986** (`0x499cc431c2a4d2d3ec90f22cfba821a7ffcec89e384c8d02e2005aaee10cc56c`),
read-only RPC checks found the following. The [Gnosis xDai contract list](https://docs.gnosischain.com/bridges/About%20Token%20Bridges/xdai-bridge),
[Gnosis AMB contract list](https://docs.gnosischain.com/bridges/About%20Token%20Bridges/amb-bridge)
and [Sky mainnet address registry](https://github.com/sky-ecosystem/spells-mainnet/blob/master/src/test/addresses_mainnet.sol)
independently list the bridge, AMB, savings adapter, sDAI, USDS and sUSDS addresses
used here.

| Check | Observed |
| --- | --- |
| Ethereum/Gnosis chain IDs | `1` / `100` |
| Bridge implementations and runtime code hashes | Both matched the historical observations above; the current router gates new deposits on the reviewed Ethereum implementation address, with council re-acknowledgement available. Runtime hashes are not enforced |
| AMB implementations | Both matched the historical addresses above; routes remained `1→100` and `100→1` |
| AMB maximum gas | Ethereum `4,000,000`; Gnosis `2,000,000`, both above the hardcoded `700,000` claim callback limit |
| Ethereum asset wiring | Bridge `erc20token()` = USDS; sUSDS `asset()` = USDS; both tokens report 18 decimals |
| Gnosis bridge policy | `feeManagerContract()` = zero; `decimalShift()` = zero |
| Gnosis adapter and sDAI | Both contain code and have unchanged runtime hashes since the pinned block; adapter hash `0x057b591e42158b9026124f0ebcd98458e794d2b855efbedc99d986b2ef5b1be0`; sDAI reports 18 decimals |
| Historical fork anchors | Ethereum block `26,154,748` and Gnosis block `48,668,463` still have the recorded hashes shown above |

The `350,000` isolated settlement gas limit and `100,000` parent reserve are
application budgets, not chain parameters. The pinned fork measured 358,712 gas
for the whole ready callback and 87,625 for the real adapter deposit; these
measurements support the current budgets but cannot guarantee future live gas
behavior. Deployer nonces, predicted application addresses, fee caps and the
reviewed plan hash must be computed for the actual deployment; they are not
canonical hardcoded addresses.

An observed AffirmationCompleted at Gnosis block 48668348 carried destination
`0x455F7c393a7cA1e05E402B06892527383688E7DE`, amount 5e18 and nonce 0x1c35. The
required-RPC fork suite checks this exact destination/amount/nonce hash through
numAffirmationsSigned and isAlreadyProcessed, instead of assuming a signature
threshold is successful execution.

Run the separate required-RPC suite with
`FOUNDRY_PROFILE=amb_router_fork forge test -vv`; both RPC variables must exist.
They must serve historical state at the pinned blocks; the RPC endpoints configured
for this current check returned the correct chain IDs but did not serve that state.
It exercises a USDS relay and real savings adapter entirely in local forks.
Initial implementation required-RPC result: **4 passed, 0 failed** at the pinned blocks. The real adapter
deposit used **87,625 gas** (5 xDAI to a fresh recipient). Peak runner RSS was
496,168 KiB. This verifies ordinary EVM contract behavior, not consensus-native
mint timing. Paired deployment scripts were dry-run with a fixed test key and
reject a changed Ethereum deployer nonce; no transaction was broadcast.

Initial implementation callback measurements using the real savings adapter and
bridge configuration, a mock AMB wrapper and a simulated execution marker:

| Path | Observed gas, including mock AMB wrapper |
| --- | ---: |
| Fresh ready registration and conversion | 380,713 |
| Duplicate Paid registration | 68,466 |
| Registration with failed destination minimum | 311,434 |

The 700k callback and 350k isolated child completed the real conversion in the
fork. Local gas-exhaustion tests also preserve Pending registration. These are
setup-sensitive fork measurements, not live AMB or native consensus-mint
measurements. Keep staging gas headroom as a production gate. Final fork peak RSS
was 513,464 KiB including compilation. Configured non-archive endpoints became unavailable for new reads
at the pinned blocks; final checks used public Ethereum dRPC and the official
Gnosis RPC instead, with the same snapshot and the then-present code-hash assertions.

Primary source and deployment documentation:

- [Canonical bridge architecture](https://docs.gnosischain.com/bridges/About%20Token%20Bridges/xdai-bridge).
- [Token bridge nonce and limits](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/BasicTokenBridge.sol).
- [Foreign relay nonce](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/BasicForeignBridge.sol).
- [Home processed marker](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/BasicHomeBridge.sol).
- [Mint scheduling and incoming fees](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/erc20_to_native/HomeBridgeErcToNative.sol).
- [AMB message sender and source chain](https://github.com/gnosischain/tokenbridge-contracts/blob/master/contracts/upgradeable_contracts/arbitrary_message/MessageProcessor.sol).
- [FCR integration](https://docs.gnosischain.com/bridges/fast-confirmation-rule).

The source branch names are explanatory references; runtime hashes above are
historical observations, not application pins. The current router remembers the
reviewed Ethereum bridge implementation address as a change detector, and the
council can acknowledge a compatible upgrade. Recheck behavior after any proxy
upgrade. Bridge governance and validators remain part of application trust.

## Gates that RPC getters do not establish

- Validator FCR processing mode for the selected xDai and AMB lanes is unverified.
  Node safe tags alone do not establish validator configuration or a delivery SLA.
  The official page read on 2026-10-09 describes FCR processing but its FAQ still
  targets production rollout at the end of October 2026 and names xDai/Omnibridge.
  It does not establish the selected arbitrary-message lane's live configuration.
- Actual consensus reward mint ordering and absence of a recipient callback need
  a separately authorized staging transfer; vm.deal does not prove either.
- Historical or future fee configuration is not proven by today's zero fee getter.
- An Ethereum bridge implementation change automatically blocks new router
  deposits until council review and acknowledgement. Gnosis bridge and AMB
  upgrades do not trigger this on-chain gate; monitor and deprecate before
  continuing traffic. Existing claims can still be affected by any upgrade.
- A same-address Ethereum receiver can hold canonical bridge returns of DAI or USDS.
  The Safe must verify the bridge outcome and original payer before a manual return;
  there is no timeout refund or automatic claim cancellation.
- The settlement router requires no sponsored seed. Optional sponsor funding has no withdrawal
  path and is an irreversible donation requiring explicit authorization.

Production activation remains gated on these product/trust decisions and a review
of the implemented contracts, executor and observed gas budgets.

## Local verification and review

This branch verifies only the AMB settlement router protocol: source/settlement router unit checks,
claim identity and a stateful conservation/at-most-once model. The pinned fork
suite separately checks canonical bridge behavior, real adapter conversion,
callback budgets and paired deployment dry-runs. Executor tests cover
signed-before-broadcast restart, RPC ambiguity, confirmed nonce/receipt handling,
event replay, disk errors and file/directory sync ordering.

Current test responsibilities:

| Suite | Behavior checked |
| --- | --- |
| Router unit and fuzz tests | Caller funding isolated from prior balances, sUSDS asset/redemption, allowances, all recipient variants, complete source rollback and immutable resend |
| Settlement router unit and fuzz tests | AMB caller/sender/chain authentication, exact execution hash, independent liquidity gate, recipient-only minimum lowering, replay and conversion rollback, gas exhaustion and reentry |
| Claim-library tests | Deployment-scoped identity and separation when the router, bridges, settlement router or nonce changes |
| Safe-token tests | Contract target and optional ERC-20 return validation, including empty, false and malformed return data |
| Stateful invariant handler | Independently modeled immutable claims, per-recipient shares, source custody/nonces and native credits minus payouts under changing order, duplicate/conflicting messages, invalid authority and temporary dependency failures |
| Executor Node tests | Signed transaction validation, durable-before-broadcast ordering, restart/rebroadcast, nonce recovery, reorg replay, disk/RPC errors and sanitized failure reports |
| Required-RPC forks | Historical canonical nonce/event and processed-marker behavior, real savings conversion, callback budget and reciprocal deployment dry-runs |

The default Foundry profile requests 1,024 cases per fuzz test and 256 invariant
runs of 500 actions, with unexpected handler reverts treated as failures. Expected
rejections are checked by the handler and unit tests. This separates application
state assertions from the independent accounting model; it is not evidence about
real validator honesty or future governance. Observed run results are recorded
separately below.

Run `forge test`, `npm run test:router-settler`, `npm run check:executor`,
`forge build` and `forge fmt --check` locally. The separate fork command above
requires archival access to both documented chain snapshots.

Standalone-branch baseline verification on 2026-10-09 (`b449228`, before the
subsequent hardening changes):

| Check | Observed result |
| --- | --- |
| `forge build --force` | Passed; stale artifacts cleared |
| `FOUNDRY_PROFILE=amb_router_fork forge build` | Passed; fork fixtures compile independently |
| `forge test` | 36 passed, 0 failed; stateful model 256 runs × 500 actions |
| `npm run test:router-settler` | 18 passed, 0 failed |
| `npm run check:executor`, `forge fmt --check`, `git diff --check` | Passed |

Those results describe branch isolation only. The fresh hardening results below
supersede its local test counts and repeat the pinned fork execution.

The initial implementation review found no Critical contract issue and identified
checkpoint-directory durability, stalled-transaction diagnostics, a minimum event
ABI mismatch and missing reentry/replay cases. These were corrected with
regression checks. The real above-limit path is supported by linked bridge source
and local gate tests; it is **not** specifically exercised in the pinned fork.
This is an implementation review, not a production security audit.

## Hardening verification on 2026-10-09

Verified the hardened working tree against baseline `b449228` with Solidity
0.8.35, the Cancun target and 200 optimizer runs:

| Check | Observed result |
| --- | --- |
| `forge build --force --sizes` | Passed; router runtime 6,115 bytes, settlement router runtime 4,872 bytes |
| `forge test -vv` | 63 passed, 0 failed; 11 fuzz properties × 1,024 cases; invariant 256 runs × 500 actions, 128,000 calls and zero unexpected handler reverts |
| Required-RPC historical forks | 4 passed, 0 failed before removal of the implementation pin; deployment dry-runs only |
| Executor tests and syntax | 34 Node checks passed, including invalid signed transactions and accepted types 0, 1 and 2; syntax passed |
| `forge fmt --check`, `git diff --check` | Passed |
| Focused mutation checks | All four disabled safety gates were caught by existing tests in an isolated copy |

The mutation checks removed source-chain authentication, the canonical processed
gate, minimum-share enforcement, and the shared reentrancy rejection separately.
Each variant compiled and failed its corresponding behavior test. This is a
focused regression check, not an exhaustive mutation score or formal proof.

Fresh reviewers inspected Solidity security, keeper durability and validation,
and testing/documentation. The stale guard import and missing positive type-1
transaction case they identified were corrected. Slither 0.11.6 analyzed 14
contracts with 102 detectors and reported 13 findings; review found none
actionable within the documented trust model:

| Detector findings | Disposition |
| --- | --- |
| 8 `reentrancy-balance` and 1 `reentrancy-benign` | Source entrypoints share the guard; balance/nonce snapshots deliberately enforce relay postconditions before storing a claim. Callback and rollback tests exercise these boundaries. |
| 2 `incorrect-equality` | Zero assets and zero AMB message IDs are invalid sentinel values, both intentionally rejected. |
| 1 `unused-return` | Optional settlement return values are unnecessary for durable registration; failed child calls preserve Pending state. |
| 1 `reentrancy-events` | The parent emits the failure event after a failed guarded child; that event grants no payment authority. |

The findings were reviewed rather than suppressed in source. Static analysis and
review do not establish the honesty of configured external dependencies.

### Gas observations

The fork callback uses real bridge configuration and savings conversion, a mock
AMB wrapper, and a simulated processed marker in both versions:

| Callback path | Initial implementation | Hardened implementation |
| --- | ---: | ---: |
| Fresh ready registration and conversion | 380,713 | 358,712 |
| Duplicate Paid registration | 68,466 | 68,591 |
| Registration with failed minimum | 311,434 | 291,540 |

The real adapter deposit remained 87,625 gas. A separate local comparison used
the same 35 baseline unit tests and identical mocks for both source versions,
including an asset getter needed by the new constructor check. Average measured
call gas changed from 289,990 to 280,195 for `bridgeSavingsUSDSTo`, 65,702 to
59,164 for `resendClaim`, and 114,812 to 108,566 for `settle`. These averages mix
successful, rejected and waiting paths; they are not transaction fee quotes or
blanket savings promises. The shared nonzero guard avoids repeated zero-to-nonzero
storage writes while preserving the callback budget.

Heavy commands ran serially; the largest observed peak RSS was 669,832 KiB.
Live validator delivery, FCR lane configuration, consensus-native mint ordering
and the real above-limit recovery path remain outside these checks. No transaction
was broadcast and no application contract or sponsor funding was deployed.

## Current follow-up verification on 2026-10-09

The Gnosis application is now named `GnosisAmbSettlementRouter`. It can hold
pooled xDAI temporarily while claims wait, but it issues no deposit shares and
requires no sponsor buffer. The claim domain and fixed identity test vector were
updated with that name. The older tables above record the original implementation
and earlier hardening snapshots.

- The renamed executor and paired deployer passed 38 Node tests. Both JavaScript
  entrypoints passed syntax checks.
- `forge coverage --threads 1` passed all 75 current tests, including 256
  stateful invariant runs with 128,000 calls and no unexpected handler reverts.
  Every production `src/` contract reached 100% line, statement, branch and
  function coverage. Aggregate line coverage was 88.57% because the report
  also includes test helpers, mocks and simulation scripts.
- The four pinned Ethereum/Gnosis fork tests passed with public historical RPC
  access after the configured endpoints could not serve the pinned state. They
  cover a real adapter deposit, the registered-claim callback with a mock AMB,
  relay behavior, and paired simulation-script address checks. No transaction
  was broadcast on either live chain.
- A paired deployment dry-run against the current live RPCs with dedicated
  deployer accounts remains outstanding. Historical forks cannot establish
  current validator delivery, native-credit ordering or refund behavior.
