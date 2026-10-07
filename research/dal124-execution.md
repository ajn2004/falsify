# DAL-124 execution operations

The locked sweep is executed by `scripts/run_confirmatory_v0_1.jl`; it uses
`run_attempt` for every attempted logical run. No scientific comparisons are
computed here.

First validate and inspect the frozen plan:

```bash
julia +1.12.7 --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
julia +1.12.7 --project=. scripts/run_confirmatory_v0_1.jl --dry-run
```

For live execution, commit the implementation, use a clean checkout at that
commit, and provide `OPENROUTER_API_KEY` in the process environment:

```bash
OPENROUTER_API_KEY=… julia +1.12.7 --project=. scripts/run_confirmatory_v0_1.jl
```

The runner is conservative and serial across logical runs; decisions within a
ScientistPolicy run are necessarily sequential. It records the immutable plan
at `results/confirmatory-v0.1/execution-plan.json`, mutable resume bookkeeping
at `execution-state.json`, and every attempt in `run-ledger.jsonl`. Raw run
directories are under `results/raw/`. Re-running the command resumes from the
ledger: completed and behavioral-failure slots are terminal, and only an
infrastructure-classified original attempt may receive one `-retry1` attempt.
An infrastructure retry that is also infrastructure-classified is terminal.
Do not delete or edit these files to force a rerun. Preserve partial artifacts.

The dry-run prints the deterministic 300-slot/1,440-nominal-request totals and
makes no provider requests or run artifacts. Runtime, commit, and clean-tree
checks are mandatory before live execution; the key is neither printed nor
persisted. The operational summary reports requests, tokens, latency, cost and
provider identities only. DAL-125 owns all scientific scoring comparisons.
