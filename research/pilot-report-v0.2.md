# V0.2 apparatus pilot report

**EXPLORATORY — NOT CONFIRMATORY.** No treatment-effect claim is made. No
confirmatory protocol was locked and no confirmatory slot was executed.

## Pilot identity and execution

| Pilot protocol | Purpose | Logical slots / outcome |
|---|---|---:|
| `falsify-v0.2-pilot-dal156-v1` | Initial candidate, coupled probe `(0,0,0,0,0.5,0.7)` | 32 baseline slots completed |
| `falsify-v0.2-pilot-dal156-v2` | Probe-choice rerun attempt | Runner defect after first completed slot; partial raw artifact retained |
| `falsify-v0.2-pilot-dal156-v3` | Rerun after policy-name correction | 32 runs completed; post-run state serialization defect; raw artifacts retained |
| `falsify-v0.2-pilot-dal156-v4` | Working baseline runner, probe `(0,0,0,0,0.5,0.25)` | 32 slots completed and materialized offline |
| `falsify-v0.2-pilot-dal156-apparatus-v1` | Expanded baseline apparatus check | 96 slots completed and materialized offline |
| `falsify-v0.2-pilot-dal156-structural-budget-sweep-v1` | Structural budgets 1, 2, 4, 8 | 192 slots completed and materialized offline |
| `falsify-v0.2-pilot-dal156-structural-noise-sweep-v1` | Structural Gaussian σ 0.25, 0.50, 1.00 m | 72 slots completed and materialized offline |

All runs are under `results/pilot-v0.2/`. The v2/v3 failures are retained as
exploratory operational failures; neither version's outcomes were used as a
scientific comparison. Successful runs use the shared run controller and
artifact machinery. The frozen V0.1 outputs were not changed.

Baseline seeds were exploratory and disjoint from the V0.1 confirmatory world
seeds (8123001–8123030) and the earlier DAL-123 pilot seeds (7122123–7122126).
The expanded structural seed sample used a deterministic first-12 class-balanced
selection from seeds 9560201 onward, conditioned only on hidden class, before
running either baseline. Coupled seeds were 9560101–9560112. Budget and noise
sweeps reused their stated worlds only for within-pilot paired apparatus checks.
No confirmatory seed manifest exists yet.

## Structural saturation diagnosis and candidate revision

The version-1 structural environment is saturated rather than scientifically
informative for experiment selection. Across the recorded structural budget
and noise sweeps, FixedDesign classified 12/12 worlds at budgets 1, 2, 4, and
8, including σ=1.0 m. FixedDesign was not changed. No LLM treatment informed
this diagnosis.

Deterministic evaluator-side nuisance-refit maps in
`results/pilot-v0.2/structural-geometry-v*/diagnostic.json` compare a balanced
truth sample against legal initial-condition and drive settings. A candidate
environment version 2 narrows the shared linear/Duffing initial displacement
and velocity limits to `[-0.5,0.5]`, preserving V0.1 global limits, public
field names, class-neutral validation, and the drive space. The map found both
ambiguous low-information settings and discriminating high-amplitude,
low-frequency settings. Under the exploratory σ=0.05 m condition, the first
fixed corner action recovered 8/16 classes; grid recovery ranged from 7/16 to
16/16 with Δ on both sides of zero. A few weak single-intervention nuisance
fits did not converge within the evaluator's current iteration cap. This
supports testing the candidate, not declaring the apparatus acceptable.

Fresh class-balanced Random/Fixed budget pilots for version 2 are the next
gate. Their coupled rerun is included because the shared candidate noise
condition changes. The live LLM pilot, reliability gate, confirmatory seeds,
preregistration, and real lock remain blocked until the new Stage A evidence is
reviewed.

