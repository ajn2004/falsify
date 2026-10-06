# Provider-independent scientist policy (DAL-117)

The V0 scientist policy implements the shared `AbstractPolicy` interface and
calls an injected `AbstractModelClient`; no provider SDK, network client, retry,
or run orchestration is part of this boundary. `ModelRequest` is built field by
field from `PublicState`, never by serializing that state wholesale.

## Model-visible information

The request contains exactly: prompt version and provider-neutral task
instruction; the public `TaskDescription.model_description`; action ranges and
fixed measurement schedule from `ActionLimits` (with SI-explicit field names);
remaining intervention budget; and ordered prior action/observation pairs.
Observations contain only sampled times, displacements, optional measurement
uncertainties, and optional publicly declared noise model/scale. The present
`PublicState` history contract contains only accepted action/observation pairs,
so this request cannot represent rejected attempts or public failure outcomes.
DAL-118 extends the shared history contract with public decision entries;
scientist requests project the same entries, including safe validation/failure
codes and post-event budget, without evaluator diagnostics.

No world, truth, seed, condition, evaluator/provenance data, solver details,
unsampled trajectory, or advisor context is accepted by the request DTO. The
task text does not disclose hidden parameter ranges. The prompt requests only a
single structured action; it does not request or store chain-of-thought.

## Response and validation

The client returns `ModelResponse`, with raw structured content and optional
provider-neutral metadata (`provider`, model/request identifiers, token counts,
latency, cost, and finish reason). Metadata may be absent and is not part of the
action. The response content must be exactly one JSON object with exactly these
numeric fields: `initial_displacement_m`, `initial_velocity_m_per_s`,
`drive_acceleration_m_per_s2`, and `drive_frequency_hz`.

Schema failures raise `PolicyFailure` with stable codes: `malformed_response`,
`missing_required_field`, `invalid_field_type`, or `nonfinite_field`. Client
exceptions map to `client_failure`; raw exception messages/stack traces do not
cross the policy boundary. Parsing does not enforce action ranges or drive
constraints. `validate_action(action, state)` remains the experimental
validation owner; a parsed but invalid action is returned unchanged for the run
controller to account for under its protocol.

The client may separately hold private diagnostics, but `ModelResponse` and
`PolicyFailure` expose no such diagnostic channel. Operational metadata is
available to later orchestration without becoming an `ExperimentAction`.

## Experimental scope

Tests use deterministic in-process mock clients only. DAL-117 performs no
network calls, retries, budget accounting, experiment execution, or artifact
writing. A future provider adapter implements `request(::AbstractModelClient,
::ModelRequest) -> ModelResponse` and may be integrated by DAL-122. The V0/V0.1
policy has one scientist client only; system-one/advisor behavior remains
inactive and outside this request boundary.
