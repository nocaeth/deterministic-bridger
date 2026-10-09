# How the AMB vault bridge works

A user approves USDS or sUSDS, then makes one Ethereum deposit transaction. The router
redeems sUSDS when needed, sends USDS through the existing xDAI bridge, and submits a
claim to AMB. Both calls happen in that transaction: if either source call fails, the
deposit reverts. Delivery on Gnosis happens later.

On Gnosis, one shared vault receives the claim and is the destination for xDAI. It
converts the claim amount to sDAI for the chosen recipient only after the exact bridge
transfer has executed and the vault has enough xDAI. An executor retries pending claims,
so the user normally makes no Gnosis transaction.

The router and vault are new application contracts and have not been deployed. The xDAI
bridge and AMB contracts are existing infrastructure; this design does not change them.

## Where the funds and claim go

Solid arrows show assets. Dotted arrows show a message or a call.

```mermaid
flowchart TB
  subgraph Ethereum["Ethereum"]
    User["User"]
    Router["Source router"]
    SourceBridge["xDAI bridge"]
    SourceAMB["AMB"]
    User -->|"USDS or sUSDS"| Router
    Router -->|"USDS for the vault"| SourceBridge
    Router -.->|"stored claim"| SourceAMB
  end

  subgraph Gnosis["Gnosis Chain"]
    HomeBridge["xDAI bridge"]
    HomeAMB["AMB"]
    Vault["Shared vault"]
    Adapter["Savings adapter"]
    Recipient["Recipient"]
    HomeBridge -->|"xDAI credit"| Vault
    HomeAMB -.->|"register claim"| Vault
    Vault -->|"claim amount in xDAI"| Adapter
    Adapter -->|"sDAI shares"| Recipient
  end

  SourceBridge -->|"canonical transfer"| HomeBridge
  SourceAMB -.->|"authenticated message"| HomeAMB
```

The two cross-chain paths can arrive in either order. AMB registers a claim; the
canonical bridge establishes whether its exact transfer executed. Native xDAI can reach
the vault later than that execution marker. A sponsor may supply cash for that gap, but
sponsor cash alone never authorizes a payout.

## What authorizes a payout

The vault first stores a valid AMB claim as Pending. It may try to settle immediately.
If that attempt fails, the claim stays Pending and anyone can retry it later.

```mermaid
flowchart TD
  Claim["Authenticated claim stored as Pending"] --> Ready{"Bridge configuration supported?<br/>Exact transfer processed?<br/>Enough xDAI?"}
  Ready -- No --> Wait["Keep Pending; retry later"]
  Ready -- Yes --> Convert{"Savings deposit succeeds<br/>and minimum shares met?"}
  Convert -- No --> Wait
  Convert -- Yes --> Paid["Paid once"]
```

The exact transfer check uses the vault address, claim amount and bridge nonce. A
validator signature count, a transfer to another address, or a large vault balance
cannot replace the processed marker. After it exists, the vault may use sponsor cash
before the bridge's native credit arrives. If cash is short, settlement does nothing
until more arrives. If the adapter fails or returns too few shares, that attempt reverts
without spending the claim's xDAI.

## Why the claim cannot be sent without a source deposit

The Ethereum router creates a new claim only after it:

1. Pulls the caller's USDS, or redeems the caller's approved sUSDS, and checks the USDS
   it actually received. Old router balances cannot count as this deposit.
2. Relays exactly that amount to the fixed vault address and checks the bridge nonce and
   token balance changes.
3. Stores the payer, recipient, amount, minimum shares and nonce, then sends that stored
   claim through AMB.

All three steps happen in one transaction. A source-side bridge limit, failed relay, or
failed AMB submission reverts them together. A later resend sends only the stored
message; it cannot move more funds, change the recipient or invent another bridge nonce.

On Gnosis, the vault accepts registration only from its configured AMB when that AMB
identifies the configured Ethereum router and source chain. The vault derives the claim
ID from the router, both bridges, the vault and bridge nonce. The AMB delivery ID does
not determine the entitlement. Identical messages preserve the original claim, any
lowered minimum and the Paid state; a conflicting message is rejected.

This protection depends on honest configured AMB and bridge infrastructure. The
processed marker binds the vault, amount and nonce, **not** the payer or final sDAI
recipient. AMB authenticates those fields from the router's message. The vault does not
independently verify an Ethereum receipt. It also trusts the configured savings
adapter's report of shares issued. See
[security and ownership](AMB_VAULT_SECURITY.md) for the full trust boundary.

The router records the actual Ethereum caller as payer. Its default methods make that
payer the Gnosis recipient; the “To” methods let the caller choose someone else. Whoever
calls settlement cannot change the recipient or amount. Only the recorded recipient can
lower the pending claim's minimum shares. A contract wallet at the same address on both
chains may have different owners, so users must choose the Gnosis recipient
deliberately.

## When something is delayed

- **The source transaction fails:** The relay and claim both roll back. The user retains
  the tokens or shares and may try again after the cause changes.
- **The source succeeds but Gnosis shows Unknown:** AMB registration may be delayed or
  may have failed. Anyone can call the source router's resendClaim with the stored claim
  ID. This sends another message, not another deposit.
- **The bridge transfer has not executed:** A destination-side limit or bridge delay
  keeps the claim Pending, even if AMB arrived and sponsor cash is available. If the
  transfer never executes, this version has no automatic refund.
- **The claim is Pending:** Check bridge execution, cash, adapter behavior and the
  recipient's minimum. The executor retries the same claim when conditions change. Paid
  claims do nothing on replay.
- **The bridge configuration changes:** Settlement stops if the current implementation,
  fee manager or decimal shift is unsupported. A legitimate upgrade can strand a Pending
  claim until a reviewed recovery path exists.

The vault does not reserve cash per claim, pay partially, or enforce a strict queue. A
smaller ready claim may settle while a larger one waits. Sponsor deposits are permanent
donations: this version has no sponsor withdrawal, cancellation, timeout refund or
application recovery contract. The executor pays its own transaction gas.

## What FCR changes

[Fast Confirmation Rule](https://docs.gnosischain.com/bridges/fast-confirmation-rule)
may shorten the time bridge validators wait for Ethereum confirmation. It
adds no proof to the vault and does not make AMB delivery, bridge execution and native
credit simultaneous. This design advances cash only after the exact transfer's processed
marker exists; it does not pay against an observed Ethereum transaction or a timer.

Live validator settings, message-lane timing, native-credit ordering and recovery from
bridge limits still need validation before use. The
[operations guide](AMB_VAULT_OPERATIONS.md) covers those gates; the
[integration evidence](AMB_VAULT_INTEGRATION.md) records what has actually been tested.