The first revised-apparatus Stage A run is now recorded as
`falsify-v0.2-pilot-dal156-v5`: 512/512 Random/Fixed slots completed across
both environments, 16 class-balanced structural worlds, clean/σ=0.05 m, and
budgets 1/2/4/8. All 32 coupled groups had converged evaluator fits; normalized
held-out error decreased with budget under σ=0.05 m (Random mean 0.00851 at
budget 1 to 0.00196 at budget 8; Fixed 0.00702 to 0.00163). Structural
classification was no longer ceiling-saturated: under σ=0.05 m Random went
from 8/16 to 10/16 correct between budgets 1 and 8, while Fixed went from 9/16
to 10/16. Under clean conditions Fixed was 14/16 at budget 1 and 15/16 at
budgets 2–8. All structural fits converged except one FixedDesign, clean,
budget-1 fit where the Duffing candidate hit the 120-iteration cap. This is an
evaluator convergence issue, not a controller failure, and blocks the live
pilot until checked.

The version-2 evaluator follow-up raises the optimizer cap to 500 (the affected
fit converges at that cap without changing the model-selection rule). A fresh,
class-balanced structural-only Random/Fixed rerun is recorded as
`falsify-v0.2-pilot-dal156-structural-v6`: 256/256 slots completed, with all
evaluator fits converging. This resolved the isolated v5 fit-cap issue, but not
clean saturation. FixedDesign's first corner probe was correct in 15/16 clean
worlds and FixedDesign reached 16/16 at budgets 2, 4, and 8. The noisy condition
was non-ceiling (Random 10/16, 12/16, 11/16, 12/16; Fixed 11/16, 11/16, 12/16,
11/16 for budgets 1, 2, 4, 8). Environment version 2 is not accepted for Stage A
exit; no live pilot may proceed. The v5/v6 artifacts and scores remain separate
exploratory records. No live LLM request has occurred, no 95% reliability gate
was evaluated, and neither a confirmatory seed manifest nor a preregistration
lock exists.

Treatments exercised: `RandomPolicy` and `FixedDesignPolicy` only. Candidate live
configuration was OpenRouter `openai/gpt-5.6-luna`, provider order `openai`, no
fallback, medium reasoning, 512 completion tokens, no provider seed, using
`scientist-v0-2-schema-driven-v1` and `scientist-v0-2-open-loop-v1`. **No provider
requests were made:** `OPENROUTER_API_KEY` was unavailable. Consequently adaptive
history transport, open-loop schedule requests, token/cost/latency, LLM
behavioral reliability, and the 95% infrastructure gate remain untested.

## Baseline apparatus summaries

The expanded matrix had 12 worlds per environment, both candidate noise
conditions, and both baseline policies (96 logical slots). All 96 runs completed;
there were zero behavioral, infrastructure, or evaluator/apparatus failures.
All 48 coupled evaluator fits converged. Across 12 worlds, normalized held-out
prediction error was:

| Policy | Noise | Mean (SD not used for inference) | Median | Range |
|---|---|---:|---:|---:|
| Random | clean | 0.000283 | 0.000209 | 0.000022–0.000845 |
| Fixed | clean | 0.000166 | 0.000164 | 0.000043–0.000330 |
| Random | Gaussian σ=0.10 m | 0.004229 | 0.003802 | 0.002170–0.006369 |
| Fixed | Gaussian σ=0.10 m | 0.003714 | 0.003790 | 0.001377–0.006242 |

The normalized coefficient RMS means were 0.00056/0.00030 (random/fixed) clean
and 0.00819/0.00789 noisy. The normalized prediction endpoint does not show
ceiling behavior; noisy errors remain well below 0.01 on its 1 m reference scale.
The deterministic design check also passed finite/repeatability and 16-truth
noiseless recovery/rank screens. These checks do not establish noisy parameter
identifiability for every support point.

All 48 structural fits in the expanded matrix converged. The 12-world sample
was exactly class-balanced. At budget 8, both policies classified all 12 worlds
correctly under clean and σ=0.10 m noise; no ties/`undetermined` outcomes
occurred. This is descriptive apparatus evidence, not evidence of a treatment
effect. In a separate 12-world paired budget sweep, FixedDesign classified all
12 correctly at budgets 1, 2, 4, and 8 under both clean and σ=0.10 m. Random
classified 12/12 clean at each budget; noisy accuracy was 11/12, 12/12, 11/12,
and 12/12 respectively. The selected-model normalized prediction error and
conditional parameter error were finite at every budget, but structural class
correctness appears close to a floor/saturation for the predeclared FixedDesign
baseline at σ=0.10 m, even with one accepted intervention.

