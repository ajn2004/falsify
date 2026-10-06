# V0.1 preregistration: sequential identification of a hidden oscillator

**Protocol ID:** `falsify-v0.1-prereg-1`  
**Status:** Initial preregistration; conceptual choices frozen, implementation-dependent values explicitly pending pre-confirmatory lock.  
**Study phase:** Pilot and confirmatory data are separate. No frontier-model pilot results informed this document.  
**Scope:** DAL-119. This document does not implement metrics, noise, a provider, or run orchestration.

## 1. Research question and scope

> How effectively can a language-model agent choose sequential physical experiments to identify an unknown dynamical system under finite experimental budgets?

The V0.1 apparatus is one hidden damped harmonic oscillator. The target is the policy's externally observable experiment selection and the identification/prediction quality supported by the resulting observations—not physics recall, private reasoning, or general scientific intelligence. Conclusions are limited to the implemented oscillator-world distribution, public action space, model treatment, and declared observation conditions; they do not establish performance on other physical systems.

The hidden equation is

```text
x'' + 2ζω₀x' + ω₀²x = a_d sin(2πft)
```

with hidden damping ratio `ζ` and natural angular frequency `ω₀` (rad/s). Policy controls are `initial_displacement_m`, `initial_velocity_m_per_s`, `drive_acceleration_m_per_s2`, and `drive_frequency_hz`. Observations are sampled displacement versus time. Duration and cadence are fixed by the protocol, not chosen by the scientist. The public task may describe the equation, its units and conventions, and action bounds; it must not disclose hidden parameter ranges unless this is separately frozen as participant-visible information before confirmation. The initial V0 scientist task text currently omits hidden parameter ranges.

## 2. Hypotheses and falsification

All comparisons use the common evaluator and matched-world design in this document. “Outperform” means a better direction on the preregistered endpoint, with uncertainty reported; a point estimate alone is not evidence of a reliable advantage.

- **H1 (primary; adaptive scientist vs random):** Under the same 8-intervention budget, the frozen frontier-model ScientistPolicy has better evaluator-scored parameter identification and held-out predictive quality than RandomPolicy. H1 is supported only when both co-primary endpoint contrasts favor ScientistPolicy under the joint rule in Section 7; a favorable result on one endpoint cannot compensate for an unfavorable or inconclusive result on the other.
- **H2 (primary; adaptive scientist vs fixed design):** Under the same 8-intervention budget, ScientistPolicy has better parameter identification and held-out predictive quality than, or is practically comparable to, FixedDesignPolicy. H2 is supported only when both endpoints meet the preregistered superiority-or-equivalence rule in Section 7. Evidence of material inferiority on either endpoint rejects the joint claim; absent a defensible equivalence margin, no equivalence claim is made. Decision opportunities used, invalid attempts, and failure/completion rate are secondary behavioral/efficiency outcomes, not part of the intervention-budget comparison.
- **H3 (secondary behavioral):** Invalid-action and malformed-response rates, and whether the policy recovers after publicly recorded rejection, are meaningful outcomes. Invalid decisions are not free: each consumes one decision opportunity; no automatic repair/retry is allowed. No directional superiority is assumed for H3.
- **H4 (secondary/exploratory):** Adaptive policy behavior may yield greater identification improvement per consumed valid intervention than either non-adaptive control. This remains exploratory unless DAL-120 justifies and freezes a model-independent formula and baseline before confirmation. Do not promote it to a primary endpoint based on observed results.

Null, negative, and heterogeneous results are reportable outcomes. System-One/advisor assistance is disabled and is not a V0.1 condition.

## 3. Experimental conditions and unit

Minimum policy groups, with the same task, public information, action limits, observation process, and budgets:

1. `RandomPolicy` (V0 seeded policy RNG; its own seed, independent of world/noise seeds).
2. `FixedDesignPolicy` (V0 predeclared non-adaptive design: unforced initial-condition corners followed by signed drive-amplitude/frequency sweep; it does not read measurements).
3. `ScientistPolicy(frontier model)` (one model treatment; no leaderboard of multiple frontier models in V0.1).

The fixed design is the implementation already present; it must not be tuned on confirmatory truth or outcomes. The scientist uses the same typed action/observation contract as both baselines. No policy-specific free experiments, intervention budgets, or privileged inputs are allowed.

One run is **one hidden world × one policy × one repetition × one declared protocol condition**. Every run has an opaque run ID, independent world seed, policy seed where applicable, separate repetition ID, and full provenance. Policies are paired on the same predetermined world seeds (common-random-world design). Baseline policy RNG and observation-noise RNG remain independent streams. For a stochastic model, repetition identity is separate from world identity; analyze model repeats within world rather than counting repeats as new worlds.

