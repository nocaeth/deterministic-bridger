# FCR AMB sDAI Vault

An Ethereum-to-Gnosis savings bridge using an immutable source router, a shared
settlement vault, authenticated AMB claims and a durable Gnosis executor.
Users supply USDS or sUSDS; sUSDS is redeemed to USDS before the canonical xDai
bridge relay. This branch contains only the AMB vault architecture.

The source transaction funds the bridge and submits its immutable claim
atomically. The Gnosis vault pays only after authenticating the source router,
checking the exact canonical transfer's processed marker and confirming enough
spendable xDAI. It deposits exactly the claim amount through the savings adapter
for the recorded recipient. Failed conversion leaves the claim pending for a
safe retry; a paid claim can never pay again.

## Architecture and integration

- [Architecture and funds-flow diagrams](docs/AMB_VAULT_ARCHITECTURE.md)
- [Detailed protocol design](docs/superpowers/specs/2026-10-09-fcr-amb-vault-design.md)
- [Frontend integration and recovery states](docs/AMB_VAULT_FRONTEND.md)
- [Deployment and operations](docs/AMB_VAULT_OPERATIONS.md)
- [Pinned bridge evidence and verification results](docs/AMB_VAULT_INTEGRATION.md)
- [Implementation plan and rollout gates](docs/superpowers/plans/2026-10-09-fcr-amb-vault.md)

## Components

| Component | Responsibility |
| --- | --- |
| `MainnetAmbBridgeRouter` | Caller-funded USDS relay or sUSDS redemption; atomic AMB submission; stored-claim resend |
| `SavingsXDaiSettlementVault` | Durable authenticated claims; execution/cash checks; minimum-share protection; at-most-once conversion |
| `VaultClaimLib` | Shared payload and bridge-nonce-based claim identity |
| `script/vault-settler.mjs` | Gnosis discovery, persistent retries, serialized transaction nonce and restart recovery |
| `DeployAmbVault` / `DeployAmbRouter` | Reciprocal immutable deployment with Ethereum CREATE nonce checks |

The application contracts have not been deployed. Public bridge/asset addresses
in the integration evidence describe the tested canonical infrastructure, not
new application deployments.

## Development

Install the locked Node dependencies and Foundry's test library:

```bash
bun install --frozen-lockfile
npm run install:foundry
```

Copy `.env.example` to `.env` and supply configuration for the intended deployment.
Keep RPC credentials and keys private. Local contract and executor checks:

```bash
forge build
forge fmt --check
forge test
npm run check:executor
npm run test:vault-settler
```

The separate pinned-fork suite requires both RPC URLs and access to historical
state at the documented blocks; it fails if configuration or state is unavailable:

```bash
FOUNDRY_PROFILE=amb_vault_fork forge test -vv
```

Deploy the Gnosis vault bound to the expected Ethereum router address first, then
verify the Ethereum deployer nonce and deploy the router bound to the actual
vault. The operations guide provides the dry-run commands and reciprocal checks.

## Completion executor

Provision an existing persistent checkpoint directory and a dedicated Gnosis gas
account. Set `AMB_VAULT`, `AMB_VAULT_DEPLOYMENT_BLOCK`, `GNOSIS_RPC_URL` and
`VAULT_SETTLER_PRIVATE_KEY`, then run:

```bash
node --env-file=.env script/vault-settler.mjs
```

The executor saves a signed transaction before broadcast and retries the same
hash after ambiguous responses. File and directory sync establish checkpoint
durability before submission. Each signer/state file has one process owner;
independent executors use separate accounts and files. The vault remains the
payment authority.

## Production gates

FCR can shorten confirmation latency, but selected xDai/AMB lane timing and real
consensus-mint ordering require live validation. Fees, canonical implementation
upgrades and refund/recovery policy remain explicit rollout decisions. Sponsored
seed is permanently non-withdrawable in this version. Deployment, seed funding
and traffic activation require separate authorization.
