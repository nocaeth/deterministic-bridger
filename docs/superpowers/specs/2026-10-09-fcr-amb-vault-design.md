# FCR, AMB and a shared sDAI settlement vault

Date: 2026-10-09. Status: implemented, with production deployment evidence gates.
Branch: `codex/fcr-amb-vault-plan`.

## Outcome and constraints

Let a payer supply Ethereum USDS or sUSDS in one router transaction, after token
approval, and receive Gnosis sDAI without browser registration or polling to drive
execution. Preserve a distinct payer and recipient. Leave the canonical xDai
bridge and AMB contracts unchanged.

The application consists of an immutable Ethereum router, an immutable Gnosis
vault, authenticated AMB claims and a small fallback executor.

FCR reduces source confirmation latency. It does not make the two bridges atomic,
provide a native-mint callback, guarantee a maximum delivery time, or remove the
canonical bridge's validator/governance trust. One transaction per new deposit is
a user-experience target after approval, not a claim about total validator
transactions. The added AMB path can increase total bridge transactions.

Global implementation constraints:

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

## Why this architecture

The shared vault combines AMB authorization with the canonical execution gate.
Liquidity advances cover only the mint scheduling/credit gap; independent message
and asset delivery still need an executor. Do not pay just because the router's
AMB message has arrived. The shared vault's balance alone is also insufficient to
authorize a claim: it may contain seed liquidity or unrelated deposits.

## Observed evidence and what remains unverified

The router supports USDS and ERC-4626 redemption of sUSDS. Its bridge call uses
USDS. There is no direct canonical sUSDS bridge call: the asset path is
`sUSDS redemption -> USDS relay`.

Public source reviewed on this date supports the following proposed integration:

1. The foreign bridge exposes `nonce()` and emits the previous nonce with a
   successful relay. Its relay checks source limits before pulling tokens.
   [BasicTokenBridge](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/BasicTokenBridge.sol),
   [BasicForeignBridge](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/BasicForeignBridge.sol),
   [ForeignBridgeErcToNative](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/erc20_to_native/ForeignBridgeErcToNative.sol).
2. The home bridge identifies an affirmation by
   `keccak256(abi.encodePacked(recipient, value, nonce))`. A public processed bit
   distinguishes successful execution from mere signature collection.
   [BasicHomeBridge](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/BasicHomeBridge.sol).
3. Successful positive-value execution schedules native minting through
   `addExtraReceiver`. Out-of-limit execution records a separate condition.
   Incoming fees can reduce the amount scheduled.
   [HomeBridgeErcToNative](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/erc20_to_native/HomeBridgeErcToNative.sol).
