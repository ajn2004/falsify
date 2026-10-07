# DAL-123 pilot report and protocol lock record

**Status:** Exploratory pilot; protocol version 3 (`falsify-v0.1-prereg-3`) frozen. **Live-provider operational gate: PASSED** (run recorded 2026-10-07 UTC; result appended below); the provider-side prerequisite for DAL-124 is satisfied under the unchanged frozen protocol.  
**Date:** 2026-10-06 (extended 2026-10-06 after review of the first pilot draft; live gate strengthened after second review)  
**Code/runtime:** repository working copy for DAL-123; Julia 1.12.7; project Manifest as committed.  
**Pilot world seeds:** `7122123`, `7122124`, `7122125` (deterministic local baseline pilot) and `7122126` (used once by the live-provider operational gate, exploratory only). These seeds and all pilot observations are excluded from the confirmatory set. Pilot noise seeds follow the same derivation rule as confirmation (`noise = world + 1,000,000` → `8122123–8122126`; `random_policy = world + 2,000,000` → `9122123–9122125`); none overlap the confirmatory file.

## Apparatus and usability checks

The Julia test suite passes in Julia 1.12.7 (620 assertions across package, scientist contract/provider mock, oscillator, noise, baselines, artifacts, controller, infrastructure-failure classification, and metrics testsets). The 8-intervention/16-opportunity contract completed for RandomPolicy and FixedDesignPolicy in all pilot worlds with 8 valid interventions each; no invalid actions or controller failures were observed. The new supervised runner (`run_attempt`) and run ledger were exercised on induced decision-time, finalization-time, persistence, and provider-outage faults. Artifacts were persisted temporarily and scored from the persisted path, matching the analysis boundary. Pilot run metrics are persisted at `results/derived/pilot-condition-matrix-dal123.csv` (48 baseline runs).

## Degeneracy finding (primary motivation for version 3)

The first pilot showed clean-condition scores at ~1e-9 for both baselines on both co-primary endpoints. To decide whether that was merely "a possible floor effect," the pilot was extended across **observation condition (clean, σ=0.10 Gaussian) × intervention budget (1, 2, 4, 8) × {Random, Fixed}** on the three pilot worlds — 48 deterministic runs, no model involvement.

Result: **the clean condition is structurally degenerate.** A single clean 10 s / 101-sample trajectory identifies ζ and ω₀ to the solver/fit floor; endpoint scores are ~1e-9 at *every* budget (identical to displayed precision for budgets 1 through 8). Under the frozen clean-primary design, H1/H2 would reduce to "did the model produce eight schema-valid actions," because any valid run scores ≈ 0 and only malformed responses produce the 1.0 failure score. That does not measure experiment selection.

The σ = 0.10 m noisy condition is non-degenerate and discriminating:

| Condition | Budget | Parameter error range (6 runs) | Held-out error range | Ordering |
|---|---:|---|---|---|
| clean | 1–8 | ~1e-9 (floor) | ~1e-9 (floor) | Random ≡ Fixed |
| σ = 0.10 | 1 | 1.2e-3 – 1.4e-2 | 9.5e-4 – 4.4e-3 | spread |
| σ = 0.10 | 2 | 4.4e-5 – 7.3e-3 | 2.1e-5 – 3.0e-3 | spread |
| σ = 0.10 | 4 | 5.6e-4 – 2.6e-3 | 2.7e-4 – 1.6e-3 | spread |
| σ = 0.10 | 8 | 2.3e-4 – 3.0e-3 | 1.2e-4 – 1.1e-3 | Random and Fixed trade ranks across worlds |

Non-degeneracy criterion applied (model-independent): endpoint scores must be ≥ ~3 orders of magnitude above the clean numerical floor and below the 1.0 failure cap, and must respond to evidence quantity. Only the noisy condition qualifies; it keeps budget 8 informative (more evidence helps, selection still matters). **Protocol change:** noisy σ = 0.10 is now the primary inferential condition; clean is retained as a secondary apparatus-control condition (detects contract/behavioral defects; carries no H1/H2 weight). Budget, observation schedule, action space, estimator, and probes are unchanged.

## Failures, blockers, and changes

