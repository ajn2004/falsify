# Falsify Agent Guide

## Purpose

This repository is a research project studying experimental scientific reasoning in LLM agents.

The central question is not whether an LLM can answer physics questions. The question is whether an agent can behave as an effective experimental scientist when:

- the underlying system is partially observed,
- ground truth is hidden,
- experiments have a finite budget,
- observations may be noisy,
- useful information must be actively acquired,
- and conclusions must be supported by reproducible measurements.

The benchmark places an agent inside controlled simulated environments and evaluates its observable scientific behavior.

The first environment is a damped harmonic oscillator. Later versions will expand to additional dynamical systems, robustness experiments, and system-one-assisted decision flows.

This repository should read and behave like a scientific instrument, not an AI application demo.

---

# Research Principles

## 1. Scientific validity comes before feature velocity

Do not optimize for how quickly an LLM can be connected to the environment.

Before introducing model behavior, establish:

1. the experimental protocol,
2. the hidden-system environment,
3. the action and observation contracts,
4. deterministic controls,
5. reproducible run artifacts,
6. scoring and evaluation,
7. leakage protections.

A model result produced by an inadequately controlled apparatus is not useful.

---

## 2. Separate hypotheses from implementation decisions

Do not encode expected conclusions into the architecture.

Examples:

Bad:

> The system-one advisor should improve experiment selection, so structure the agent around the advisor.

Good:

> The agent has a stable decision interface. A later experiment may insert an advisor at that boundary and compare it against an otherwise identical control.

The system-one hypothesis belongs primarily to V0.3.

V0 and V0.1 must remain valid whether system-one assistance ultimately helps, hurts, or has no measurable effect.

---

## 3. Treat the LLM as an experimental subject

The LLM must not receive:

- hidden simulation parameters,
- evaluator-only metadata,
- ground-truth labels,
- internal filenames that encode experimental conditions,
- simulator exceptions containing hidden state,
- seeds that reveal benchmark structure,
- difficulty labels unless explicitly included by protocol,
- information unavailable to a real experimental participant.

Every piece of information passed to the model should be defensible as an observable available to the experimental scientist.

Tests should actively attempt to detect leakage.

---

## 4. Evaluate observable behavior, not hidden reasoning

Do not depend on private chain-of-thought or hidden reasoning traces.

Evaluate externally observable scientific behavior:

- experiment selected,
- parameters chosen,
- measurement requested,
- prediction made,
- hypothesis or estimate reported,
- decision to repeat an experiment,
- decision to stop experimenting,
- final model/parameter estimate,
- response to contradictory evidence.

Short structured explanations may be requested if they are themselves an experimental variable, but benchmark correctness must never depend on access to hidden chain-of-thought.

---

# Technical Direction

## Primary language: Julia

The scientific core of this project should be written in Julia.

This is intentional.

The dominant local computation is:

- dynamical-system simulation,
- numerical integration,
- parameter estimation,
- statistical inference,
- experimental design,
- reproducible numerical analysis.

It is not web-service orchestration.

Prefer the Julia scientific-computing ecosystem where appropriate, including:

- `DifferentialEquations.jl`
- SciML packages
- `Distributions.jl`
- `DataFrames.jl`
- `Arrow.jl`
- `JSON3.jl`
- Julia's built-in `Test` framework

Do not introduce Python merely because a model provider has a convenient Python SDK.

LLM providers are remote compute systems and should normally be accessed through thin HTTP/JSON adapters.

Python may be introduced later when a specific library provides a concrete research advantage that outweighs the cost of a second runtime.

---

# Repository Structure

Prefer a structure similar to:

```text
closed-loop-science/
├── AGENTS.md
├── README.md
├── Project.toml
├── Manifest.toml
│
├── src/
│   ├── ClosedLoopScience.jl
│   ├── environments/
│   ├── protocol/
│   ├── baselines/
│   ├── agents/
│   ├── evaluation/
│   └── artifacts/
│
├── test/
│
├── configs/
│
├── research/
│   ├── protocol.md
│   ├── leakage-threat-model.md
│   └── preregistrations/
│
├── results/
│   ├── raw/
│   └── derived/
│
├── figures/
│
└── scripts/
```

Exact organization may evolve, but maintain clear boundaries between:

- simulation,
- experimental protocol,
- experimental policies,
- model-provider integration,
- evaluation,
- artifacts,
- and analysis.

---

# Architectural Boundaries

## Environment