4. AMB exposes message sender, source chain and message ID during a callback. The
   original AMB message ID is distinct from the canonical token bridge nonce.
   [MessageProcessor](https://github.com/gnosischain/tokenbridge-contracts/blob/master/contracts/upgradeable_contracts/arbitrary_message/MessageProcessor.sol).
5. The documented native mint credits the destination in a subsequent block.
   [xDai bridge documentation](https://docs.gnosischain.com/bridges/About%20Token%20Bridges/xdai-bridge).
6. FCR changes validator processing, with fallback to finality. The documentation
   is inconsistent about rollout dates, and does not independently establish
   the processing mode of our particular AMB deployment.
   [FCR documentation](https://docs.gnosischain.com/bridges/fast-confirmation-rule).

These are public-source observations, not verified live-proxy behavior. Before
implementation freezes the integration, record proxy and implementation addresses,
implementation code hashes, source revisions, chain IDs, block numbers, getter
results and AMB lanes in `docs/AMB_VAULT_INTEGRATION.md`. Verify the exact transfer
marker and fee behavior on pinned forks. Optional fork tests that silently return
without RPC configuration do not satisfy this gate.

## The accompaniment guarantee

The guarantee has two parts, under the trust assumptions below.

### Ethereum creates a claim only from a successful funded relay

The router has four narrow user entry points, not a generic message sender. For
sUSDS, the router redeems shares from `msg.sender` into its own USDS balance. It
uses the observed balance increase, verifies that it equals the redeem return
value and rejects zero assets. For USDS, it checks the actual balance increase
from `safeTransferFrom` against the requested amount.

Then, in the same transaction and under a router reentrancy guard:

1. Read the configured foreign bridge's next nonce.
2. Record router and bridge USDS balances.
3. Clear allowance, approve the exact amount and call
   `foreignBridge.relayTokens(gnosisVault, amount)`.
4. Require the nonce advanced by exactly one, the router balance decreased by
   the exact amount, and the bridge balance increased by the exact amount.
5. Clear allowance. Derive a claim ID from the configured deployment domain and
   the captured bridge nonce. Store the immutable claim.
6. Send that stored claim to the configured Gnosis vault through the foreign AMB.
7. Emit the source event only after all checks and message submission succeeded.

The exact balance assertions are valid only for the supported relay implementation;
a version that internally invests assets during relay needs a reviewed replacement
assertion, not removal of funding checks. Existing unrelated router balances must
not increase a payer's claim.

No step catches and suppresses a funding, relay, nonce or AMB submission failure.
If any step fails, EVM transaction rollback removes the redemption/transfer,
bridge request, stored claim and AMB request together. The user still pays gas.
Transactions from unrelated parties cannot interleave inside this transaction.

`resendClaim(claimId)` reads a claim previously stored by this successful path. It
accepts no new amount, recipient, minimum or nonce. Resending does not redeem or
bridge again. A new AMB message ID never creates a new entitlement.

### Gnosis accepts only that router and that canonical transfer

`registerClaim` requires the configured home AMB as `msg.sender`, the immutable
Ethereum router as `messageSender()`, source chain ID `1`, and destination chain
ID `100`. Payload addresses cannot override configured router/bridge/vault
addresses. It rejects zero payer, zero recipient and zero amount.

The vault recomputes the claim ID. It stores the first authenticated payload;
identical duplicates are successful no-ops, and conflicting duplicates revert.
The original payload stays immutable even if the recipient later lowers the
settlement minimum. Paid records remain permanently to prevent replay.

Before any payout, the vault computes the canonical home bridge transfer hash:

```solidity
bytes32 transferHash = keccak256(
    abi.encodePacked(address(this), claim.amount, claim.bridgeNonce)
);
bool executed = homeBridge.isAlreadyProcessed(
    homeBridge.numAffirmationsSigned(transferHash)
);
```

This is the proposed expression to verify against the live implementation. A
signature count reaching a threshold, an `AmountLimitExceeded` condition, a raw
balance increase or an AMB callback alone must not substitute for `executed`.

The conjunction establishes: the authorized router bound this payer/recipient to
its actual funded relay, and the canonical home bridge successfully executed that
specific transfer to this vault. A stranger sending the same payload through AMB
has a different AMB source sender and cannot register it. A local settlement caller
supplies only the claim ID and cannot redirect its payout.

This is not a trustless Ethereum receipt proof. It relies on correct immutable
router code, canonical bridge/AMB validation, their governance and FCR assumptions.
A compromised validator quorum or changed bridge implementation can invalidate
those assumptions. AMB does not independently inspect the sUSDS redemption.

## Protocol data and interfaces

Use `src/libraries/VaultClaimLib.sol` for the shared payload and ID expression.

```solidity
struct Claim {
    bytes32 bridgeNonce;
    address payer;
    address recipient;
    uint256 amount;       // USDS actually relayed, in 18-decimal asset units
    uint256 minShares;    // original minimum sDAI shares
}
```

The claim ID is `keccak256(abi.encode(domain, uint256(1), uint256(100), router,
foreignBridge, homeBridge, vault, bridgeNonce))`, where
`domain = keccak256("SDAI_AMB_VAULT_V1")`. The payload is not user-supplied message
calldata; each public bridge function constructs it internally.

New Ethereum contract: `MainnetAmbBridgeRouter`.

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

Caller-default variants set recipient to `msg.sender`; `To` variants allow the
payer to specify a separate recipient. Use these exact ABIs for the application
deployment.

New Gnosis contract: `SavingsXDaiSettlementVault`.

```solidity
registerClaim(VaultClaimLib.Claim calldata claim) returns (bytes32 claimId);
settle(bytes32 claimId) returns (SettlementResult result, uint256 shares);
getClaim(bytes32 claimId) view returns (
    VaultClaimLib.Claim memory original,
    ClaimStatus status,
    uint256 minimumShares
);
settlementStatus(bytes32 claimId) view returns (SettlementResult);
lowerMinShares(bytes32 claimId, uint256 newMinimum);
receive() external payable;
```

`ClaimStatus = Unknown, Pending, Paid`. `SettlementResult = Unknown, Paid,
WaitingForBridge, WaitingForLiquidity, UnsupportedBridgeConfig, Ready`. Adapter
and slippage errors are reverted/caught attempt outcomes, not persisted claim
states. The stored effective `minimumShares` starts at the original minimum.

Events: source `ClaimBridged` includes indexed ID/payer/recipient, bridge nonce,
amount, original minimum and initial AMB message ID; `ClaimMessageSent` records
each submission. Destination `ClaimRegistered` includes the full immutable
payload; `ClaimPaid` includes ID, recipient, assets and shares;
`MinimumSharesLowered` includes ID and new minimum; `SettlementAttemptFailed`
includes ID when an optional isolated attempt reverts. Persisted events and getters
are sufficient to rebuild an executor's work list without an on-chain array.

Pin event signatures for frontend/executor ABI integration:

```solidity
event ClaimBridged(
    bytes32 indexed claimId, address indexed payer, address indexed recipient,
    bytes32 bridgeNonce, uint256 amount, uint256 minShares, bytes32 ambMessageId
);
event ClaimMessageSent(bytes32 indexed claimId, bytes32 indexed ambMessageId);
event ClaimRegistered(
    bytes32 indexed claimId, address indexed payer, address indexed recipient,
    bytes32 bridgeNonce, uint256 amount, uint256 minShares
);
event ClaimPaid(
    bytes32 indexed claimId, address indexed recipient, uint256 amount, uint256 shares
);
event MinimumSharesLowered(bytes32 indexed claimId, uint256 minimumShares);
event SettlementAttemptFailed(bytes32 indexed claimId);
```

## Recording, payment and gas isolation

Registration writes the claim and event before attempting payment. It makes a
bounded external self-call to `settle` and catches a failed attempt. Do not call
the adapter inline in the registration scope: adapter rollback must not erase a
valid registered claim.

Initial gas constants to measure and freeze before deployment: AMB callback budget
`700_000`, optional settlement child budget `350_000`, registration return reserve
`100_000`. Skip the optional attempt unless remaining gas covers the child,
EIP-150 overhead and return reserve. Catch without copying arbitrary revert data.
These are starting budgets, not measured estimates. Verify the AMB allows the
callback budget and verify the real adapter fits the child budget.

Registration is not protected by the same active lock as its self-called settlement.
Settlement has its own reentrancy guard; registration rejects entry while settlement
is active. The source router has a separate guard. This prevents adapter callbacks
from altering claim state and avoids a nested guard preventing every self-call.

`settle` does the following in one transaction:

1. Return `Unknown` for an unregistered ID and `Paid` for a completed ID.
2. Check supported bridge configuration, then the exact processed marker. If not
   executed, return `WaitingForBridge` without spending anything.
3. If the vault cannot cover the whole claim, return `WaitingForLiquidity`.
4. Set status to Paid before the external adapter call, while guarded.
5. Deposit exactly this claim's amount, not the vault's full balance, into the
   immutable adapter for the stored recipient.
6. Require positive shares and `shares >= minimumShares`; emit `ClaimPaid`.

Adapter failure or minimum failure rolls back the status, adapter operation and
value transfer together. The outer registration or an executor observes the failed
attempt; the earlier pending record remains. A batch executor isolates transactions
per claim initially, so one failed claim cannot roll back another payout.

Only the stored recipient can lower an unpaid claim's minimum, only downward.
They cannot change payout ownership or amount. This handles a minimum that has
become unattainable after a prolonged delay. Original payload comparison still
uses the immutable original minimum, so a resend cannot reset the new minimum.

There is no claim expiry, partial payout or automatic xDAI payout in v1.

## Ordering and failure matrix

| Condition | Durable state | Completion path |
| --- | --- | --- |
| Ethereum redemption, funding, relay or AMB submission reverts | No claim and no bridge request | User retries a new transaction after correcting the cause |
| AMB delivered before canonical home execution | Pending / WaitingForBridge | Executor checks later; no advance yet |
| Home execution blocked by daily or per-transfer limit | Pending / WaitingForBridge | Canonical bridge reprocessing or recovery; vault cannot override it |
| Home execution complete, mint not credited, enough seed available | Paid | Later mint replenishes cash; no second payout |
| Home execution complete, insufficient cash | Pending / WaitingForLiquidity | Executor retries after actual credit or sponsor top-up |
| Funds credited before AMB delivery | No claim yet; cash present | Authenticated registration can settle immediately |
| Adapter reverts, returns zero or violates minimum | Pending | Retry adapter later, or recipient lowers minimum |
| Registration callback itself fails, including out of gas | No destination claim | Resend stored source claim through a new AMB message |
| AMB delivery is merely slow | Source claim exists | Wait; a resend is safe but does not bypass a halted AMB |
| Duplicate original or resent message | Same Pending/Paid record | No new entitlement or duplicate payment |
| Bridge configuration/implementation outside supported policy | Pending / UnsupportedBridgeConfig | Stop automatic settlement; reviewed migration/recovery |
| FCR slows or falls back | Existing states unchanged | Continue waiting; do not assume a 12-second deadline |
| Source chain reorg violates fast confirmation assumptions | Bridge-level risk | Incident response; this application cannot reverse issued sDAI |

## Liquidity and fee policy

The seed is operator-sponsored native xDAI. V1 has no LP shares, lending, pricing,
seed withdrawal or owner sweep. Native `receive()` only accepts funds; it does not
create claims or attempt to infer a payer. This avoids withdrawing capital that
backs delayed claims or deposits whose AMB message has not arrived.

Record this implementation limit in one code comment:
`shortcut: sponsor liquidity has no withdrawal path; design liabilities and delayed exits before accepting withdrawable LP capital`.

Under a supported zero-incoming-fee deployment, let D be unique registered claim
assets, P successful payout assets, and M actual canonical mint credits. Cash is
seed plus M plus donations minus P. Pending assets are D minus P. These describe
accounting, not an assertion that every source deposit has already been registered
or that all scheduled minting has been credited. Payments never exceed cash.

Seed size affects how often an optional attempt succeeds; it does not determine
whether a claim is valid. Waiting is the default when cash is insufficient. There
is no promise of strict FIFO under limited liquidity; the executor prioritizes
older ready claims and avoids starvation operationally. This needs no on-chain
queue or partial-payment bookkeeping.

Zero incoming fee and zero decimal shift are production gates for this first
version. The processed marker proves execution, not the net amount delivered.
Record and monitor the live fee policy and supported implementation. Runtime
guards check the expected implementation and the verified no-fee configuration;
a mismatch returns UnsupportedBridgeConfig before payout. Current fee getters
cannot prove historical fee settings if governance changed them and changed them
back. Consequently the v1 backing argument explicitly assumes the supported
no-fee policy remains in effect throughout outstanding transfers. Monitoring is
not a cryptographic substitute for that assumption.

If live evidence cannot establish the required fee semantics, or the product
requires protection from historical fee changes, do not ship this gross-amount
advance design. Review a design that authenticates each transfer's actual net
mint amount; do not infer net value from today's fee rate or an aggregate balance.
This is a specific go/no-go gate, not an unspecified implementation task.

An immutable implementation pin also stops settlement after a legitimate canonical
bridge upgrade, even if funds have arrived. This v1 has no mechanism to approve a
replacement implementation or export an outstanding claim. Do not describe a
reviewed migration as an already implemented recovery path. If eventual payout
across canonical upgrades is required, the immutable-pin version is a no-go until
a narrowly authorized compatibility/recovery mechanism is designed and reviewed.

## Executor and frontend

Add a separate `script/vault-settler.mjs`, using installed ethers. Read only the
new Gnosis vault's ClaimRegistered/ClaimPaid events to discover normal work; source
scan is unnecessary for registered claims. Persist an atomic JSON checkpoint with
cursor block/hash, pending IDs, retry time and any submitted transaction hash.
Scan in bounded ranges with block-hash verification and replay from a known vault
deployment block if the checkpoint cannot be validated. Rebuild after restart;
never start at latest and silently skip old claims. Claim getters remain the
authority when events or a checkpoint disagree.

The executor checks settlementStatus, calls only settle(ID) for ready claims and
serializes transaction nonces. Confirm submitted receipts before discarding work;
reconcile receipts and nonce state before resubmitting after a timeout. Paid calls
remain safe no-ops even if two independent executors submit them. Use capped
backoff on adapter/RPC failures and keep permanent errors visible. Watch balance
changes/bridge events as hints, not payment authorization. Fund the executor's gas
from a separate low-balance wallet; no fee is taken from a recipient's claim in v1.

For a claim missing on Gnosis, the frontend displays source registration pending.
It can read the source stored claim and AMB delivery status and expose a manual
`resendClaim` after a failed callback. Do not continuously resend every slow
message. A resend changes only delivery, never entitlement.

Frontend states: SourcePending, AwaitingMessage, WaitingForBridge,
WaitingForLiquidity, ConversionRetry, UnsupportedBridgeConfig, Paid. A completed
receipt plus ClaimPaid/getter evidence establishes success. Preserve transaction
hashes and IDs across reloads. Label awaiting canonical delivery as delayed, not
lost. Show a manual permissionless settle action and recipient-only minimum
adjustment. Explain that smart-contract wallets may have different identities or
control on the two chains; equality of address strings alone is not a control
proof. Browser observation never drives or authorizes normal execution.

## Recovery and deployment

Do not refund based on timeout. The bridge can deliver later, while a vault claim
could already have paid. Canonical above-limit recovery is a separate privileged
bridge procedure. Because the canonical destination is the shared vault, an
Ethereum-side recovery may name that same address on Ethereum, not the original
payer. Do not assume there is a controlled contract at that address or that the
source router can recover those tokens.

Before production, either prove the selected operational recovery preserves
delivery to the Gnosis vault, or design and review control of the Ethereum recovery
destination and authenticated cancellation/repayment. This design includes no
automatic refund promise. If reversible bridge recovery is a product requirement,
the branch must not be deployed until that additional protocol is specified and
tested. Persistent canonical non-delivery remains a bridge-level custody risk.

The router and vault reference each other immutably. Resolve deployment without
introducing a generic factory: predict the dedicated Ethereum deployer's next
CREATE address, deploy the Gnosis vault bound to that expected router, then deploy
the router bound to the actual vault. Verify the actual router address matches,
and verify all reciprocal configuration before funding or frontend activation.
Nonce drift requires a corrected deployment; never fix it with an arbitrary
initializer or mutable trust anchor.

Deploy and verify the router and vault. Activate traffic only after the
integration gates, measured gas budgets, ordering checks, executor restart checks,
security review and explicit production authorization.

## Required validation

Local tests cover successful USDS/sUSDS routing, zero/invalid inputs, caller vs
recipient, actual redemption balance deltas, exact relay balance deltas, nonce
capture, source transaction rollback, stored-payload resends, authenticated AMB
context, conflicting/identical duplicates, canonical marker matching, both arrival
orders, cash exhaustion, positive/minimum shares, recipient-only minimum lowering,
reentrancy, optional-call gas exhaustion and replay after Paid.

Stateful invariants cover at-most-once payment, immutable identity/amount, no payment
without authenticated registration and canonical execution, aggregate paid amount
equal to successful adapter deposits, and no negative/overdrawn cash. Mock bridge
execution and actual balance credit are separate operations; direct vm.deal does
not stand in for proving real consensus mint behavior.

Pinned fork checks verify getters and relay event nonce against the exact proxies,
USDS/sUSDS compatibility, AMB source context, processed-marker semantics, bridge
limits and supported fees. A controlled staging transfer separately checks real
native mint ordering and absence of recipient callback. Local mocks and ordinary
EVM forks cannot alone establish consensus-native mint behavior.

Executor tests cover restart/reorg reconstruction, stale state, duplicate events,
paid claims, isolated adapter errors, lost receipts and serialized submissions.
Measure callback gas with the real adapter, then run the full vault protocol and
executor suites. Before any builds/forks/bulk replay,
read `~/.codex/policies/memory.md` and apply its resource limits.

## Acceptance criteria

- A public caller cannot create a payable claim merely by sending AMB calldata or
  topping up the vault; the source must be the configured router's funded relay.
- Matching the amount without matching vault and canonical nonce is insufficient.
- An AMB registration can survive a failed conversion attempt.
- Exhausted liquidity defers claims without deleting, redirecting or duplicating
  them. A restarted executor can find and finish every registered pending claim.
- Paid status is permanent, including after repeated AMB delivery and local retries.
- The happy path needs no application registration webhook or browser-triggered
  processing; exceptional paths and bridge trust limits are documented accurately.
- Unsupported live fees, proxy behavior or recovery requirements stop production
  rollout rather than being hidden by a successful mock test.
