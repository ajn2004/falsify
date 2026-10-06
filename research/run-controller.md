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
failure and terminates the run. Unexpected Julia exceptions propagate.

When the intervention budget is reached, status is `completed`. Exhausting
decision opportunities with interventions remaining is `failed`; a typed
policy failure is also `failed`. A zero intervention budget completes without
calling the policy. Terminal counts are derived from and checked against events.

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