## 4. Hidden worlds and held-fixed apparatus

Use the current V0 generation rule, not guessed or newly stratified parameter bins: sequential draws from `MersenneTwister(world_seed)`, `ζ ~ Uniform[0.05, 0.40]`, `ω₀ ~ Uniform[0.80, 2.00]` rad/s. The physical truth is fixed within a world. The current action bounds are displacement and velocity `[-2,2]`, drive acceleration `[-1,1]` m/s², and frequency `[0,3]` Hz. These are apparatus choices, not claims about a natural population. No manual deletion of atypical seeds/worlds is allowed.

Confirmatory worlds will be selected by a deterministic, documented seed-generation rule and recorded as a committed seed list before any confirmatory outcome is observed. Seed selection must not depend on model performance. Pilot seeds are disjoint and permanently labeled exploratory. Whether a proposed seed list has acceptable coverage is checked without model outcomes; no post-hoc “easy world” selection. The fixed list/rule and seed custody are to be recorded at protocol lock.

Hold V0 numerical apparatus fixed unless a documented bug blocks validity: `Tsit5()`, `reltol=1e-9`, `abstol=1e-11`, 10 s duration, 101 equally spaced samples (0.1 s cadence). Any apparatus change after pilots is a versioned amendment before confirmation, not a silent per-policy change.

## 5. Budgets and decision opportunities

The primary budget is **8 valid interventions per run**, identical in all policy groups and conditions. Eight permits sequential choices and leaves experiment selection consequential without a broad budget sweep. Each valid intervention returns the protocol-defined displacement trace and consumes one intervention. An invalid action consumes no intervention. An intervention budget is not extended for any policy failure.

Freeze the opportunity cap at **16 policy decision opportunities** per run (8 interventions plus a maximum of 8 rejection/failure opportunities). Every invocation/output attempt consumes one opportunity, whether it produces a valid action, invalid action, or schema/policy failure. There are no hidden retries, automatic corrections, or free parser repairs. An invalid action remains in the public history; if opportunities remain, the policy may respond to the public rejection. Exhaustion with interventions remaining terminates as `failed`. The cap is common across policies; successful runs normally stop when the eight interventions have executed.

DAL-118's engineering default is `intervention_budget + retry_allowance`, with retry allowance defaulting to the budget, so this cap agrees numerically with that default. Its controller catches typed `PolicyFailure` and terminates immediately; malformed output therefore consumes the current opportunity and is a behavioral failure, not a retryable invalid action. Provider/network exceptions mapped to `PolicyFailure` likewise terminate. Unexpected Julia exceptions currently propagate rather than produce a finalized run; this is an implementation conflict to resolve and test before confirmation, not permission to discard them. Model-visible state must include remaining intervention budget and public history. The current public request does **not** expose remaining decision opportunities; DAL-122/123 must add a public, policy-equivalent count (or enforce a non-inferable equivalent) before confirmation so the finite decision cap is an interpretable participant contract. No controller semantics are changed by DAL-119.

## 6. Observation conditions and public noise information

- **Primary condition: clean.** Exactly zero intentionally added measurement noise; sampled displacement is deterministic given world, action, and recorded numerical apparatus.
- **Secondary robustness condition: one noisy condition.** Independent, seeded, additive Gaussian measurement noise on each sampled displacement (`ε ~ Normal(0, σ²)`), with the frozen scale **σ = 0.10 m**. This is 5% of the ±2 m displacement action bound and 10% of the 1 m default initial displacement: visible relative to the signal but not intended to dominate the physical response. Noise is drawn independently of world and policy RNG. For a matched world block, the same noise seed is used across policies; the same accepted intervention index receives the same standard-normal sequence even if adaptive policies choose different actions. Thus the noise variates are matched by index, not the actions/observations, and are signal-independent.

For both conditions, the measurement is the physical signal plus the declared measurement process. Public observations disclose `noise_model` (`none` or `gaussian_additive`) and `noise_scale_m` (0.0 or 0.10). All policies receive equivalent observation semantics. Noise seeds are never shown to policies.

## 7. Primary outcomes, evaluator, and scoring

The evaluator—not the scientist—fits one common system-identification estimator to each run's accumulated accepted experimental observations. Policies do not select their scoring estimator. The scientist does **not** return `ζ` or `ω₀` as the primary scored answer; the primary benchmark tests experiment selection, and primary scores come from the same evaluator pipeline for all three policies.

