# Security, trust and ownership

The router and settlement settlement router have no upgrade or withdrawal mechanism. The
router's immutable bridge council Safe can deprecate or resume new deposits, but
cannot alter claims, block resends or control settlement router settlement. It also controls
the separate Ethereum return receiver. Deployment selects trusted external contracts; it
does not remove those contracts' governance or validator authority. The executor
provides availability and pays gas. It never authorizes a payout.

This document describes the current security model. Read it with the
[architecture and funds flow](AMB_ROUTER_ARCHITECTURE.md),
[operations runbook](AMB_ROUTER_OPERATIONS.md) and
[observed integration evidence](AMB_ROUTER_INTEGRATION.md).

## Authority and responsibilities

| Layer or actor | Authority and responsibility | Boundary and failure impact |
| --- | --- | --- |
| Ethereum payer | Approves USDS or sUSDS, supplies its own assets and chooses recipient and original minimum | Default recipient is the caller; `To` methods intentionally allow another recipient. Successful source submission cannot be canceled here. |
| Gnosis recipient | Receives sDAI and may lower the effective minimum while Pending | Only this address may lower it; the payer has no separate right when the addresses differ. Equal contract-wallet addresses across chains do not prove equal ownership. |
| Source router | Measures caller funding, relays the exact USDS amount to the fixed settlement router and submits the stored claim atomically | No arbitrary AMB forwarding, user-supplied nonce or recipient override on resend. It cannot rescue unrelated tokens or administer bridge recovery. |
| Bridge council Safe | Can deprecate/resume new deposits, acknowledge a reviewed Ethereum bridge implementation, and manually transfer returned DAI/USDS from the Ethereum receiver | Cannot alter existing claims or block resends. Compromise can misdirect recovered funds or approve an incompatible implementation; losing it prevents reopening deposits and recovery. |
| Settlement settlement router | Authenticates registration, checks the exact canonical transfer and cash, and converts once for the stored recipient | No admin payout, sweep, cancellation, upgrade or sponsor withdrawal. Paid records remain to prevent replay. |
| Deployer / integration maintainer | Reviews dependencies, chooses reciprocal addresses, verifies deployment and publishes configuration | Constructor checks do not prove a contract is canonical or correct. A wrong pair must be replaced before use; no post-deployment repair authority exists. |
| Canonical token bridge validators | Attest and execute the USDS-to-xDAI transfer | The application trusts the resulting processed marker; it does not verify an Ethereum receipt or validator signatures itself. |
| Token bridge proxy governance | Controls upstream upgrades and bridge policy, including validators, limits and fees | An Ethereum implementation change blocks new deposits until council acknowledgement. Gnosis upgrades and policy changes still need off-chain monitoring; existing claims may be affected. |
| AMB validators and proxy governance | Deliver messages and authenticate source contract and source chain | The settlement router trusts AMB callback context. AMB implementation is not pinned by this application; upstream compromise can falsify that context. |
| Ethereum/Gnosis consensus and FCR infrastructure | Establish source confirmation, chain ordering and spendable native credit | Source rollback or failed upstream minting is not repaired by an application cancellation protocol. Fast confirmation adds no proof to the settlement router. |
| USDS / sUSDS protocol and governance | Maintain token transfers, redemption and asset backing | These assets are external dependencies. Balance checks reject mismatched funding; they cannot protect economic backing or restore unavailable redemption. |
| Savings adapter / sDAI protocol and governance | Convert xDAI, issue the returned shares to the recipient and maintain savings economics | The application fixes the adapter address and trusts its returned share count. It does not measure the recipient's token balance change or pin all upstream savings dependencies. |
| Sponsor | May optionally donate xDAI liquidity; no buffer is required | Donation creates no shares, claim, withdrawal right or repayment promise. All remaining cash is permanently subject to this settlement router's settlement rules. |
| Executor operator | Owns the Gnosis gas key, persistent checkpoint, exclusive signer nonce stream and retry infrastructure | Any caller may settle. Key compromise or dishonest RPC fee quotes threaten the gas account and availability; neither grants a payout override. Protect signed checkpoint transactions and backups. |
| Frontend / RPC operator | Presents quotes, discovers state and supplies chain data | These are not payment authorities. Bad quotes or stale RPC data can delay or misrepresent completion; the transaction still follows on-chain gates. |

