# V0 experiment and observation contract

## V0.2 environment extension boundary (DAL-150)

`AbstractEnvironment` denotes a hidden world implementation, not a policy object.
Each environment implements the task-description and limits methods plus typed
dispatch for `action_schema`, `parse_action(::Type{Environment}, text)`,
`validate_environment_action`, `execute_experiment`, and
`apply_environment_noise`. It also implements `public_action` and
`public_observation`; these methods are the deliberate projections from private
environment values to policy-safe typed values. Schema, environment, and
observation versions are separate provenance fields. Noise receives its seed
and intervention index explicitly and must not use world or policy RNG state.

The run controller handles only `AbstractEnvironment`, typed action/observation
interfaces, and the common budget/history/failure/artifact lifecycle. It must
not branch on environment names. New environment work belongs in its own
methods, not in `RunController.jl`.

The policy request DTO includes the environment-provided strict JSON schema and
public task/limits/history. The environment's type-level parser converts the
response into its native action; the model-facing request never includes the
world, parser closure, RNG, evaluator truth, or provenance object. OpenRouter
transports this request schema with strict structured output and owns no
scientific field names. The original oscillator prompt, action DTO, observation
shape, and serialized field names remain the V0.1 compatibility path.
Public run artifacts retain schema version 1 and add nullable environment/action/
observation schema identity fields; v1 readers continue to accept legacy files
where those optional fields are absent. Evaluator truth keeps its existing
V0.1 JSON keys while the in-memory truth record can be environment-specific.

To implement DAL-151, define a coupled-world subtype and typed action/clean and
policy observation types for both coordinates; provide its public task, schema,
parser, validation, solver, two-channel noise/projection, and private evaluator
methods. To implement DAL-152, define its class-hidden world and its own typed
action and displacement observation methods. Neither ticket should change the
controller, provider transport, or scientist loop. In either environment, do
not put hidden coefficients/class, seeds, generation stratum, truth-derived
modal values, evaluator metrics, solver diagnostics, or evaluator artifact
paths into the public task, request history, validation message, or public
artifact. Persist such values only in provenance/evaluator artifacts under the
existing public/private split.

## DAL-154 adaptive and open-loop LLM treatments

V0.2 distinguishes `scientist_adaptive` (`scientist-v0-2-schema-driven-v1`)
from `scientist_open_loop` (`scientist-v0-2-open-loop-v1`). Adaptive requests
retain public task, legal limits, environment schema, remaining budget, and the
public action/validation/observation history at each decision. V0.1 retains its
frozen `scientist` / `scientist-v0-1` request and prompt.

Open-loop makes one schedule request before experiment 1. Its dedicated
`OpenLoopScheduleRequest` contains only prompt version/instruction, public task,
legal limits, environment action schema, and total intervention budget. It has
no history or observation member and no world, seed, truth, evaluator metadata,
or artifact path. The response is a strict root object `{"actions":[...]}`;
each array item uses that environment's existing action schema and parser, and
the array length is exactly the requested budget. The complete parsed schedule
is cached before the first action and returned in order unchanged. It is not
repaired or regenerated after observations or validation outcomes.

Malformed JSON/root/action content and wrong schedule length are behavioral
failures (`malformed_schedule`, `wrong_schedule_length`); actual provider
delivery errors retain DAL-155 infrastructure codes. Parsed but semantically
invalid actions pass unchanged to ordinary controller validation. Rejected
actions do not cause schedule replacement. If all committed actions have been
attempted while intervention budget remains, the next decision visibly fails
as `open_loop_schedule_exhausted`. The schedule policy instance is single-run;
reuse at a fresh history is rejected. The schedule-generation call's provider
metadata/cost appears only on the first event; later scheduled actions have no
provider-call metadata, so one request is counted once.

