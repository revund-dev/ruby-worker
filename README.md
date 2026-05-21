# revund-ruby-worker

The Ruby AST sidecar for [Revund](https://revund.dev). A gRPC server that
implements `revund.worker.v1.Worker` — the universal contract every
Revund worker speaks. Built on
[whitequark/parser](https://github.com/whitequark/parser), the same library
RuboCop, Sorbet, and Brakeman use.

## Install

```bash
gem install revund-ruby-worker
```

You also need the [`revund`](https://revund.dev/install) CLI itself. The CLI
discovers `revund-ruby-worker` on `PATH` and spawns it on demand.

## Usage

The worker is normally launched by the Revund CLI. To run it standalone:

```bash
revund-ruby-worker                              # binds 0.0.0.0:50053
REVUND_RUBY_WORKER_PORT=0 revund-ruby-worker    # OS-assigned port; prints "ready: 0.0.0.0:<port>" on stdout
```

Point the CLI at it via the `REVUND_WORKERS` env var (plain
`host:port` — the CLI calls `Describe` to learn the worker's
languages and capabilities):

```bash
REVUND_WORKERS=localhost:50053 revund review
```

## What it does

The worker advertises one capability via the `Describe` RPC:

| Capability | RPC | Purpose |
|---|---|---|
| `parse` | `Parse` | Returns the universal `ParsedFile` shape — requires, top-level decls (`class` / `module` / `def` / `defs` / `casgn`), method bodies (with cyclomatic complexity, hash, canonical hash, blocks), and concern evidence (Presentation/State/Network/IO/Config/Business/DataAccess/Transport). |

`ResolveSymbols` and `RunDiagnostics` are not implemented yet — the Revund CLI checks the capability list from `Describe` and skips RPCs the worker hasn't advertised.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `REVUND_RUBY_WORKER_PORT` | `50053` | Bind port. Use `0` for OS-assigned (recommended when the CLI spawns the worker). |

## Contract

The wire contract is defined in
[`proto/worker/v1/worker.proto`](./proto/worker/v1/worker.proto), vendored
inside the gem. The canonical source lives at
[`revund-dev/revund-workers/proto/worker/v1/worker.proto`](https://github.com/revund-dev/revund-workers/blob/main/proto/worker/v1/worker.proto).

## License

Apache-2.0