No party in this table is assigned an undeclared recovery power. Bridge governance
and savings governance refer to those external deployments, not to an owner of
the application settlement router.

## Conditional payment guarantees

For each claim, successful settlement requires all of the following:

1. Registration comes through the configured home AMB, naming the configured
   Ethereum router and source chain 1. The settlement router runs on chain 100 and derives
   the deployment-scoped claim ID itself.
2. The exact canonical transfer hash for `(settlement router, amount, bridgeNonce)` has a
   processed marker. A signature count, another transfer or an above-limit
   record without successful processing is insufficient.
3. The current incoming fee manager and decimal shift match the supported
   configuration, and the settlement router has at
   least the claim amount in spendable xDAI.
4. Conversion accepts exactly that amount and the trusted adapter reports positive
   shares meeting the current minimum. The settlement router marks Paid before calling the
   adapter; a revert or insufficient shares rolls back both payment and status.

Under honest configured AMB and canonical bridge behavior, a claim from this
router implies a funded relay in the same Ethereum transaction. Transfer or
redemption, exact token movement, nonce advancement, claim storage and AMB
submission all revert together on source failure. The user still pays source gas.
Resend reads only that stored payload and performs no new asset transfer.

The processed marker binds the **settlement router, amount and bridge nonce**, not the payer
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

The router compares the Ethereum bridge proxy's current implementation address
with a council-approved address on every new deposit; it does not pin code hashes.
The council can acknowledge a compatible new implementation and resume. Gnosis
bridge and AMB upgrades need monitoring and manual deprecation. Existing claims
can continue settling, but the application cannot prove compatibility from the
checked getters alone. A change to nonce behavior, processed-marker meaning,
fees or actual credited amount may
block settlement or violate the funding assumption. Monitor upgrades and deprecate
the router for review. Resume after compatibility is verified. Existing claims
still need recovery or settlement.

Canonical refund/recovery is a manual Safe action outside claim settlement. The
Ethereum return receiver is deployed at the Gnosis settlement router's numeric address. It
lets the immutable Safe authority transfer returned DAI/USDS after checking the
original payer, return transaction and any Gnosis payout. There is no authenticated
cancellation or automated accounting for an already Paid claim, which may have
used pooled liquidity. A timeout cannot safely invent those mechanisms.
One concrete route is a transfer above Gnosis execution limits: the
[home bridge records it](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/erc20_to_native/HomeBridgeErcToNative.sol),
and [governance can choose to unlock it on Ethereum](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/HomeOverdrawManagement.sol)
to the original destination address. Here that address is the Gnosis settlement router and
matching Ethereum receiver. Validator delay or failed AMB registration
does not by itself trigger this refund path.
At the 2026-10-09 live snapshot, Ethereum's outgoing and Gnosis's incoming
per-transfer caps both equal 9,999,999 USDS; their daily caps are 10,000,000
and 15,000,000 USDS respectively. Under unchanged limits and same-day delivery,
the source bridge rejects an amount that would exceed the destination cap.
Delayed transfers from two Ethereum days can execute in one Gnosis day and
exceed its daily cap; governance can also change either limit independently.

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
ordering. See [integration evidence](AMB_ROUTER_INTEGRATION.md) for observed results
and the exact scope of each check.

Before activating deposits, the integration owner must secure the Safe, verify
initial compatibility and explicitly resume the router. The owner must accept
bridge upgrade trust, ongoing zero fee/shift assumptions, manual return custody
and any optional permanent sponsor donations. Live delivery, callback gas, mint
ordering and
operator recovery still need a separately authorized staging transfer. Tests and
implementation review are not a production security audit.