The structural noise sweep retained budget 8 and the same 12 balanced worlds.
Random accuracy was 11/12 at σ=0.25 m, 11/12 at σ=0.50 m, and 8/12 at σ=1.00 m;
FixedDesign was 12/12 at each. At σ=1.00 m the randomized Δ values spanned
−0.0179 to 0.0120 (mean −0.0063); at σ=0.50 m they spanned −0.0457 to 0.0796.
Δ is a signed BIC difference per sample, not a probability. This noise sweep
shows increased structural ambiguity but does not establish a suitable shared
noise condition: coupled-oscillator performance at these higher scales was not
tested, and the fixed policy still saturated class correctness in these 12
worlds.

The four structural probes are unchanged: `(0.2,0,0,0)`, `(0,0,0.2,0.8)`,
`(1.5,0,0,0)`, `(0,0,0.8,1.1)`. Existing deterministic evidence shows a
refitted linear model can closely approximate a low-amplitude Duffing trace,
while high-amplitude probes discriminate. The current pilot sample did not
estimate an across-support low-amplitude ambiguity rate.

## Coupled forced-probe diagnostic

Before treatment outcomes, a deterministic evaluator-side comparison used 32
fixed exploratory truths and the complete zero-state action `(0,0,0,0,0.5,f)`.
Candidate frequencies were 0.25, 0.40, 0.55, 0.70, 1.00, and 1.40 Hz. Ranking by
median minimum singular value of the parameter-range-scaled trajectory
sensitivity matrix was 0.25 (1.135), 0.40 (0.609), 0.55 (0.289), 0.70 (0.192),
1.00 (0.120), and 1.40 Hz (0.081). At 0.25 Hz, median peak displacement was
0.270 m and the largest across these truths was 0.721 m; trajectories remained
finite. The 0.25 Hz candidate was chosen for the next pilot version because it
improved deterministic three-parameter sensitivity and lies in the low-frequency
modal coverage region, without selecting on policy performance. The earlier
0.70 Hz artifacts remain preserved. The proposed full probe is
`(x1,x2,v1,v2,force,frequency)=(0,0,0,0,0.5,0.25)`.

Pilot evaluator candidate is external file
`configs/v0.2-evaluator-pilot-v2.json` (source-file SHA-256 is reproducible with
`sha256sum`). It includes every support, probe, scale, penalty, optimizer control,
and evaluator version. Both prediction normalization scales are 1.0 m: an
interpretable one-meter reference error, not fitted to a policy difference.
These are **pilot configuration values, not a preregistration lock**.

## Operational and reliability accounting

The 96-slot apparatus baseline had 96 completed runs, zero behavioral failures,
zero terminal infrastructure failures, and zero apparatus failures. Its
reliability denominator contains zero LLM logical slots; therefore the gate is
**not tested**, not passed. The two incomplete runner versions are documented
above and are not part of a treatment reliability denominator. No retries were
needed in successful baseline matrices. Provider calls, tokens, estimated cost,
and latency are all zero/not observed because no live LLM request was made.

`scripts/reliability_report_v0_2.jl` now recognizes adaptive and open-loop
scientists separately, reports logical-slot denominator and strata, and retains
the 95% gate. A full pilot reliability report cannot be asserted until genuine
live slots have been recorded.

## Protocol choices considered

