# AMB vault integration evidence

Read-only observations on 2026-10-09; no transaction was broadcast. The new router
and vault are undeployed. RPC credentials are excluded from this document.

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

An observed AffirmationCompleted at Gnosis block 48668348 carried destination
`0x455F7c393a7cA1e05E402B06892527383688E7DE`, amount 5e18 and nonce 0x1c35. The
required-RPC fork suite checks this exact destination/amount/nonce hash through
numAffirmationsSigned and isAlreadyProcessed, instead of assuming a signature
threshold is successful execution.

Run the separate required-RPC suite with
`FOUNDRY_PROFILE=amb_vault_fork forge test -vv`; both RPC variables must exist.
It exercises a USDS relay and real savings adapter entirely in local forks.
Observed result: **2 passed, 0 failed** at the pinned blocks. The real adapter
deposit used **87,625 gas** (5 xDAI to a fresh recipient). Peak runner RSS was
496,168 KiB. This verifies ordinary EVM contract behavior, not consensus-native
mint timing.

Primary source and deployment documentation:

- [Canonical bridge architecture](https://docs.gnosischain.com/bridges/About%20Token%20Bridges/xdai-bridge).
- [Token bridge nonce and limits](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/BasicTokenBridge.sol).
- [Foreign relay nonce](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/BasicForeignBridge.sol).
- [Home processed marker](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/BasicHomeBridge.sol).
- [Mint scheduling and incoming fees](https://github.com/gnosischain/tokenbridge-contracts/blob/xdaibridge/contracts/upgradeable_contracts/erc20_to_native/HomeBridgeErcToNative.sol).
- [AMB message sender and source chain](https://github.com/gnosischain/tokenbridge-contracts/blob/master/contracts/upgradeable_contracts/arbitrary_message/MessageProcessor.sol).
- [FCR integration](https://docs.gnosischain.com/bridges/fast-confirmation-rule).

The source branch names are explanatory references; the runtime hashes above pin
the tested implementations. Recheck after any proxy upgrade. The bridge's
upgradeability and validator assumptions remain part of application trust.

## Gates that RPC getters do not establish

- Validator FCR processing mode for the selected xDai and AMB lanes is unverified.
  Node safe tags alone do not establish validator configuration or a delivery SLA.
- Actual consensus reward mint ordering and absence of a recipient callback need
  a separately authorized staging transfer; vm.deal does not prove either.
- Historical or future fee configuration is not proven by today's zero fee getter.
- An immutable implementation pin can strand pending claims on a legitimate
  canonical upgrade. This v1 does not authorize a replacement implementation.
- Canonical refund/recovery into the vault's address on Ethereum is not supported
  by a recovery contract here. No timeout refund or reversible-recovery promise.
- Sponsored seed has no withdrawal path. Production funding is an irreversible
  donation under this v1 design and needs explicit authorization.

Production activation remains gated on these product/trust decisions and a review
of the implemented contracts, executor and observed gas budgets.