Two co-primary conceptual endpoints are frozen:

1. **Parameter identification quality:** evaluator-estimated `ζ` and `ω₀` error against hidden truth, with the two parameter scales handled by a DAL-120 formula frozen before confirmation.
2. **Held-out predictive quality:** prediction error for evaluator-inferred system on a fixed, preregistered set of held-out interventions/trajectories not exposed to any policy during selection.

Both must be reported; neither may be dropped or replaced after outcomes are inspected. DAL-120 specifies the estimator, formulas, normalization, and failed-fit handling. DAL-123 confirms the choices are usable without optimizing them for the model. If a common estimator cannot validly identify both parameters from the available evidence, confirmation is blocked pending a preregistered amendment; do not substitute self-reported model answers.

For both H1 and H2, use an intersection-union decision rule: each co-primary endpoint must independently satisfy the contrast rule for that hypothesis; there is no endpoint substitution or compensation. Lower error is favorable. For H1, support requires both ScientistPolicy-minus-baseline world-level effect estimates to favor ScientistPolicy and their two-sided 95% paired-world intervals to exclude zero in the favorable direction. For H2, support requires each endpoint either to meet that same superiority criterion or, if a practical-equivalence margin has been justified and frozen in DAL-120, its 90% interval to lie wholly within that margin. Otherwise report the hypothesis as not supported (distinguishing inferiority from inconclusive evidence). This joint rule does not license a claim based on only one endpoint.

Held-out probes are generated from the same oscillator/action domain using a fixed deterministic rule/list declared before confirmation. They span the declared physical parameter regime and are identical among policies on each matched world. They remain evaluator-only until all decisions in that run are complete. The probe rule must not be tuned against pilot model-policy rankings or confirmatory outcomes. DAL-120 freezes the exact probe controls, count, and prediction-error calculation.

## 8. Secondary and exploratory outcomes

Report separately from the co-primary endpoints:

- invalid-action rate and count;
- malformed structured-response rate and typed policy-failure counts;
- recovery after a public rejection (subsequent valid action and completion), without treating the rejected attempt as free;
- decision opportunities and valid interventions used, including zero-usable-intervention runs;
- completed/failed/aborted fractions;
- identification improvement per consumed intervention (exploratory unless DAL-120 freezes a defensible formula in advance);
- operational token use, request latency, elapsed time, and estimated cost when returned by provider;
- variability across worlds and, separately, stochastic policy/model repetitions.

These logged fields are not automatically separate confirmatory hypotheses. No private chain-of-thought is requested or scored. A structured rationale, if introduced at all, is a separately declared treatment and is out of scope here.

## 9. Run outcomes, failures, and exclusions

Terminal run categories are `completed`, `failed`, and `aborted`; preserve the cause and event history. `completed` means all eight valid interventions were executed. `failed` includes policy termination, malformed model output, provider-call failure after a run has begun, or exhausting decision opportunities with interventions remaining. An invalid model action is a recorded behavioral event; it is not by itself an exclusion. A run with zero usable interventions remains in the failure/behavioral accounting and is not silently removed from the run denominator.

Distinguish **behavioral failure** (invalid action, malformed output, failure to recover, opportunity exhaustion) from **infrastructure failure** (provider outage before a response exists, evaluator/apparatus crash, storage failure). Provider outage is not evidence of poor scientific reasoning. Preserve every attempt and classify it from auditable evidence. A provider outage after a request with no response is retained in operational/reliability reporting; it is excluded only from model identification-effect estimates under the predeclared infrastructure rule, with policy-completion denominators and all exclusions reported. Do not retry invisibly. Any later retry is a new run with a new run ID/repetition identity and the same declared condition; retry policy must be frozen in DAL-123 before confirmation.

Legitimate exclusion is limited to corrupted/incomplete artifacts, invalid provenance, evaluator/apparatus failure preventing valid scoring, a confirmed implementation defect affecting the run, or a documented provider/infrastructure failure for which no usable model response exists. Record exclusion reason, affected run IDs, determination time, and decision-maker. Exclude neither a world nor one policy's matched run based on observed scientific performance; if a world is invalidated by apparatus/provenance failure, remove its matched block from the primary paired comparison and report the block. Model-selected poor experiments, invalid actions, malformed responses, budget exhaustion, and low scores are outcomes, never exclusions. Artifact-write failure leaves partial evidence intact and is an infrastructure failure; it must not be rewritten as a completed run.

