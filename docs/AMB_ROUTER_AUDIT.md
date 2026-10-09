# AMB settlement router branch review — 2026-10-09

## Scope and result

Reviewed the branch against `main`: source router, Gnosis settlement router, claim identity,
token wrapper, executor, deployment, tests and operating assumptions. No
confirmed direct unauthorized-payout or double-payout path was found under the
documented bridge, AMB and adapter trust model. This is an implementation review,
not a claim about validator honesty or future upstream upgrades.

## Remediation after this review

- The Ethereum router now starts deprecated. On each new deposit it compares the
  bridge proxy implementation with the council-approved address. A change blocks
  new deposits until the bridge council Safe reviews it, calls
  `deprecate()`/`verifyBridgeImplementation()`, and then `resume()`. This is
  reversible and uses no bridge code hash. Gnosis bridge, AMB and policy changes
  still need off-chain monitoring and a council deprecation action; changes to
  behavior behind an unchanged implementation address are not detected.
- A DAI/USDS return receiver is now paired with the Gnosis settlement router at the same
  numeric address. The paired deployer requires matching router deployer nonces
  across chains, creates the Ethereum receiver first and checks its Safe authority.
  Return payments require Safe review of the payer, source deposit, return and
  any Gnosis settlement. The receiver is custody, not automatic cancellation.
- No sponsor buffer is required. The settlement router settles from fungible bridge credits;
  optional sponsor cash remains an irreversible donation. A focused test covers
  payment from another processed transfer's existing credit.
- The older Foundry scripts are simulation-only; the paired Node deployer remains
  the reviewed broadcast route. None of these changes broadcasts a transaction.

Follow-up verification: `forge test --threads 1` passed 75 tests, including 256
invariant runs with 128,000 calls and zero unexpected reverts. `forge coverage
--threads 1` passed the same 75 tests. Production `src/` contracts reached 100%
line, statement, branch and function coverage; aggregate line coverage was
88.57% because it also includes test helpers, mocks and simulation scripts.
All 38 paired-deployer and executor Node tests, both `node --check` commands,
`forge fmt --check` and `git diff --check` passed. All four pinned historical
fork tests passed using public archive-capable RPC endpoints after the configured
RPC endpoints lacked historical state. The fork suite includes the paired
simulation-script address check; it sent no live transaction. A paired deployment
dry-run against current live RPCs with dedicated deployer accounts remains
unverified. The test counts below describe the original audit snapshot and do
not substitute for that remaining check before production review.

## Original findings and deployment decisions (before follow-up)

### High dependency risk — an upstream bridge upgrade can change transfer semantics

- Evidence: the router checks the bridge token and relay postconditions; the settlement router
  checks the current fee/shift configuration and exact processed marker.
- At the audit snapshot: neither contract checked the bridge implementation or
  code hash. A compatible
  upgrade can serve existing claims, but an incompatible upgrade is not automatically
  rejected if its checked getters retain the same values.
- Fails when: governance changes nonce, relay, processed-marker, fee or native-credit
  behavior beyond those checks while claims remain outstanding.
- Blast radius: pending claims, new source deposits and sponsor liquidity.
- Decision at the audit snapshot: monitor bridge governance, use the router's
  deprecation switch if compatibility breaks, and rerun live compatibility checks.
  Recovery from incompatible historical transfers
  needs a separately reviewed protocol design.

### High conditional loss risk — canonical refund handling is absent

- Evidence: the router's `_relayAndSendClaim` and `resendClaim` only relay or
  resend; the security model records the missing recovery authority.
- At the audit snapshot: the application had no authenticated cancellation,
  source-chain token recovery or accounting for claims already paid from
  sponsor liquidity.
- Fails when: the canonical bridge returns a transfer to an application address
  rather than completing delivery. The exact live refund route was not exercised
  in the historical fork tests.
- Blast radius: affected deposit funds, with a second accounting problem if the
  claim was already paid from the buffer.
- Decision: confirm the canonical refund route and define recovery and
  cancellation rules before promising refunds or routing substantial deposits.

### Medium economic assumption — current zero-fee getters do not prove transfer history

- Evidence: `src/GnosisAmbSettlementRouter.sol:76-79,159-176,191-199`.
- At the audit snapshot: the settlement router checks current fee manager and decimal shift, then authorizes
  the gross claim amount using the processed transfer marker.
- Fails when: bridge governance enables a fee or shift for a transfer and later
  restores the zero settings before settlement; sponsor cash could cover the
  difference. This requires an upstream configuration change, not an ordinary
  unprivileged caller.
- Blast radius: sponsor liquidity and the affected claims.
- Decision: monitor governance and accept this trust assumption, or add a
  transfer-specific net-credit proof in a separately reviewed protocol version.

### Medium operational risk — executor fee quotes have no ceiling

- Evidence: `script/router-settler.mjs:202-210` signs the RPC fee quote; the
  settlement call has a fixed 700,000 gas limit.
- At the audit snapshot: the executor validates destination, calldata, nonce and signer, but a
  compromised or badly configured RPC can suggest an excessive fee for the
  dedicated gas account.
- Fails when: an unreasonable quote is signed and mined.
- Blast radius: that account's gas balance; payout authorization remains in the
  Gnosis settlement router.
- Decision: fund only the operational gas budget, use a trusted RPC and add an
  operator fee ceiling if the executor must tolerate untrusted fee data.

## Verification performed

- At the original snapshot, after removing bridge implementation pins and adding permanent router deprecation,
  `forge coverage --threads 1`: 70 tests passed. Production `src/` contracts
  reached 100% line, statement, branch and function coverage. The aggregate
  Foundry report is 87.80% lines because it also includes test helpers, mocks
  and the single-chain Foundry scripts, which run in the separate fork profile.
- Before removing implementation pins, `FOUNDRY_PROFILE=amb_router_fork forge test --threads 1 -vv`: four historical
  fork tests passed at the pinned Ethereum and Gnosis blocks. The real adapter
  deposit used 87,625 gas; the ready callback with a mock AMB used 358,712 gas.
- Executor: 34 Node tests passed. Paired deployment script: four Node safety
  tests passed, including nonce conflict, review hash, cost ceiling and balance.
  Node's test coverage report measured 85.53% lines for the executor and 30.84%
  for the paired deployer; its two-chain path was instead exercised by the local
  fork deployment below. The Node scripts do not have 100% instrumented coverage.
- Before removing implementation pins, paired script: dry-run, both local-fork deployments and reciprocal getter
  verification passed using disposable Anvil forks and public test keys. A stale
  review hash then rejected a second broadcast without changing either nonce.
  These were local fork transactions; neither application contract was deployed
  on a live chain.
- Slither 0.11.5 analyzed 14 contracts with 101 detectors and returned 17
  detector hits. The high reentrancy hits concern router calls behind its shared
  entrypoint guard; targeted reentry tests exercise those paths. The remaining
  equality, unused-return, low-level-call and event-order hits did not establish
  an additional exploitable path in this review.

## Remaining live gates

Confirm the selected asset and AMB lanes' actual validator delivery behavior,
native credit ordering, upstream configuration stability and refund handling with
an authorized small staging transfer before funding the settlement router or directing users
to it. Coverage and historical forks cannot prove those live conditions.
