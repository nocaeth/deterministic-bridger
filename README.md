# USDS to sDAI through an AMB settlement router

This repository contains a new Ethereum-to-Gnosis savings route. A user approves USDS or
sUSDS, then makes one Ethereum deposit transaction. The router redeems sUSDS when needed
and sends USDS through the existing xDAI bridge. In that transaction, it also submits a
claim to AMB. Either source call failing reverts the deposit; delivery on Gnosis happens
later.

On Gnosis, a shared settlement router waits for that exact bridge transfer to execute and for enough
xDAI to be available. It can briefly hold pooled xDAI while claims wait; it does not
issue deposit shares or require a sponsor buffer. It then deposits the claim amount into savings for the chosen
recipient. A separate executor retries delayed claims. The user normally makes no Gnosis
transaction.

The bridge and AMB contracts are existing infrastructure. The new Ethereum router and Gnosis settlement router do
not change them. Their operators and governance remain part of the trust model.

## Read the design

- [Architecture and funds flow](docs/AMB_ROUTER_ARCHITECTURE.md) — the paths for assets
  and claims, payment checks, and retries.
- [Security and ownership](docs/AMB_ROUTER_SECURITY.md) — each layer's powers and
  failure boundaries.
- [Frontend integration](docs/AMB_ROUTER_FRONTEND.md) — wallet calls, statuses, and
  message recovery.
- [Deployment and operations](docs/AMB_ROUTER_OPERATIONS.md) — setup, failures, and
  rollout gates.
- [Integration evidence](docs/AMB_ROUTER_INTEGRATION.md) — historical bridge observations
  and test results.
- [Branch audit](docs/AMB_ROUTER_AUDIT.md) — coverage, deployment checks, and open
  production risks.

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
npm run test:router-settler
npm run test:deployment
```

The pinned fork tests also need Ethereum and Gnosis RPC URLs with access to the
historical blocks in the [evidence guide](docs/AMB_ROUTER_INTEGRATION.md):

```bash
FOUNDRY_PROFILE=amb_router_fork forge test -vv
```

The paired [deployment script](docs/AMB_ROUTER_OPERATIONS.md) checks both chains
and their reciprocal contract addresses in dry-run mode before any transaction.

## Run the executor

The executor needs a dedicated Gnosis gas account and a persistent checkpoint directory.
Set `AMB_GNOSIS_ROUTER`, `AMB_GNOSIS_ROUTER_DEPLOYMENT_BLOCK`, `GNOSIS_RPC_URL` and
`ROUTER_SETTLER_PRIVATE_KEY`, then run:

```bash
node --env-file=.env script/router-settler.mjs
```

Copy `.env.example` to `.env` for the full configuration and keep RPC credentials and
keys private. See [operations](docs/AMB_ROUTER_OPERATIONS.md) before running it outside
local development.

## Before real deposits

The router starts deprecated. Its bridge council Safe can verify the current bridge
implementation, enable deposits, or deprecate them again for an upgrade review.
An Ethereum bridge implementation change blocks deposits until council review.
The Gnosis settlement router needs no
sponsor buffer: bridge credits fund settlement. Optional sponsor xDAI is a permanent
donation. Claims can wait if the bridge, AMB, native credit or savings adapter is
delayed; there is no automatic application refund or deadline. A separate Ethereum
receiver can hold a canonical bridge return for a Safe-reviewed manual refund.

[Fast Confirmation Rule](https://docs.gnosischain.com/bridges/fast-confirmation-rule)
may shorten bridge validator waiting time. Live settings for both delivery paths,
native credit ordering and recovery behavior still need validation. The
[security guide](docs/AMB_ROUTER_SECURITY.md) and
[operations guide](docs/AMB_ROUTER_OPERATIONS.md) list those decisions.