The V0 schema supports `completed`, `failed`, and `aborted`, but current run controller finalizes only completed/failed and lets unexpected apparatus exceptions propagate. Before confirmation, DAL-123 must ensure failure classification and durable evidence meet these rules. If `aborted` is used, its trigger must be frozen and distinct from behavioral `failed`.

## 10. Statistical comparison and provisional sample

The unit of analysis for primary policy effects is the **world**. For each endpoint and baseline, compute the per-world paired difference `ScientistPolicy - baseline` under the same observation condition. For ScientistPolicy, first take the arithmetic mean of the three repetition-level endpoint scores within each world; this fixed aggregation defines the scientist's world-level score and is not a plotting choice. Baselines are represented by their single run per world. Aggregate paired differences across the predetermined confirmatory world set and report effect size plus a confidence/uncertainty interval. Use a two-sided 95% percentile bootstrap interval from 10,000 resamples of matched worlds, resampling whole world blocks with replacement and a fixed recorded analysis RNG seed. For H2 equivalence, use the corresponding 90% percentile interval. Emphasize magnitude, direction, interval, world heterogeneity, and repeat variability; do not count model repeats as independent worlds.

Provisional target: **30 distinct confirmatory worlds per condition**, paired across all policies. For ScientistPolicy, plan **3 separately identified model repetitions per world** if operationally feasible; each baseline is run once per world unless pilot evidence of baseline implementation nondeterminism warrants a documented change. Summarize stochastic scientist repetitions within world before the primary world-level comparison and additionally show their within-world variability. This is an initial benchmark demonstration intended to characterize variance and test apparatus, not a claim of publication-grade power. DAL-123 may revise the count/repetition plan for feasibility or precision only before protocol lock and before any confirmatory outcomes; document rationale and freeze the final count. No outcome-dependent optional stopping or sample-size expansion.

Clean is the primary inferential condition. The single noisy condition is secondary robustness; report the same paired contrasts and uncertainty, without pooling it into the clean primary estimate. H1 and H2 comparisons and both co-primary endpoints are all reported. The intersection-union rule above governs each hypothesis; no additional multiplicity adjustment is applied to these joint claims, and no selective endpoint reporting is permitted. Other contrasts/analyses are explicitly descriptive or exploratory.

For a matched world block invalidated by a preregistered infrastructure/apparatus exclusion, omit the entire block from that contrast (never retain only the favorable policy run); report excluded block IDs and counts by reason. Behavioral failures and poor scores are not missing data. Report the number of valid and excluded blocks alongside every interval; DAL-120 defines metric-specific handling for endpoints that cannot be scored.

## 11. Pilot/confirmatory boundary and protocol lock

DAL-123 pilots may find bugs, schema/prompt failures, unusable action settings, infrastructure/cost problems, gross metric floor/ceiling effects, or an unusable candidate noise scale. Pilot results and artifacts remain labeled exploratory; pilot worlds/seeds never enter confirmatory estimates. Pilots may not be used to choose the metric that favors the model, favorable confirmatory seeds, a baseline weakened because it performs well, a budget maximizing model advantage, or failure modes to remove. They do not authorize changing hypotheses after results are seen.

Before DAL-124 begins, freeze and version: exact metric/estimator/probe definitions; noise distribution/scale and disclosure; final model and provider configuration; prompt text/version/hash; baseline versions/configuration; public request schema; budget and opportunity/retry rules; failure and exclusion rules; world/repetition counts and seed list; estimand; within-world repetition aggregation; interval/resampling method and analysis RNG seed; missing-block treatment; multiplicity and endpoint-interpretation rule; code commit and dependency/runtime provenance. Record pilot/confirmatory seed disjointness. Confirmatory execution starts only once the signed-off lock record exists. Any subsequent material change requires a dated amendment, rationale, affected runs, and a new protocol version or experiment designation; do not combine altered runs as though they were the original confirmatory condition.

## 12. Model/provider and prompt control

DAL-122 will integrate the single selected frontier-model treatment through OpenRouter; DAL-119 does not select a model or make a network call. Before confirmation, freeze and persist:

- explicit model slug and version/revision as practically available;
- OpenRouter provider routing and the model/provider identity returned for each request;
- fallback disabled, or exact fallback behavior declared as a treatment (default: disabled);
- all generation parameters and structured-output settings;
- exact prompt text, `PROMPT_VERSION`, and content hash;
- action/response schema version and request-contract version;
- request IDs, timestamps, supplied sampling seed (if any), token counts, latency, cost, finish reason, and provider errors when available.