1. **Live model pilot (initially unavailable, now executed):** `OPENROUTER_API_KEY` was unset at first draft; the strengthened two-intervention noisy gate has since run live and passed (see "Live gate result" below). Real prompt/schema compatibility, serving identity, request hashes, token usage, latency, and API cost are now observed against the production endpoint.
2. **Runtime mismatch encountered:** default `julia` was 1.13.1 while `Project.toml` pins 1.12.7; `Pkg.test()` correctly refused under the wrong runtime. `julia +1.12.7` passes. **Protocol change:** none; 1.12.7 remains prescribed.
3. **Pilot harness scoring interface mismatch:** an in-memory `RunOutcome` is not an accepted metric input; scoring works through the persisted-artifact path. **Protocol change:** none; analysis runs on persisted artifacts only.
4. **Clean-primary degeneracy (above):** endpoint floor under clean at all budgets. **Protocol change:** version 3 condition swap; clean demoted to apparatus control.
5. **Exception-propagation gap (previously open in Section 9):** resolved by implementation — unexpected non-`PolicyFailure` exceptions finalize runs as `aborted`; `run_attempt` supervises attempts, writes aborted records on finalization-stage escapes, and appends every attempt to a JSON-lines run ledger; `score_run` emits `run_class` ∈ {`completed`, `behavioral_failure`, `infrastructure`} with `NaN` endpoints for infrastructure records. **Protocol change:** failure classification frozen in Section 9; retry rule frozen (no in-run retry; infrastructure-invalidated runs may be re-attempted once as a new run ID with a `-retry1` repetition label).
6. **H2 carried unusable equivalence language:** no equivalence margin exists (DAL-120). **Protocol change:** H2 is strict superiority vs FixedDesignPolicy in version 3.
7. **Seed file froze only world seeds:** now fixes per-world noise seeds and RandomPolicy seeds, the analysis bootstrap seed (9123999), scientist repetition IDs (1,2,3), and the explicit no-provider-seed rule.
8. **No behavioral/action failure** was found in baseline runs at any budget/condition.
9. **Live gate did not exercise the sequential interaction (second review):** the original gate ran `RunConfig(1; max_decision_opportunities=2)` under `exploratory-clean`, so a single valid response ended the run. It verified initial structured output but never the confirmatory interaction's core — request #2 consuming request #1's serialized noisy-observation history. **Change:** `scripts/openrouter_pilot.jl` now performs a two-intervention σ = 0.10 run (world `7122126`, noise seed `8122126`, budget 2, opportunity cap 4, `exploratory-gaussian-0.10`) and enforces the checklist in the gate below, including a SHA-256 reconstruction check proving a post-observation request carried exactly the persisted public history. No protocol change.
10. **`condition_id` dropped on the finalized path:** building the gate surfaced that `run_experiment` never forwarded `condition_id` to `evaluator_artifact`; only aborted records carried it. Fixed — evaluator artifacts now record the condition label on every path. Public artifacts and policy-visible state are unchanged. No protocol change.

## Timing, cost, sample count

Local deterministic run-plus-score: ~0.5–0.9 s steady state (3.9 s cold with compilation). Provider latency/cost measured at the live gate: ~6.4–11.6 s and $0.0026–0.0125 per request, growing with serialized history length.

**Corrected request accounting.** The scientist treatment executes 8 model decisions per completed run (up to the 16-opportunity cap when invalid attempts occur). The frozen design therefore requires:

```text
30 worlds × 2 conditions × 3 repetitions × 8 decisions = 1,440 OpenRouter requests nominal
```

(worst case approaching 2,880 with opportunity-cap exhaustion). The earlier draft's "180 model calls" counted runs, not requests — off by the 8-decision factor. Baselines make no model calls. Sample plan unchanged: 30 matched worlds × 2 conditions, 3 scientist repetitions per world, baselines once per world — a bounded variance-characterization design, not a power guarantee; per-request cost must be measured at the gate before DAL-124 commits spend.

Cost note (non-blocking, recorded for DAL-124): the clean condition is now a secondary apparatus control carrying no H1/H2 weight, yet it still accounts for 720 of the 1,440 nominal requests. A smaller predeclared control sample would suffice for contract/behavioral detection, but shrinking it post-hoc would require a version-4 amendment and a regenerated seed set. Default: accept the cost unless gate-measured per-request cost proves material.

## Frozen decisions (version 3)

