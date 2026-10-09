# USDS to sDAI through an AMB vault

This repository contains a new Ethereum-to-Gnosis savings route. A user approves USDS or
sUSDS, then makes one Ethereum deposit transaction. The router redeems sUSDS when needed
and sends USDS through the existing xDAI bridge. In that transaction, it also submits a
claim to AMB. Either source call failing reverts the deposit; delivery on Gnosis happens
later.

On Gnosis, a shared vault waits for that exact bridge transfer to execute and for enough
xDAI to be available. It then deposits the claim amount into savings for the chosen
recipient. A separate executor retries delayed claims. The user normally makes no Gnosis
transaction.

The bridge and AMB contracts are existing infrastructure. The new router and vault do
not change them. Their operators and governance remain part of the trust model.

## Read the design

- [Architecture and funds flow](docs/AMB_VAULT_ARCHITECTURE.md) — the paths for assets
  and claims, payment checks, and retries.
- [Security and ownership](docs/AMB_VAULT_SECURITY.md) — each layer's powers and
  failure boundaries.
- [Frontend integration](docs/AMB_VAULT_FRONTEND.md) — wallet calls, statuses, and
  message recovery.
- [Deployment and operations](docs/AMB_VAULT_OPERATIONS.md) — setup, failures, and
  rollout gates.
- [Integration evidence](docs/AMB_VAULT_INTEGRATION.md) — pinned bridge observations
  and test results.

The [original design](docs/superpowers/specs/2026-10-09-fcr-amb-vault-design.md) and
[implementation plan](docs/superpowers/plans/2026-10-09-fcr-amb-vault.md) are kept as
project history.

## Run the checks

Install the locked Node dependencies and Foundry test library:

```bash
bun install --frozen-lockfile
npm run install:foundry
```

Run the local checks:

```bash
forge build
forge fmt --check
forge test
npm run check:executor
npm run test:vault-settler
npm run test:deployment
```

The pinned fork tests also need Ethereum and Gnosis RPC URLs with access to the
historical blocks in the [evidence guide](docs/AMB_VAULT_INTEGRATION.md):

```bash
FOUNDRY_PROFILE=amb_vault_fork forge test -vv
```

The paired [deployment script](docs/AMB_VAULT_OPERATIONS.md) checks both chains
and their reciprocal contract addresses in dry-run mode before any transaction.

## Run the executor

The executor needs a dedicated Gnosis gas account and a persistent checkpoint directory.
Set `AMB_VAULT`, `AMB_VAULT_DEPLOYMENT_BLOCK`, `GNOSIS_RPC_URL` and
`VAULT_SETTLER_PRIVATE_KEY`, then run:

```bash
node --env-file=.env script/vault-settler.mjs
```

Copy `.env.example` to `.env` for the full configuration and keep RPC credentials and
keys private. See [operations](docs/AMB_VAULT_OPERATIONS.md) before running it outside
local development.

## Before real deposits

The router and vault have no owner, upgrade or admin withdrawal function. A sponsor's
xDAI buffer is a permanent donation. Claims can wait if the bridge, AMB, native credit
or savings adapter is delayed; there is no application refund or deadline.

[Fast Confirmation Rule](https://docs.gnosischain.com/bridges/fast-confirmation-rule)
may shorten bridge validator waiting time. Live settings for both delivery paths,
native credit ordering and recovery behavior still need validation. The
[security guide](docs/AMB_VAULT_SECURITY.md) and
[operations guide](docs/AMB_VAULT_OPERATIONS.md) list those decisions.
