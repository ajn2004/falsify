# Falsify: Experimental Reasoning in LLM Agents

Falsify is a scientific benchmark for studying whether agents can acquire
evidence and reason effectively in controlled, partially observed experiments.
The repository is currently establishing the **V0 experimental apparatus**.
The [research protocol](research/protocol.md) defines the information boundary;
the executable V0 oscillator environment now provides seeded hidden worlds,
validated experiments, and clean sampled displacement observations. Parameter
ranges, action bounds, and solver settings are documented in that protocol.

## Requirements

- Julia 1.12.7 (the CI-tested version)

Instantiate the pinned project environment:

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Run the tests:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

Run the deterministic, non-LLM package smoke calculation:

```bash
julia --project=. scripts/smoke.jl
```

The disposable smoke calculation still loads `configs/smoke.toml`, solves a
generic first-order decay ODE with SciML, and adds noise from an explicitly
seeded RNG. It writes a TOML result to `results/raw/bootstrap-smoke.toml`; it
is only a package/bootstrap check and is not part of the scientific benchmark.
