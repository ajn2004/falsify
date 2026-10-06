# V0.1 evaluator metrics (DAL-120)

**Status:** Frozen before frontier-model pilots; applies identically to every policy. This document resolves only the DAL-120 items delegated by `preregistration-v0.1.md`.

## Common system-identification estimator

For each accepted action/observation pair, fit the stated oscillator equation to every stored displacement sample, jointly across all accepted interventions. Minimize the equally weighted sample mean squared displacement residual (m²) over `ζ ∈ [0.05, 0.40]` and `ω₀ ∈ [0.80, 2.00] rad/s`. No hidden truth is supplied to the fitter. The fixed initialization is the lowest-objective point of a 15×15 equally spaced grid over the closed bounds. From that point, deterministic eight-neighbor coordinate pattern search starts with grid spacings, halves both step sizes when no neighbor improves the objective, and stops when the largest step is below `1e-8` or after 160 iterations. Solver: `Tsit5()`, `reltol=1e-9`, `abstol=1e-11`. No random initialization or noise-dependent weighting is used. Fit status is `success`, `insufficient_evidence` (no usable accepted trace), or `optimizer_failed`; unsuccessful fit parameters are missing. The objective and evaluation count are diagnostics, not policy-visible data. The procedure is shared by all policies.

## Co-primary parameter endpoint

The component errors are

```text
eζ = |ζ̂ - ζ| / (0.40 - 0.05)
eω = |ω̂₀ - ω₀| / (2.00 - 0.80)
raw_parameter_error = sqrt((eζ² + eω²) / 2)
parameter_error = raw_parameter_error / (1 + raw_parameter_error)
```

Dividing by each parameter's preregistered physical support width makes the contributions dimensionless and comparable despite different units/scales; equal squared weighting avoids privileging either parameter. Squashing gives a finite bounded score in `[0,1)`, with lower better, without changing rank among successful fits. On fit failure, the finite confirmatory score is exactly `1.0` and component errors/estimates are missing. Thus every behavioral failure remains in arithmetic aggregation, and failure is no better than any successful fit.

## Co-primary held-out predictive endpoint

The fixed evaluator-only probe set, applied in this order in every world, is:

1. unforced `(x₀,v₀)=(1,0)`;
2. unforced `(x₀,v₀)=(0,1)`;
3. driven `(x₀,v₀)=(0,0), A=0.5 m/s², f=0.75 Hz`;
4. mixed initial state and drive `(x₀,v₀)=(-0.5,0.25), A=-0.5 m/s², f=2.25 Hz`.

All are legal actions, include distinct initial conditions and drive frequencies, and use the apparatus's 10 s/101 sample schedule (or the schedule persisted with the run). The list is fixed from the legal domain, not policy outcomes; neither actions nor targets are provided to the policy. For each probe, generate the true-world trajectory and fitted-model prediction at the persisted measurement times. Raw diagnostic is pooled root mean square displacement error in meters across all probes/samples. The confirmatory score is `raw_RMSE / (2 m + raw_RMSE)`, dimensionless and lower-is-better. A failed fit receives exactly `1.0`; successful scores are strictly below 1.

## Success and secondary outcomes

Secondary success criterion: successful fit and `parameter_error ≤ 0.10`. This corresponds to a small average normalized support-width error and was selected for interpretability, not observed policy separation. Held-out error has no separate success threshold. H2 practical equivalence is **not claimed**; DAL-120 does not establish a justified equivalence margin.

Persisted-artifact-derived records also retain fit MSE and objective-evaluation count as diagnostics; these do not alter scores. Secondary fields include valid interventions, decision opportunities, budget utilization, invalid actions/count and rate, policy-failure events/count and rate, completion status, and whether any invalid action was followed by a valid intervention (recovery). Rates use decision opportunities as denominator. Exploratory identification improvement per intervention is the difference between the error of the fixed support-midpoint estimate `(ζ,ω₀)=(0.225,1.4)` and the fitted estimate's error, divided by valid interventions; it is missing on fit failure or zero interventions. This fixed reference is not a learned/tuned baseline, and no H4 confirmatory claim is enabled. Operational metadata aggregate model calls (zero for a baseline with no call events), available input/output tokens, per-call latency and estimated cost, and provider/model identity; absent usage remains missing, not zero. Event elapsed times are summed as elapsed wall-time proxy. The typed record retains individual per-run values for matched-world aggregation/bootstrap; no inferential procedure is added here.

## Artifact boundary

`score_run(path)` loads `public.json`, `provenance.json`, and `evaluator.json`; alternatively `score_run(load_run(path))` accepts the loaded record. Scoring consumes only persisted action/observation events, evaluator truth, and evaluator-generated held-out probes. It neither receives nor mutates a live world, policy, controller, or public state, and its return value must not be fed back into a running policy.