| Choice | Pilot observation | Decision at this point |
|---|---|---|
| Coupled fifth probe: 0.70 vs 0.25 Hz | Deterministic sensitivity ranking favored 0.25; both legal/stable | Use 0.25 as the next candidate; lock only after live pilot/protocol review |
| Evaluator scales | 1.0 m corresponds to a one-meter error reference | Retain 1.0 m for pilot; do not tune to treatment outcomes |
| Budget 8 | Coupled fits converge; structural accuracy saturated even at budget 1 | Do not lock 8 yet; structural task geometry needs policy-independent review |
| Clean + Gaussian σ=0.10 m | Both tasks score/converge; structural baseline class correctness saturated | Keep as historical candidate; do not freeze noisy condition until LLM pilot and structural apparatus decision |
| Structural Gaussian σ=0.25, 0.50, 1.00 m | Random ambiguity grows; fixed remains 12/12; σ=1.00 was not evaluated on coupled task | No final sigma selected; evaluate coupled feasibility and consider limits/geometry rather than over-noising |
| Retry limit | Infrastructure taxonomy is explicit; runner retries only an infrastructure attempt with zero accepted interventions | Candidate maximum one; later failures are terminal to avoid duplicate consumed interventions |
| Structural rule | `smaller BIC wins`, exact tie `undetermined`, counted incorrect | Retain; no Δ threshold or probability interpretation |
| Primary endpoints | No apparatus evidence justifies changing hierarchy | Retain candidate coupled normalized prediction error and structural class correctness |

## Protocol decision and stop condition

The baseline apparatus is numerically viable, but the structural class endpoint
is saturated for FixedDesign over the tested budget/noise samples. Higher noise
increased ambiguity for Random but did not remove FixedDesign saturation, and
was not assessed on the coupled task. This merits a policy-independent review of
structural action geometry (and potentially legal action limits) before protocol
lock; no change is made here based on LLM outcomes.

**DAL-156 remains blocked before preregistration lock.** Live OpenRouter adaptive
and open-loop pilots were not executed because no `OPENROUTER_API_KEY` is
available. The 95% gate, provider transport, adaptive history, open-loop
one-request scheduling, LLM cost/latency, and LLM behavioral reliability are
untested. No confirmatory seeds or lock were generated, and no confirmatory
runner was executed. These artifacts are exploratory apparatus diagnostics only.

Raw and materialized evidence is retained in the versioned directories under
`results/pilot-v0.2/`; the report is not a preregistration and leaves the
scientific choices above unresolved pending the required live operational pilot
and resolution of structural saturation.

## Structural v2 noisy reassessment (supersedes the clean-saturation gate)

**Interim status only:** the assessment in this section predates the v8
policy-independent action map below. Its conclusion that v2 was not accepted
because Duffing recovery was poor under generic Random/Fixed actions is
superseded by the action-conditional evidence and current decision at the end of
this report.

Clean results are descriptive apparatus/evaluator positive controls, not the
structural inferential endpoint. The frozen V0.1 precedent treats clean as a
descriptive control and excludes it from confirmatory inference; near-perfect
clean classification is therefore not a reason to reject v2 or alter FixedDesign.
The relevant v2 scientific condition is finite measurement noise.

The converged v6 results at `gaussian_0.05` (16 balanced worlds per
policy-budget cell) are:

| Budget | Random correct | Fixed correct | Random Δ median (range) | Fixed Δ median (range) |
|---:|---:|---:|---:|---:|
| 1 | 10/16 | 11/16 | −0.0459 (−0.0567, 0.4598) | −0.0317 (−0.0727, 0.1958) |
| 2 | 12/16 | 11/16 | −0.0265 (−0.0475, 0.5232) | −0.0249 (−0.0451, 0.1303) |
| 4 | 11/16 | 12/16 | −0.0154 (−0.0319, 0.4413) | −0.0144 (−0.0494, 0.1481) |
| 8 | 12/16 | 11/16 | −0.0084 (−0.0206, 0.8525) | −0.0088 (−0.0733, 0.0993) |

For both policies, all 8/8 linear worlds were selected as linear at every
budget. Duffing recovery was lower: Random 2/8, 4/8, 3/8, 4/8 and Fixed 3/8,
3/8, 4/8, 3/8. No outcomes were undetermined. Median selected-model prediction
RMSE (m), by budget 1/2/4/8, was Random 0.0247/0.0118/0.0085/0.0070 and Fixed
0.0145/0.0122/0.0111/0.0115; median conditional parameter error was
0.0246/0.0160/0.0118/0.0072 and 0.0225/0.0177/0.0111/0.0088, respectively.
All fits converged. Thus v2 is not saturated at the noisy class endpoint, and
prediction/parameter errors improve with budget in places, but the result is
class-asymmetric and Duffing recovery is below chance in most cells.