An environment represents hidden physical reality.

For V0, this is a damped harmonic oscillator.

The environment owns:

- hidden physical parameters,
- dynamical evolution,
- ground-truth trajectories,
- numerical simulation,
- observation generation.

Ground truth must not cross into agent-facing interfaces.

---

## Experimental policy

A policy chooses what experiment to perform next.

Policies include:

- random baseline,
- fixed-design baseline,
- future active-design baselines,
- LLM scientist,
- future system-one-assisted LLM scientist.

All policies should consume the same public experimental state and emit the same typed action representation.

Do not create special privileged interfaces for the LLM.

---

## Evaluator

The evaluator may access ground truth.

It calculates metrics such as:

- parameter estimation error,
- held-out trajectory prediction error,
- intervention efficiency,
- success rate,
- invalid-action rate,
- cost,
- latency,
- run-to-run variance.

Evaluation code should not influence experiment execution.

Where practical, analysis should operate solely on persisted artifacts.

---

## Provider adapters

Provider-specific model integration belongs behind a narrow interface.

The core repository should not know whether the policy uses OpenAI, Anthropic, Google, an open model, or another provider.

A provider adapter should primarily perform:

```text
structured experimental state
        |
        v
provider request
        |
        v
structured model response
        |
        v
validated experiment action
```

Do not allow provider SDK conventions to determine benchmark architecture.

---

# Experimental Actions

Experiment actions should correspond to meaningful interventions on the simulated physical system.

For the oscillator this may include:

- selecting initial displacement,
- selecting initial velocity,
- choosing forcing amplitude,
- choosing forcing frequency,
- selecting measurement duration,
- selecting measurement cadence,
- repeating a previous experiment.

Actions should be represented with typed Julia structures.

Validation should occur before simulator execution.

Invalid actions must produce controlled, protocol-defined responses rather than raw simulator errors.

---

# Observation Model

Observations must explicitly distinguish:

- physical signal,
- measurement process,
- measurement noise,
- hidden ground truth.

Noise generation must use an RNG independent from:

- world generation,
- policy randomness,
- model sampling.

For V0.1, begin with seeded Gaussian observation noise unless the protocol specifies otherwise.

The clean condition must correspond to exactly zero intentionally added measurement noise.

---

# Reproducibility

Every benchmark run must be replayable or independently analyzable.

Record at minimum:

- schema version,
- repository commit when available,
- Julia version,
- dependency versions,
- environment configuration,
- world-generation seed,
- observation-noise seed,
- policy seed where applicable,
- hidden truth in evaluator-only artifacts,
- complete public observation history,
- complete action history,
- experimental budget,
- policy identity,
- model/provider identity,
- model parameters,
- prompt/protocol version,
- timestamps,
- model-call latency,
- token usage,
- estimated API cost when available,
- final predictions,
- calculated metrics.

Prefer immutable append-only artifacts.

Do not require a database for early versions unless the research needs one.

---

# Randomness

Do not use a single global random seed for everything.

At minimum distinguish:

```text
world_seed
noise_seed
policy_seed
model/repetition identifier
```

This makes it possible to vary one stochastic source while holding others constant.

Random state must be explicit enough to reproduce deterministic baseline experiments.

---

# Numerical Methods

Numerical simulation settings are part of the experimental apparatus.

Record:

- solver,
- tolerances,
- time span,
- sampling scheme,
- relevant numerical options.

Where analytical solutions or limiting cases exist, test the simulator against them.

A simulation that merely "looks approximately right" is insufficient.

---

# Testing Philosophy

Tests should protect scientific conclusions, not only software correctness.

Important test classes include:

## Numerical tests

Compare simulations against:

- analytical solutions,
- limiting behavior,
- conserved or expected quantities where applicable.

## Reproducibility tests

Same seeds and configuration should produce matching outputs within declared numerical tolerances.

## Leakage tests

Verify serialized agent state does not expose hidden parameters or evaluator metadata.

## Contract tests

Verify every policy uses the same public action/observation interface.

## Artifact tests

Verify persisted results satisfy the schema and can be reloaded independently.

## Provider tests

Use deterministic mock providers before consuming paid model calls.

---

# Baselines

Never evaluate an LLM without meaningful controls.

V0 requires at least:

1. random experiment selection,
2. fixed predeclared experiment selection.

Later versions should consider stronger controls such as:

- Bayesian experimental design,
- information-gain selection,
- optimization-based policies,
- oracle or near-oracle reference policies where scientifically useful.

