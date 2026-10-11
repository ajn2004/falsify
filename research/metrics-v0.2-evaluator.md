# V0.2 offline evaluator (DAL-153)

`Falsify.V02Evaluation.score_v0_2_run` accepts only a loaded artifact triple or
run-directory path. Dispatch uses the persisted `environment_id`; it does not
accept a controller or policy object. Score rows use schema `v0.2-score-1`.
`V02EvaluatorConfig` is the evaluator-owned configuration and
`config_hash(config)` is its SHA-256 over canonical JSON serialization. The
configuration contains supports, complete probes (including the coupled forced
probe's amplitude and frequency), optimizer controls, normalization,
and the configurable behavioral-failure penalty. V0.1 `score_run`, fitting,
probes, and frozen results are unchanged.

## Coupled oscillator

The deterministic bounded least-squares objective is the equally weighted
sample mean squared residual over all accepted interventions and both
coordinates. A fixed closed-bound grid initializes the coordinate pattern
search; no random starts are used. Each candidate uses Tsit5 with
`reltol=1e-9`, `abstol=1e-11`; grid size, iteration limit, and stopping tolerance
are configuration fields. Failed/nonconverged fits are returned with a visible
status and no estimates. Truth is read only from `evaluator.json`.

Individual normalized errors are `e_k=|k̂-k|/(4.0-1.5)`,
`e_kc=|kĉ-kc|/(2.0-0.3)`, and `e_c=|ĉ-c|/(0.8-0.15)`. The aggregate is the
symmetric RMS `sqrt((e_k²+e_kc²+e_c²)/3)`; individual errors remain in the score
row. Held-out RMSE is pooled over both coordinates, all samples, and all
configured probes: `sqrt(sum squared coordinate residuals / number of scalar
coordinate samples)`. Raw RMSE is meters. The normalized endpoint is
`rmse/(scale+rmse)`; the scale is configuration, not policy-visible.
The four unforced probes are fixed in code. The fifth forced probe is an
explicit six-value action tuple `(x1,x2,v1,v2,force,frequency)` in config; it is
included only when non-null. DAL-156 must set and hash the complete probe before
lock.

## Linear versus Duffing

Both candidate models fit exactly the stored accepted observations with the
same integration settings, residual objective, fixed-grid initialization and
coordinate-search procedure. Linear has two fitted parameters and exactly
`β=0`; Duffing independently fits three parameters with `β` bounded positive.
Scores use BIC. For known positive observation standard deviation `σ`,
`S=RSS/σ² + k log(N)` (the common Gaussian constants are omitted). If no
positive σ is recorded, residual variance is estimated by Gaussian maximum
likelihood and `S=N log(max(RSS/N, eps()))+k log(N)`. `N` is the scalar
observation count. Tiny/zero RSS is floored at machine epsilon. Smaller score
wins; exact score ties select `undetermined`. This is a selection criterion,
not a probability.

The signed statistic is `Δ=(S_linear-S_Duffing)/N`: positive favors Duffing,
negative favors linear, zero is an exact tie. No abstention threshold is
applied. Both fit statuses, parameter estimates, RSS and BIC scores are
reported. Selected-model held-out error, true-class fit diagnostic held-out
error, and truth-class conditional parameter error are separate. Structural
parameter errors are support-range normalized and computed only if selected
class equals truth class; no cross-class parameter error is produced. The
selected prediction score is missing on an exact tie; wrong-class error is
otherwise retained and class correctness remains separately visible. The
selected structural RMSE is also normalized as `rmse/(scale+rmse)` using the
hashable `structural_prediction_scale_m` configuration field. Ties have
`class_correct=false`, not missing.

The configured structural held-out probes span low and high amplitudes and
are evaluator-only. Each reported RMSE pools all samples over probes. These
probe values are provisional until DAL-156 freezes the hashed configuration.

The evaluator reuses the controller's frozen `classify_run` semantics.
Infrastructure failures have `run_class="infrastructure"` and missing
scientific endpoints. Behavioral failures retain `run_class="behavioral_failure"`
and receive configured penalty on normalized scientific endpoints; for
structural identification `class_correct=false` explicitly retains this
outcome in class accuracy. No partial fit silently repairs the run. Aborted
controller/simulator defects use `run_class="apparatus_failure"` and missing
scientific endpoints; they are not infrastructure exclusions and prevent
protocol lock. Completed but
unidentifiable fits retain explicit fit failure status and missing fitted
endpoints. These are evaluator correctness contracts, not benchmark results.

Offline materialization:

```sh
julia +1.12.7 --project=. scripts/materialize_v0_2_scores.jl <run-root> <output-dir>
```

It reads persisted public/evaluator records only, performs no policy/provider
calls, and writes JSONL plus provenance containing score/config versions,
config hash, code and manifest identity, source artifact hashes, and timestamp.
