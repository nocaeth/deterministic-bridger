# Architecture

## Purpose

The system routes a deployment-configured mainnet stablecoin from a payer to a deterministic Gnosis receiver address derived from the intended deterministic receiver. After the foreign bridge mints native xDAI to that receiver, any executor can deploy the receiver clone and convert the full xDAI balance into sDAI for the deterministic receiver.

## Components

```text
Mainnet payer
  -> MainnetStablecoinBridgeRouter.bridge(amount)
  -> MainnetStablecoinBridgeRouter.bridgeTo(deterministicReceiver, amount)
  -> configured foreignBridge.relayTokens(gnosisReceiver, amount)
  -> deterministic Gnosis receiver receives native xDAI
  -> SavingsXDaiReceiverFactory.deployAndConvert(deterministicReceiver)
  -> SavingsXDaiReceiver.convertToSavingsXDai()
  -> configured ISavingsXDaiAdapter.depositXDAI(deterministicReceiver)

Accidental ERC-20 transfers
  -> SavingsXDaiReceiver.moveERC20ToReceiver(token)
  -> token.transfer(deterministicReceiver, fullReceiverTokenBalance)
```

- `MainnetStablecoinBridgeRouter` runs on Ethereum. It spends `msg.sender` allowance for `mainnetToken`, predicts the receiver using the Gnosis factory, singleton, and `deterministicReceiver`, approves the configured `foreignBridge`, and calls `relayTokens(address,uint256)`.
- `SavingsXDaiReceiverFactory` runs on Gnosis. It deploys EIP-1167 clones with `CREATE2`, where `salt = keccak256(abi.encode(deterministicReceiver))`, emits the deployed receiver and associated deterministic receiver, and calls conversion immediately after setup.
- `SavingsXDaiReceiver` is the singleton implementation. Each clone stores one `deterministicReceiver`, accepts native xDAI, deposits its full xDAI balance through `ISavingsXDaiAdapter.depositXDAI{value: balance}(deterministicReceiver)`, and can move its full balance of any ERC-20 token only to `deterministicReceiver`.
- `DeterministicReceiverLib` owns salt derivation, minimal proxy creation code, prediction, and deployment so the router and factory share one address derivation path.
- The Tenderly `Deterministic-Bridger` Action validates mined router `BridgeRequested` events when the frontend calls its public webhook, then processes pending deterministic receivers only while the frontend pings it.
- `script/watchtower.mjs` remains a standalone polling utility that can submit `deployAndConvert(deterministicReceiver)` on Gnosis.

## Payer vs Receiver

The mainnet payer is the account whose token allowance and balance are spent by the router. The deterministic receiver is the address used to derive the Gnosis receiver and to receive sDAI shares from the adapter.

- `bridge(amount)` uses `msg.sender` as both payer and deterministic receiver.
- `bridgeTo(deterministicReceiver, amount)` still spends `msg.sender` allowance, but derives the receiver from `deterministicReceiver`.

This distinction lets one payer fund a receiver address without changing deterministic address derivation.

## Address Derivation

The receiver address is derived from:

- Gnosis factory address
- `SavingsXDaiReceiver` singleton implementation address
- EIP-1167 minimal proxy creation code
- `keccak256(abi.encode(deterministicReceiver))`

The invariant is:

```text
gnosisReceiver = CREATE2(factory, salt(deterministicReceiver), clone(singleton))
```

Because both `MainnetStablecoinBridgeRouter.receiverFor(address)` and `SavingsXDaiReceiverFactory.predict(address)` use `DeterministicReceiverLib`, predictions and deployments cannot drift unless deployment configuration changes.

## Deployment Order

1. Configure `.env` from `.env.example`.
2. Deploy `SavingsXDaiReceiver` and `SavingsXDaiReceiverFactory` on Gnosis with `SAVINGS_XDAI_ADAPTER`.
3. Deploy `MainnetStablecoinBridgeRouter` on Ethereum with `MAINNET_TOKEN`, `ETHEREUM_XDAI_BRIDGE`, `SAVINGS_XDAI_RECEIVER_FACTORY`, and `GNOSIS_SINGLETON`.
4. Run fork smoke checks against the exact deployment configuration.
5. Deploy the Tenderly `Deterministic-Bridger` Action, configure its webhook in the frontend, and disable/delete older prefixed Actions if they exist.

## Trust Boundaries

- Users trust the configured mainnet token and foreign bridge pair to be compatible.
- Users trust the configured foreign bridge to pull the token and bridge the intended amount.
- Users trust the Gnosis factory and singleton addresses embedded in the router deployment.
- Users trust the configured Savings xDAI adapter in the singleton deployment.
- The watchtower is not trusted with funds. The Tenderly Action validates fresh mined mainnet router logs before storing work, and anyone can call `deploy`, `convertToSavingsXDai`, `moveERC20ToReceiver`, or `deployAndConvert`.
- The Tenderly webhook is public for browser use. Public callers can trigger bounded work and logs, but cannot choose a payout address or register arbitrary receivers without a fresh router event.
- Failed adapter conversion reverts and leaves xDAI in the receiver for retry.
- No admin-controlled sweep, pause, upgrade, or rescue path exists in the MVP. ERC-20 recovery is permissionless and always sends to the bound `deterministicReceiver`.

## Pre-Deployment Fork Checks

Run:

```bash
MAINNET_RPC_URL=$MAINNET_RPC_URL GNOSIS_RPC_URL=$GNOSIS_RPC_URL forge test --match-contract ForkSmokeTest
```

The fork smoke tests prove:

- The Ethereum bridge proxy has code.
- The Ethereum bridge implementation exposes `relayTokens(address,uint256)`.
- The Gnosis xDAI bridge and sDAI token have code.
- `SAVINGS_XDAI_ADAPTER`, when set, has code on Gnosis.

The Ethereum bridge can be upgradeable. Re-run fork checks immediately before deployment and after any bridge upgrade.
