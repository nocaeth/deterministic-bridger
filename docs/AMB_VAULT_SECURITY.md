# Security, trust and ownership

The router and settlement vault have no owner, admin or upgrade mechanism. Their
configuration is immutable. Deployment selects trusted external contracts; it
does not remove those contracts' governance or validator authority. The executor
provides availability and pays gas. It never authorizes a payout.

This document describes the current security model. Read it with the
[architecture and funds flow](AMB_VAULT_ARCHITECTURE.md),
[operations runbook](AMB_VAULT_OPERATIONS.md) and
[observed integration evidence](AMB_VAULT_INTEGRATION.md).

## Authority and responsibilities

| Layer or actor | Authority and responsibility | Boundary and failure impact |
| --- | --- | --- |
| Ethereum payer | Approves USDS or sUSDS, supplies its own assets and chooses recipient and original minimum | Default recipient is the caller; `To` methods intentionally allow another recipient. Successful source submission cannot be canceled here. |
| Gnosis recipient | Receives sDAI and may lower the effective minimum while Pending | Only this address may lower it; the payer has no separate right when the addresses differ. Equal contract-wallet addresses across chains do not prove equal ownership. |
| Source router | Measures caller funding, relays the exact USDS amount to the fixed vault and submits the stored claim atomically | No arbitrary AMB forwarding, user-supplied nonce or recipient override on resend. It cannot rescue unrelated tokens or administer bridge recovery. |
| Settlement vault | Authenticates registration, checks the exact canonical transfer and cash, and converts once for the stored recipient | No admin payout, sweep, cancellation, upgrade or sponsor withdrawal. Paid records remain to prevent replay. |
| Deployer / integration maintainer | Reviews dependencies, chooses reciprocal addresses and bridge implementation pins, verifies deployment and publishes configuration | Constructor checks do not prove a contract is canonical or correct. A wrong pair must be replaced before use; no post-deployment repair authority exists. |
| Canonical token bridge validators | Attest and execute the USDS-to-xDAI transfer | The application trusts the resulting processed marker; it does not verify an Ethereum receipt or validator signatures itself. |
| Token bridge proxy governance | Controls upstream upgrades and bridge policy, including validators, limits and fees | A current implementation/hash mismatch blocks new source relays or destination settlement. Pins do not attest the history of configuration or eliminate governance trust. |
| AMB validators and proxy governance | Deliver messages and authenticate source contract and source chain | The vault trusts AMB callback context. AMB implementation is not pinned by this application; upstream compromise can falsify that context. |
| Ethereum/Gnosis consensus and FCR infrastructure | Establish source confirmation, chain ordering and spendable native credit | Source rollback or failed upstream minting is not repaired by an application cancellation protocol. Fast confirmation adds no proof to the vault. |
| USDS / sUSDS protocol and governance | Maintain token transfers, redemption and asset backing | These assets are external dependencies. Balance checks reject mismatched funding; they cannot protect economic backing or restore unavailable redemption. |
| Savings adapter / sDAI protocol and governance | Convert xDAI, issue the returned shares to the recipient and maintain savings economics | The application fixes the adapter address and trusts its returned share count. It does not measure the recipient's token balance change or pin all upstream savings dependencies. |
| Sponsor | Voluntarily donates xDAI liquidity | Donation creates no shares, claim, withdrawal right or repayment promise. All remaining cash is permanently subject to this vault's settlement rules. |
| Executor operator | Owns the Gnosis gas key, persistent checkpoint, exclusive signer nonce stream and retry infrastructure | Any caller may settle. Key compromise or dishonest RPC fee quotes threaten the gas account and availability; neither grants a payout override. Protect signed checkpoint transactions and backups. |
| Frontend / RPC operator | Presents quotes, discovers state and supplies chain data | These are not payment authorities. Bad quotes or stale RPC data can delay or misrepresent completion; the transaction still follows on-chain gates. |

No party in this table is assigned an undeclared recovery power. Bridge governance
and savings governance refer to those external deployments, not to an owner of
the application vault.

## Conditional payment guarantees

For each claim, successful settlement requires all of the following:

1. Registration comes through the configured home AMB, naming the configured
   Ethereum router and source chain 1. The vault runs on chain 100 and derives
   the deployment-scoped claim ID itself.
2. The exact canonical transfer hash for `(vault, amount, bridgeNonce)` has a
   processed marker. A signature count, another transfer or an above-limit
   record without successful processing is insufficient.