Adaptive and open-loop use the same injected client / OpenRouter model,
provider ordering/fallback, reasoning effort, token cap, seed, gateway, and
transport configuration. Only the necessarily distinct prompt and response
schema differ. Open-loop is a control for LLM experiment-set quality; adaptive
additionally permits observation-conditioned selection. This distinction is
not a claim that either treatment is superior. DAL-156 must freeze the final
budget, noise regimes, sample size, and exhaustion/failure handling before
confirmatory work.

DAL-152's `DuffingWorld` has one evaluator-owned `DuffingTruth` with a typed
`DuffingClass`; its public environment identity and contract are class-neutral.
World generation consumes draws in the frozen order class, ζ, ω₀, β, consuming
the β draw for linear worlds too. The class prior is 1/2 each, shared ζ and ω₀
supports are uniform in physical scale, and linear β is exactly zero. It reuses
the V0.1 `ExperimentAction`, schema and stable validator, while explicitly
selecting `scientist-v0-2-schema-driven-v1`; schema identity does not select
prompt identity. Both branches use Tsit5 with identical tolerances and a fixed
10 s/101-sample schedule. Indexed Gaussian noise uses the shared
measurement-noise seed/index rule.

The policy/environment boundary uses typed `ExperimentAction`, `Observation`,
and `PublicState` values in `Falsify`. The matching machine-readable action
shape is [`experiment-contract.schema.json`](experiment-contract.schema.json).
Ranges and schedule are supplied through `ActionLimits`; the policy-facing
`TaskDescription` contains only a model description, separate from the
environment-native `OscillatorTaskDescription`. SI units are explicit in field
names.

## Action example

```json
{
  "initial_displacement_m": 0.1,
  "initial_velocity_m_per_s": 0.0,
  "drive_acceleration_m_per_s2": 0.0,
  "drive_frequency_hz": 0.0
}
```

Zero drive acceleration and frequency means no drive. A driven experiment
requires positive frequency. Duration and cadence are protocol-fixed in
`ActionLimits`, not selected by the policy; this keeps measurement volume equal
per intervention. Repetition means submitting the same controls again and
consumes another intervention. Validation reports only stable codes, never
simulator exceptions.
Invalid attempts do not consume an intervention here; decision-opportunity
accounting is a run-controller responsibility and must follow the frozen
protocol.

## Observation example

```json
{
  "measurements": [
    {"time_s": 0.0, "displacement_m": 0.1, "uncertainty_m": 0.01},
    {"time_s": 0.1, "displacement_m": 0.096, "uncertainty_m": 0.01}
  ],
  "noise_model": "gaussian_additive",
  "noise_scale_m": 0.10
}
```

Each measurement contains only sampled displacement and its time. Measurement
uncertainty equals the declared Gaussian sigma (zero in clean). Noise metadata
is always disclosed: clean uses `noise_model="none"`, `noise_scale_m=0.0`; noisy
uses `noise_model="gaussian_additive"`, `noise_scale_m=0.10`. Hidden
parameters, clean unsampled trajectories, seeds, solver diagnostics, and
evaluator data are not fields of this contract.

## Shared policy boundary

All policies implement `next_action(policy::AbstractPolicy, state::PublicState)`
and return the same environment-native subtype of `AbstractExperimentAction`;
the run controller invokes the common `next_decision` wrapper, which can
additionally capture optional operational metadata without changing the action
contract. Random, fixed/grid, active-design, and LLM policies receive the same
allowlisted state. Public history is
an immutable tuple of decision entries and includes accepted observations,
rejected actions, safe failure codes, intervention use, and remaining budget.
History and measurement collections use immutable tuples so policies cannot
mutate run-controller records through shared references. `PublicState` contains no advisor field or
advisor data. A future advisor is inserted outside the primary policy-visible
state, at the decision boundary, as a distinct V0.3 intervention. The fixed
schedule and action controls are visible through the public limits.

V0.1 retains the policy-facing `ExperimentAction`, distinct from the native
`OscillatorExperiment`; conversion remains explicit through
`to_environment_action`. Other environments define their own typed action and
observation types. Provider-facing names are owned by the environment schema,
not by the generic policy loop or provider transport.