A sophisticated model beating a deliberately weak strawman is not an interesting result.

---

# Metrics

Prefer metrics that measure scientific usefulness.

Possible metrics include:

- normalized parameter-estimation error,
- held-out prediction error,
- probability of reaching a target error,
- number of experiments required,
- error reduction per experiment,
- information gained per intervention,
- invalid-action rate,
- failure rate,
- variance across worlds,
- variance across repeated model runs,
- token consumption,
- latency,
- monetary cost.

Report uncertainty.

Do not report only aggregate means when variation materially affects conclusions.

Avoid making binary statistical-significance testing the entire analysis.

Effect sizes and confidence/credible intervals are usually more informative.

---

# Pilot vs Confirmatory Runs

Exploratory and confirmatory experimentation must remain visibly separate.

Pilot runs may be used to:

- debug schemas,
- discover unusable action spaces,
- estimate cost,
- determine reasonable noise regimes,
- detect metric saturation,
- refine prompts,
- choose sample sizes.

Pilot worlds used to tune the system must not silently become the confirmatory evaluation set.

Before confirmatory execution:

1. freeze the protocol,
2. freeze prompts,
3. freeze model settings,
4. freeze metrics,
5. freeze noise conditions,
6. define failure/exclusion rules,
7. record the confirmatory seed set.

After confirmatory execution starts, do not change the protocol and continue calling the results the same experiment.

---

# System-One Research

The project will later test whether a small/fast model improves a stronger model's decision process.

The intended comparison is conceptually:

```text
Condition A
Primary model
    |
    v
experiment decision
```

versus:

```text
Condition B
fast advisor / system-one model
    |
    v
Primary model
    |
    v
experiment decision
```

Potential intervention points include:

- selecting the next experiment,
- identifying salient features of a measurement,
- proposing candidate hypotheses,
- deciding whether to repeat a measurement,
- deciding whether evidence is contradictory,
- deciding whether to stop experimentation.

These boundaries should be observable and instrumented in V0.

However:

**V0 and V0.1 must run with the advisor disabled.**

The system-one intervention becomes a first-class experimental condition in V0.3.

Measure not only whether it helps, but:

- whether it reduces cost,
- whether it reduces latency,
- whether it changes variance,
- whether it improves experiment efficiency,
- whether incorrect fast-model suggestions anchor the primary model,
- whether benefits depend on task difficulty or noise.

The null result and negative result are both scientifically valuable.

---

# Version Program

## V0 - Experimental apparatus

Goal:

Build a trustworthy scientific instrument.

Exit criteria:

- Julia/SciML package is reproducible.
- Hidden oscillator world is deterministic from configuration/seeds.
- Public action and observation contracts exist.
- Ground truth does not leak.
- Immutable run artifacts exist.
- Random and fixed baselines run end-to-end.
- Scientist-policy interface exists.
- Future advisor boundaries are instrumented but inactive.
- Full deterministic smoke test passes.

Relevant Linear epic:

`DAL-104`

---

## V0.1 - First controlled result

Goal:

Determine whether an LLM scientist performs useful active experiment selection on hidden damped oscillators.

Compare against:

- random policy,
- fixed policy.

Evaluate under:

- clean observations,
- preregistered noisy observations.

Produce:

- raw artifacts,
- statistical results,
- figures,
- findings memo.

Relevant Linear epic:

`DAL-105`

---

## V0.2 - Environment generalization

Goal:

Determine whether conclusions survive beyond one oscillator task.

Relevant Linear epic:

`DAL-106`

---

## V0.3 - System-one intervention

Goal:

Test whether fast-model guidance improves scientific decision-making.

Relevant Linear epic:

`DAL-107`

---

## V0.5 - Robustness and recovery

Goal:

Measure scientific behavior under misleading or faulty evidence.

Examples:

- anomalous measurements,
- calibration error,
- misleading priors,
- inconsistent observations.

Relevant Linear epic:

`DAL-108`

---

## V0.9 - Locked benchmark

Goal:

Execute statistically meaningful benchmark sweeps across models and conditions using frozen protocols.

Relevant Linear epic:

`DAL-109`

---

## Vfinal - Public research release

Goal:

Publish a research artifact that can withstand external technical scrutiny.

Relevant Linear epic:

`DAL-110`

---

# Linear Workflow

Development is tracked in the Daleego Linear team.

Project:

**Closed-Loop Science: Experimental Reasoning in LLM Agents**

Work from the ticket assigned for the current task.

Before implementation:

1. read the parent epic,
2. read the ticket description,
3. inspect blockers,
4. inspect relevant existing code,
5. identify the scientific invariant the ticket is intended to protect.

Do not expand scope into later milestones simply because the architecture makes it easy.

If implementation reveals a new scientific concern, document it rather than quietly changing the protocol.

---

# Initial V0 Tickets

The initial V0 sequence is:

- `DAL-111` Experimental protocol and leakage threat model
- `DAL-112` Julia/SciML package bootstrap
- `DAL-113` Hidden damped-oscillator environment
- `DAL-114` Experiment/observation/agent contract
- `DAL-115` Immutable run artifacts and provenance
- `DAL-116` Random and fixed-design baselines
- `DAL-117` Provider-agnostic scientist policy
- `DAL-118` Deterministic full-apparatus smoke suite

Respect their dependency relationships.

---

# Initial V0.1 Tickets

The V0.1 sequence is:

- `DAL-119` Preregister hypotheses and benchmark conditions
- `DAL-120` Scientific-performance metrics
- `DAL-121` Controlled noise regimes
- `DAL-122` First frontier-model scientist
- `DAL-123` Pilot experiments and protocol lock
- `DAL-124` Confirmatory benchmark sweep
- `DAL-125` Statistical analysis and figures
- `DAL-126` Findings memo and research-forward README

Do not execute `DAL-124` until the pilot is complete and the protocol is frozen.

---

# Scope Discipline

Avoid premature infrastructure.

Do not add without demonstrated need:

- web applications,
- dashboards,
- distributed task queues,
- databases,
- Kubernetes,
- generalized plugin frameworks,
- elaborate provider abstractions,
- arbitrary multi-agent systems,
- generalized benchmark DSLs.

We are not trying to build the universal AI scientist platform.

We are trying to answer specific empirical questions well.

A small codebase producing a convincing experiment is more valuable than a sophisticated framework producing ambiguous evidence.

---

# Version Control

Using the Jujutsu Versioning control with the github CLI client

- Always set the description to be relevant to the work done in a commit

# Code Quality

Prefer:

- explicit types,
- small interfaces,
- deterministic behavior,
- pure functions where practical,
- clear units,
- clear ownership of randomness,
- testable components,
- stable serialization,
- documented scientific assumptions.

Avoid:

- hidden mutable global state,
- implicit randomness,
- unversioned prompts,
- dynamically changing schemas,
- silent retries,
- silently discarded runs,
- convenience abstractions that obscure experimental state.

---

# Failure Handling

Experimental failures are data.

Do not silently repair failed model runs.

Record:

- invalid model output,
- provider errors,
- simulator failures,
- timeouts,
- budget violations,
- parsing failures,
- retries.

Retry behavior must be defined by the protocol.

If an experimental run is excluded, record why.

---

# Analysis Boundary

Analysis should ideally consume stored artifacts rather than live benchmark objects.

The statistical-analysis path should not:

- call an LLM,
- rerun an environment,
- modify raw experiment data.

Use:

```text
raw results
    |
    v
derived tables
    |
    v
statistics + figures
```

Figures and tables must be regenerable from committed analysis code.

---

# Documentation Style

Write like a researcher, not a product marketer.

Prefer:

> Under the preregistered 12-intervention budget, model A reduced median held-out trajectory error relative to the random policy, with substantial variance across worlds.

Avoid:

> Our revolutionary AI scientist dramatically outperforms traditional approaches.

Clearly distinguish:

- observation,
- interpretation,
- hypothesis,
- speculation.

Negative results should remain visible.

---

# README Philosophy

The eventual README should lead with:

1. the research question,
2. why it matters,
3. the experimental design,
4. the main figure,
5. the result,
6. limitations.

Installation instructions belong below the research story.

A hiring manager or researcher should understand why the project exists within two minutes.

---

# Definition of Done

A ticket is not complete merely because code runs.

A research ticket is complete when:

- the implementation satisfies the ticket,
- tests cover the relevant scientific invariants,
- randomness and configuration are explicit,
- artifacts needed for reproducibility are preserved,
- no hidden-state leakage was introduced,
- documentation reflects material experimental assumptions,
- later experimental conditions have not accidentally contaminated earlier versions.

When uncertain, choose the design that makes the eventual scientific claim easier to defend.