The earlier σ=0.25/0.50/1.00 sweep covered only budget 8 and 12 worlds, so a
fresh balanced σ=0.25 budget sweep was run as v7 (16 worlds, budgets 1/2/4/8,
both baselines; 128/128 completed, all fits converged, no apparatus failures).
At σ=0.25, Random correctness was 8/16, 8/16, 9/16, 11/16; Fixed was
8/16, 8/16, 9/16, 10/16. Linear was selected for all 8/8 linear worlds in
every cell. Duffing recovery was Random 0/8, 0/8, 1/8, 3/8 and Fixed 0/8,
0/8, 1/8, 2/8. The Δ-per-sample distributions (median [range]) for Random at
budgets 1/2/4/8 were −0.0457 [−0.0471,−0.0432], −0.0259
[−0.0273,−0.0223], −0.0148 [−0.0160,0.0084], and −0.0081
[−0.0118,0.0106]. FixedDesign values were −0.0462 [−0.0565,−0.0230],
−0.0256 [−0.0326,−0.0199], −0.0140 [−0.0172,0.0103], and −0.0080
[−0.0105,0.0038]. Thus the distributions were wholly linear-favoring at
budgets 1–2 and crossed zero at 4–8, while the median remained linear-favoring.
Selected prediction RMSE medians (m) for Random were
0.1206/0.1041/0.0676/0.0377 and Fixed 0.0769/0.0559/0.0368/0.0365;
conditional parameter-error medians were 0.1201/0.1087/0.0863/0.0447 and
0.0690/0.0558/0.0301/0.0403. These finite endpoints and some budget-related
improvement do not offset the poor Duffing recovery. The small earlier
σ=0.25 budget-8 sweep had 12/12 Fixed correct, illustrating substantial
world-sample variability rather than a stable recovery result.

As a signal-relative diagnostic, across public 101-point, 10-second
trajectories, the median second-moment-corrected signal RMS was about 0.148 m
at σ=0.05 and 0.142 m at σ=0.25, giving median σ/RMS ratios 0.32 and 1.50.
This estimator subtracts the known σ² from observed mean-square displacement
and floors at zero; it is a descriptive aggregate across interventions, not a
latent-truth trajectory metric. At σ=0.25, noise is already comparable to or
larger than the typical signal, so increasing noise further is not justified
by this evidence. Clean v6 FixedDesign remains 15/16 at budget 1 and 16/16 at
budgets 2/4/8; report it only as the descriptive positive control.

**Decision:** structural v2 is not yet accepted as the DAL-156 apparatus
candidate, but clean saturation is not the reason. The blocking evidence is
finite-noise class asymmetry: the broad β support does not make Duffing worlds
reliably recoverable under the currently reduced initial-condition envelope,
while the fitted linear family is preferred on most Duffing traces. This is
consistent with weak nonlinear excitation: the Duffing contribution scales as
βx³, or relative to the linear restoring term approximately βx²/ω₀²; at
typical displacements around 0.14 m it is small over much of the support.
The observed improvement in Δ with additional interventions shows that the
101 samples per intervention do not universally make the sequential task
trivial. The next step is a policy-independent nuisance-refit/action-map
diagnostic under σ=0.25, with signal-relative summaries, before any new
environment version is designed. Do not increase noise to force errors or
use LLM outcomes to choose geometry. No live LLM pilot, reliability gate,
confirmatory seeds, preregistration, or real lock has been executed.

## Policy-independent finite-noise action map (v8; current apparatus decision)

This diagnostic used structural environment version 2 and a fresh exploratory
balanced truth set, selected by class from seeds 9,590,000 onward independently
of the v2 design choice: 8 linear and 8 Duffing worlds (truth seeds are recorded
in the raw diagnostic). It evaluated the complete structured legal grid of 81
unique combinations: `x₀,v₀ ∈ {-0.5,0,0.5}`, crossed with 9 drive settings from
zero drive to signed/unit-amplitude forcing at frequencies 0.2–2.5 Hz. Each
action used the fixed 10 s/101-sample schedule. Conditions were clean
(descriptive only) and Gaussian σ=0.05 m (three independently seeded noise
replicates per truth/action). There were 5,184 rows: 1,296 clean and 3,888 noisy.
The diagnostic is policy-independent; no Random, Fixed, adaptive or open-loop
policy selected its geometry. Both nuisance fits converged in every row, and
selected-model prediction RMSE was finite in all rows.