Mutable remote presets cannot be the sole confirmatory configuration. Any provider/model change forced by availability after lock is a protocol amendment, not a silent substitution. If provider-level deterministic sampling is unavailable or unreliable, model stochasticity is part of the policy: retain the preregistered repeats, record supplied seeds/settings, and distinguish statistical reproducibility from exact replay. Do not claim a provider seed guarantees reproducibility unless verified.

`PROMPT_VERSION` is frozen for confirmation. DAL-123 may approve one final prompt revision before lock. After lock there are no wording tweaks, dynamic coaching, hidden provider-specific instructions, or exception-specific advice beyond the public task/history contract. Misunderstanding the frozen task is measured behavior.

## 13. Leakage and reproducibility controls

Every model request is built from an allowlist and contains only task description, action limits, remaining intervention budget, public decision history, public observations, and sanitized public failures/status permitted by the frozen protocol. Never expose hidden truth/parameter values, world/noise/policy seeds, evaluator condition IDs/metadata, solver internals, clean unsampled or held-out trajectories, future metric results, provider-side evaluator annotations, evaluator artifacts, provenance artifacts, or advisor information. Model/provider operational metadata are not task observations. Leakage in a run invalidates that run and triggers investigation; do not redact/correct it and retain it as an ordinary confirmatory observation. Audit serialized model requests and failure paths before confirmation.

For every run preserve protocol/schema version, repository commit and dirty status, Manifest SHA-256, Julia/package version, environment and solver configuration, world/noise/policy seeds, repetition ID, policy/model/provider settings, prompt version/hash, provider routing, action/observation/failure history, intervention and opportunity budgets, timestamps, model-call metadata, final evaluator outputs/metrics, and opaque run ID. Keep public transcript, provenance, and evaluator-only truth distinctly labeled and access-controlled; identifiers visible to the policy are opaque and non-semantic. Preserve raw artifacts immutably and analyze from persisted records.

## 14. Protocol amendments and unresolved implementation items

Amendments are dated and versioned, identify the exact changed decision, scientific rationale, whether any pilot/confirmatory outcomes were visible, affected conditions/runs, and analysis treatment. Changes after confirmatory execution starts are not folded into this protocol version. Deviations and failures remain reported.

The following are intentionally delegated, and must be resolved before confirmatory runs:

- **DAL-120:** exact common fitting estimator; formulas/normalization for the two co-primary endpoints; fit-failure/missing-data rules; held-out probe list/rule and prediction metric; defensible practical-equivalence margin (or explicitly no equivalence claim); optional efficiency formula. These metric choices feed, but do not defer, the inferential contract frozen before confirmation.
- **DAL-120 resolution:** see [`metrics-v0.1.md`](metrics-v0.1.md) for the frozen estimator, formulas, probes, finite failure values, success threshold, secondary metrics, and explicit no-equivalence/no-H4-efficiency-claim decisions. These values were selected from apparatus support and unit/scale considerations, without frontier-model pilot results.
- **DAL-121 resolution:** Gaussian noise scale, per-sample construction, RNG implementation, public noise metadata, and paired-noise behavior are specified in Section 6 and [`observation-noise-v0.1.md`](observation-noise-v0.1.md). No additional noise levels.
- **DAL-122:** explicit frontier model/version, OpenRouter routing/fallback behavior, generation settings, final structured request/response contract, capture of provider identity/usage/failures, and alignment of malformed/client failures with the decision-opportunity contract.
- **DAL-123:** pilot execution and record separation; final feasibility/precision rationale for world/repetition counts; immutable confirmatory seed list; final prompt revision if any; end-to-end classification/persistence of behavioral versus infrastructure failures; policy-visible decision-opportunity count; and signed protocol lock/version before DAL-124. Lock the three-repeat arithmetic-mean aggregation, bootstrap method/RNG seed, matched-block missingness rule, and joint endpoint/multiplicity interpretation here (informed by DAL-120 metric definitions).
- **DAL-125:** mechanically execute the already-locked analysis plan and produce tables, figures, and reporting. It must not choose or alter estimands, within-world aggregation, interval/resampling method, missing-block treatment, or multiplicity/interpretation after confirmatory outcomes exist.

These items do not reopen the frozen research question, policy groups, matched-world principle, primary/secondary distinction, 8-intervention budget, 16-opportunity cap, clean-primary/noisy-secondary structure, evaluator-owned scoring, exclusion principle, or leakage boundary. Resolve any genuine apparatus conflict through a documented pre-confirmatory amendment; do not silently change controller semantics or expand scope in DAL-119.
