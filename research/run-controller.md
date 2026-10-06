# V0 run controller

`run_experiment(world, policy, RunConfig(...))` owns one complete run. It builds
an allowlisted `PublicState`, invokes the common `next_decision` interface,
validates the returned action, executes accepted experiments, and constructs
the three DAL-115 artifacts. Only `OscillatorWorld` and this controller hold
evaluator state; policies receive immutable public decision history only.

## V0 lifecycle and accounting

An intervention is consumed only after action validation succeeds and the
environment returns its observation. Every policy invocation consumes one
decision opportunity, including invalid actions and `PolicyFailure`. The V0
engineering default is `max_decision_opportunities = intervention_budget +
retry_allowance`, with `retry_allowance` defaulting to the intervention budget.
Invalid actions are public events, have no observation, retain the budget, and
are never replaced automatically. A `PolicyFailure` becomes a sanitized public
failure and terminates the run. Unexpected Julia exceptions abort the run (see
below); they no longer propagate out of the decision loop.

When the intervention budget is reached, status is `completed`. Exhausting
decision opportunities with interventions remaining is `failed`; a typed
policy failure is also `failed`. A zero intervention budget completes without
calling the policy. Terminal counts are derived from and checked against events.

## Abort and supervision (DAL-123)

An unexpected exception — anything that is not a typed `PolicyFailure` from the
policy call, or any fault inside action validation, `observe`, or the
measurement process — aborts the run: it terminates as `aborted` with public
failure code `apparatus_exception`, preserving the executed event history. The
exception type name (never its message) is recorded as an evaluator-side
`EvaluatorFailure` diagnostic; nothing exception-derived enters the public
artifact beyond the stable code. `aborted` is never a policy outcome and is
always classified `infrastructure`.

`run_attempt(world, policy, config; artifacts_root, ledger_path, ...)` is the
supervised entry point for benchmark execution. It runs `run_experiment`,
persists artifacts when possible, and appends one JSON-lines record to the run
ledger for every attempt — including attempts where `run_experiment` escapes
during finalization (a durable `aborted` record with `unfinalized_events` is
written) or where persistence itself fails (the ledger line remains the last
resort record). The per-attempt `classification` is `completed`,
`behavioral_failure`, or `infrastructure`; a `failed` run is `infrastructure`
when its terminal failure code is a provider/transport fault
(`PROVIDER_INFRASTRUCTURE_CODES`), i.e., no usable model response existed. The
confirmatory runner for DAL-124 must execute through `run_attempt` so that no
attempt can vanish without an auditable record.

`DecisionHistoryEntry` is the common public history: requested action,
validation code, intervention consumption, returned observation, safe failure
code, and post-event remaining budget. Scientist request DTOs project this
same history; baselines use it through `PublicState` and do not get policy-
specific event formats.

`PolicyDecision` carries an action plus optional provider-neutral operational
metadata. Scientist decisions capture `ModelMetadata` fields on the run event;
ordinary policies return no metadata. This metadata is provenance/operations,
not part of the action or future public state.

The event sequence is validated before `PublicRunArtifact`, provenance from the
concrete world and policy configuration, and evaluator truth are bound to one
opaque run ID. `write_run` persists those independent documents. The smoke
suite reloads the artifacts and checks that recorded actions and observations
match the run.

V0 smoke tests establish deterministic fixed, random, and mock-scientist
execution, including rejected-action recovery, policy failure, exhaustion,
and public serialization leakage checks. They use no provider/network and
write only into temporary directories. These retry/exhaustion and failure
termination choices are engineering defaults; DAL-119 must freeze the
confirmatory decision/call accounting, retry rules, and exclusion semantics
before benchmark execution.
