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

## Provider credentials

The ScientistPolicy treatment calls OpenRouter through
`src/providers/OpenRouterClient.jl`, which reads `OPENROUTER_API_KEY` from the
environment at request time. Provide it via your shell or secret manager:

```bash
export OPENROUTER_API_KEY=sk-or-...
```

Notes:

- Never commit the key; `.env*` files are gitignored and the repository code
  does not read dotenv files — inject the variable into the process environment
  yourself (e.g. `export`, `direnv`, or a CI secret).
- A missing/empty key produces a safe `PolicyFailure(:configuration_failure)`;
  no network request is attempted, so tests never require credentials.
- The key is only sent as an `Authorization` header to
  `https://openrouter.ai/api/v1/chat/completions`; it is never written into
  request bodies, artifacts, or logs.
- Live calls are part of the exploratory operational gate only; confirmatory
  execution is separately gated and documented in `research/pilot-report-dal123.md`.

With a key set, the manual single-run exploratory smoke (not CI) is:

```bash
julia +1.12.7 --project=. scripts/openrouter_pilot.jl
```
