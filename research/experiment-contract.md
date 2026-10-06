# V0 experiment and observation contract

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
  "noise_model": "gaussian",
  "noise_scale_m": 0.01
}
```

Each measurement contains only sampled displacement and its time. Uncertainty
and noise metadata may be `null` when the participant protocol does not reveal
them. Clean measurements have exactly zero intentionally added noise. Hidden
parameters, clean unsampled trajectories, seeds, solver diagnostics, and
evaluator data are not fields of this contract.

## Shared policy boundary

All policies implement `next_action(policy::AbstractPolicy, state::PublicState)`
and return the same `ExperimentAction`; the run controller invokes the common
`next_decision` wrapper, which can additionally capture optional operational
metadata without changing the action contract. Random, fixed/grid, active-
design, and LLM policies receive the same allowlisted state. Public history is
an immutable tuple of decision entries and includes accepted observations,
rejected actions, safe failure codes, intervention use, and remaining budget.
History and measurement collections use immutable tuples so policies cannot
mutate run-controller records through shared references. `PublicState` contains no advisor field or
advisor data. A future advisor is inserted outside the primary policy-visible
state, at the decision boundary, as a distinct V0.3 intervention. The fixed
schedule and action controls are visible through the public limits.

`ExperimentAction` is a policy-facing type, distinct from the environment-native
`OscillatorExperiment`. The simulator adapter converts explicitly with
`to_environment_action`; environment-specific naming does not leak into the
policy contract.