### A. Duffing recoverability under σ=0.05 m

Duffing was recoverable through experiment choice across the sampled support:
all 8/8 Duffing truths had at least one action with correct selection in at
least 2 of 3 independent noisy replicates. Truth support observed in this small
sample was β=0.176–0.787, ζ=0.118–0.283, and ω₀=0.994–1.469. The action
`(0.5,0.5,1.0,0.2)` recovered 8/8 Duffing truths by replicate majority (23/24
individual fits) and selected linear for 8/8 linear truths (24/24 individual
fits). This establishes recoverability in this exploratory sample, not a
population guarantee.

### B–D. Ambiguity, discrimination, and action dependence

Both regimes exist and intervention choice matters. Zero initial state and zero
drive is uninformative about Duffing: it recovered 0/8 Duffing truths, and
Δ=(BIC_linear−BIC_Duffing)/N was −0.04569 for every truth/replicate. With
`(x₀,v₀,A,f)=(0.5,0.5,0,0)`, Duffing recovery was 3/8, with Δ range −0.1671
to 0.2349. By contrast, high-amplitude low-frequency forcing can create strong
separation: at `(0.5,0.5,1.0,0.2)`, Δ ranged −95.992 to 13.288 across classes,
truths and replicates, with the correct class selected for 47/48 observations.
The sign convention is positive for Duffing evidence. Other legal actions were
intermediate; across the 81 actions, noisy Duffing majority recovery ranged
from 0/8 to 8/8, while action-level median Δ ranged from −0.0510 to 0.1121.
Thus the action landscape has ambiguous and discriminating regions, rather than
being uniformly one or the other.

Across all noisy rows, the median clean-trajectory RMS was 0.211 m (range
0–1.376 m), median peak amplitude 0.500 m (0–2.294 m), and median σ/RMS was
0.236 (range 0.036–8.976 where RMS was nonzero). For the one-action shortcut
`(0.5,0.5,1.0,0.2)`, median signal RMS was 0.776 m and median σ/RMS 0.064.
The noise level itself is therefore defensible, but that action has a large
signal-to-noise advantage. Full class-conditional Δ, both candidate scores,
convergence, prediction error, signal RMS/peak, and noise ratios are preserved
per row in `results/pilot-v0.2/structural-action-map-v8/diagnostic.json`.

### E. Universal-action check and prospective decision

**FAIL for the experiment-selection challenge.** A single obvious legal
strategy—maximum positive initial displacement and velocity, maximum drive
amplitude, and one fixed low-frequency drive—classified all 16 sampled worlds
correctly by the noisy replicate-majority rule in one intervention. This is
precisely the universal trivial action the apparatus gate excludes. This is not
a finding that Duffing is undetectable: targeted actions recover it, and weak
actions remain ambiguous. Rather, the action map shows the distinction is
available immediately to a simple predeclared action, leaving no meaningful
selection problem on these conditions. Clean map results remain descriptive
positive controls only.

No v3 was implemented. The smallest scientifically natural prospective change
to investigate is reducing the common legal drive-amplitude ceiling: at
`(0.5,0.5,0.5,0.2)`, Duffing recovery fell to 4/8, while the maximum-amplitude
low-frequency action is the shortcut. Any proposed version change must be
reassessed on fresh policy-independent truths/actions, and must preserve both
ambiguous and discriminating conditions; do not tune FixedDesign, increase
noise merely to induce errors, or use LLM outcomes to choose geometry.

No live LLM pilot ran. Accordingly there are no LLM logical slots, reliability
estimate, token/cost/latency observations, confirmatory seeds, preregistration,
or real protocol lock. DAL-156 remains blocked; this action map does not
authorize provider calls or confirmation.