- Primary condition σ = 0.10 m additive Gaussian; clean is secondary apparatus control.
- 8 valid interventions / 16 decision opportunities; per-world frozen world/noise/random-policy seeds; analysis bootstrap seed 9123999; scientist repetition IDs {1,2,3}; no provider seed.
- DAL-120 evaluator/metrics/probes; NaN endpoints for infrastructure-classified runs; 1.0 for behavioral failures.
- H1/H2 intersection-union superiority contrasts vs Random and Fixed respectively; H2 has no equivalence branch.
- Model/routing/prompt/schema per `configs/v0.1-frontier.toml` and `openrouter-v0.1.md` (temperature/top-p unsent and locked as a declared treatment limitation; OpenAI-family routing locked, serving provider recorded per response).

### Gate before DAL-124

With credentials available, run `scripts/openrouter_pilot.jl` — a two-intervention σ = 0.10 run on exploratory world `7122126` (noise seed `8122126`, budget 2, up to 4 decision opportunities, `exploratory-gaussian-0.10`). It exits nonzero unless **all** of the following hold: the run completes with 2 consumed interventions; every model response parses under the strict schema; every recorded request SHA-256 equals the hash of the payload reconstructed from the persisted public event history — proving each request, including at least one post-observation request, carried exactly the serialized public state; observations are `gaussian_additive` at σ = 0.10 m with matching per-measurement uncertainty; serving provider/endpoint, served model identity, request id, `finish_reason`, token usage, latency, returned cost, and HTTP 200 are captured per request; the artifact reloads independently with matching condition id and provenance; and a matching run-ledger entry exists. If the first response is invalid, the 4-opportunity cap lets the run still produce a post-observation request; the gate does not pass without one. Use its operational metadata only — never its scientific action — to confirm feasibility and to bound per-request cost ×1,440 before committing confirmatory spend, and append the operational result below. Do not alter model, prompt, schema, metrics, budgets, sample counts, or confirmatory seeds based on its action. If an operational defect requires a material change, issue a dated protocol version 4 amendment and regenerate a disjoint confirmatory seed set before any confirmatory execution. The current confirmatory seed set has not been used.

### Live gate result (run recorded 2026-10-07 UTC)

Executed `scripts/openrouter_pilot.jl` with `OPENROUTER_API_KEY` present. Run `f546ab25-fdde-4df8-a88e-d70e6a381f11` (`exploratory-gaussian-0.10`; world `7122126`, noise `8122126`; 2 interventions / 2 of 4 opportunities) completed cleanly and **all 29 gate checks passed**, including SHA-256 equality between every recorded request hash and the payload reconstructed from the persisted public history — request #2 provably carried request #1's serialized σ = 0.10 observation (101 measurements, noise model, declared uncertainty). Observations verified `gaussian_additive` at σ = 0.10 m. Only operational metadata is recorded here; no scientific action content is used for any decision.

| Request | Provider | Served model | HTTP | finish_reason | Input tok | Output tok | Latency (s) | Cost (USD) |
|---|---|---|---|---|---:|---:|---:|---:|
| 1 | OpenAI | openai/gpt-6.1-sol | 200 | stop | 365 | 187 | 6.42 | 0.0026 |
| 2 | OpenAI | openai/gpt-6.1-sol | 200 | stop | 3,420 | 391 | 11.56 | 0.0125 |

Artifact `results/raw/f546ab25-fdde-4df8-a88e-d70e6a381f11/` reloads independently with matching run id, `condition_id`, and provenance; the run-ledger entry matches.

**Cost bound for the confirmatory sweep.** Per-request cost scaled with serialized history: the second request added one ~101-measurement observation (+3,055 input tokens, +$0.0099). A crude linear extrapolation, ≈ $0.0026 + $0.0099·(k−1) for request k, gives ≈ **$0.30 per 8-decision scientist run** — ≈ **$54 for 180 runs (1,440 requests)** nominal, and ≈ **$1.23/run (~$221)** at the 16-opportunity worst case. This is a two-sample extrapolation, not a quote; DAL-124 should treat it as an order-of-magnitude bound and re-check after the first confirmatory runs. Latency ran ~18 s for 2 requests; an 8-request run plausibly takes ~1.5–2.5 min, putting a serial 180-run sweep in the multi-hour range. Concurrency policy is a DAL-124 decision, unchanged here.
