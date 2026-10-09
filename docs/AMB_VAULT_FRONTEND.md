# Frontend integration for the AMB vault route

This repository contains contracts and the executor, not a frontend application.
Use the `MainnetAmbBridgeRouter` and `SavingsXDaiSettlementVault` ABIs in `out/`
after `forge build`. Configure verified deployments as a reciprocal pair.

## Ethereum wallet interaction

| Input | Call | Approval |
| --- | --- | --- |
| USDS to caller | `bridge(amount, minShares)` | USDS allowance to source router |
| USDS to chosen recipient | `bridgeTo(recipient, amount, minShares)` | USDS allowance to source router |
| sUSDS to caller | `bridgeSavingsUSDS(shares, minShares)` | sUSDS share allowance to source router |
| sUSDS to chosen recipient | `bridgeSavingsUSDSTo(recipient, shares, minShares)` | sUSDS share allowance to source router |

Amounts and shares use 18 decimal base units. `minShares` is minimum **destination
sDAI shares**, not xDAI assets. Zero disables a price floor but the vault still
requires positive shares. Quote conservatively using current adapter/savings
pricing and disclose price movement while in flight. There is no deadline or
automatic cancellation. A minimum that cannot be met leaves Pending work until
the designated Gnosis recipient lowers it or prices recover.

All methods return `(bytes32 claimId, uint256 assets)` in simulation. Extract the
actual `ClaimBridged` from the mined Ethereum receipt, emitted by the verified
router. Its fields are indexed `claimId`, `payer`, `recipient`, followed by
`bridgeNonce`, `amount`, `minShares`, `ambMessageId`. Actual redeemed assets can
differ from the frontend's quote. Persist source chain/router, vault, claim ID,
transaction hash and payload for reload recovery. A frontend event is a display
hint; it does not authorize Gnosis payment.

The default calls bind recipient to the Ethereum caller. `To` calls deliberately
allow another recipient. Cross-chain contract-wallet ownership must be checked
by the user; the same address may have different contract ownership on Gnosis.

## Destination display states

Call `getClaim(id)` for `(original, status, minimumShares)` and
`settlementStatus(id)` on Gnosis. The original Claim fields are bridgeNonce,
payer, recipient, amount and minShares. `status` is Unknown=0, Pending=1, Paid=2.

| SettlementResult | Value | Suggested display/action |
| --- | --- | --- |
| Unknown | 0 | Waiting for claim registration; inspect AMB delivery before recovery |
| Paid | 1 | Completed; obtain actual shares from `ClaimPaid` |
| WaitingForBridge | 2 | Canonical destination transfer not executed yet |
| WaitingForLiquidity | 3 | Bridge executed; waiting for spendable vault xDAI |
| UnsupportedBridgeConfig | 4 | Protocol compatibility blocked; operator review required |
| Ready | 5 | Ready for executor; adapter/minimum can still prevent conversion |

`Ready` is a precondition view, not a guarantee that the external adapter will
succeed. For persistent Ready claims inspect `SettlementAttemptFailed` and local
settlement receipts. Adapter errors revert a local attempt, while optional
registration attempts catch failures and keep the claim.

Display original and effective minimum separately. Only the recorded recipient
can call `lowerMinShares(id, newMinimum)` on Gnosis while Pending, with
`newMinimum <= currentMinimum`. It emits `MinimumSharesLowered(id, minimumShares)`.
Do not imply that this refunds or changes the
bridge transfer. Resending the original Claim preserves the lowered minimum.

Any Gnosis wallet can call `settle(id)` for a registered claim. It cannot choose
the recipient or amount. Unknown, Paid, waiting and unsupported statuses are
no-ops. Successful conversion emits `ClaimPaid(id, recipient, amount, shares)`.
Unsuccessful conversion reverts that local transaction; reattempt the same ID
after the cause changes. The executor normally handles this without a wallet
transaction.

## Exceptional message recovery

Check AMB execution status and the source router's `getClaim(id)` when a mined
source deposit stays Unknown on Gnosis. `resendClaim(id)` on Ethereum submits a
new AMB message carrying that stored payload. It never transfers assets again.
Its `ClaimMessageSent(id, ambMessageId)` event identifies the new delivery.

Original and resent messages can race. Identical destination registrations
remain one entitlement; conflicting payloads reject and Paid claims stay Paid.
Do not ask users to submit a second bridge transaction to repair a callback.
Delayed canonical transfers, exhausted bridge limits and native credits are
independent of AMB recovery.

On reload, re-read the vault instead of treating a cached transaction receipt or
webhook as completion. Allow confirmation/reorg handling for both chains. Show
the [operations limits](AMB_VAULT_OPERATIONS.md), especially no timeout refund,
no sponsor withdrawal and settlement freeze after incompatible bridge upgrades.