3. The currently inspected home bridge implementation/hash, incoming fee manager
   and decimal shift match the supported configuration, and the vault has at
   least the claim amount in spendable xDAI.
4. Conversion accepts exactly that amount and the trusted adapter reports positive
   shares meeting the current minimum. The vault marks Paid before calling the
   adapter; a revert or insufficient shares rolls back both payment and status.

Under honest configured AMB and canonical bridge behavior, a claim from this
router implies a funded relay in the same Ethereum transaction. Transfer or
redemption, exact token movement, nonce advancement, claim storage and AMB
submission all revert together on source failure. The user still pays source gas.
Resend reads only that stored payload and performs no new asset transfer.

The processed marker binds the **vault, amount and bridge nonce**, not the payer
or final sDAI recipient. Those fields are authenticated by AMB and the router's
stored payload. A compromised AMB could fabricate a recipient for a real
processed transfer. A compromised canonical bridge could fabricate execution.
The application has no independent light client or Ethereum receipt proof that
would defeat either compromise.

Identical messages preserve the original payload, effective minimum and Paid
state. A conflicting payload rejects. Only the designated recipient can lower
the effective minimum, and resends cannot reset it. Repeated settlement cannot
pay an already Paid claim again.

## Assets, ordering and availability

The claim amount is USDS assets at source and the same number of xDAI base units
at destination. sUSDS shares are redeemed first; destination sDAI shares are a
different quantity. This correspondence assumes zero incoming fees and zero
decimal shift throughout outstanding transfers. Today's getter values cannot
prove a historical change-and-return episode.

AMB delivery, canonical execution and native credit are independent. Registration
saves Pending before a bounded optional conversion attempt. Failed child
conversion retains registration; an AMB callback that itself fails before saving
the claim needs source `resendClaim`. A native credit alone creates no claim and
need not invoke `receive`.

Cash can come from canonical credits or sponsor donations. It cannot substitute
for the processed marker. Once that marker exists, sponsor cash may cover the
gap before native credit. Insufficient cash leaves Pending and makes settlement
a no-op; an executor can retry after credit. The pool is fungible, with no
reservation, partial payment or strict FIFO. A large claim can wait while smaller
claims complete. No deadline or maximum completion time is promised.

Pending adapter/minimum failures require a change in their cause before a retry
can succeed. The recipient may accept a lower minimum. There is no deadline-based
refund if the recipient cannot act, the adapter stops working, or upstream
delivery does not recover.

## Upgrades, refunds and fast confirmation

Bridge implementation pins deliberately fail closed on a current mismatch.
A legitimate canonical upgrade can therefore strand Pending claims. The
application cannot authorize a replacement implementation. These checks detect
the currently returned implementation and its code, not malicious historical
proxy changes, altered bridge storage or all upstream dependencies.

Canonical refund/recovery is outside this application's protocol. A refund to
the vault's address on Ethereum may be inaccessible: the Gnosis vault does not
control that Ethereum address. There is no controlled source refund receiver,
authenticated cancellation, or accounting to repay sponsor cash after an already
Paid claim. A timeout cannot safely invent those mechanisms.

[Official FCR documentation](https://docs.gnosischain.com/bridges/fast-confirmation-rule)
describes faster validator processing with synchrony and honest-stake assumptions,
and fallback to finality. A safety failure may still reorg a fast-confirmed block.
The application inherits that upstream risk and cannot reverse a destination
payment. FCR does not enforce AMB/asset ordering or an application delivery SLA.
Selected xDai and arbitrary-message lane configuration remains a live rollout
gate; the documented rollout statements were inconsistent at the tested date.

## Verification limits and deployment decisions

Unit, fuzz and stateful tests exercise application authorization, rollback,
identity, replay, liquidity and failure recovery using controlled dependencies.
Pinned forks exercise the recorded canonical contracts and real savings adapter
at historical blocks. Neither proves validator honesty, economic solvency,
current FCR lane configuration, future governance behavior or live consensus mint
ordering. See [integration evidence](AMB_VAULT_INTEGRATION.md) for observed results
and the exact scope of each check.

Before activating deposits, the integration owner must accept immutable bridge
pins, ongoing zero fee/shift assumptions, permanent sponsor donations and the
absence of application refunds. Live delivery, callback gas, mint ordering and
operator recovery still need a separately authorized staging transfer. Tests and
implementation review are not a production security audit.
