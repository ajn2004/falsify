# DAL-122 OpenRouter treatment

This is a single frontier-model treatment, not a model comparison. The current
OpenRouter catalog and endpoint listing were checked on 2026-10-05: the selected
slug `openai/gpt-6.1-sol` is available on the OpenAI provider endpoint, whose
endpoint metadata declares `response_format` and `structured_outputs` support.
It is selected as the current frontier general-purpose treatment, with a single
declared provider endpoint and native strict-schema request; no pilot outcome
informed the choice.

`configs/v0.1-frontier.toml` freezes the model, provider order `openai`,
`allow_fallbacks=false`, max output tokens 512, prompt version
`scientist-v0-1`, and action schema version `experiment-action-v1`. `only` is
also set to `openai`, so no undeclared endpoint is eligible. OpenRouter's
`require_parameters=true` excludes endpoints lacking request parameters. There
is no application retry, model fallback, provider fallback, JSON repair,
response-healing plugin, tool use, or second completion. No provider seed is
supplied; provider-level determinism is not claimed. The catalog endpoint does
not advertise temperature/top-p support, so neither is sent. The API default
for those unsupported settings is an outstanding treatment limitation to
review at DAL-123; do not silently tune it.

The HTTP adapter reads `OPENROUTER_API_KEY` at request time. A missing key is a
safe `configuration_failure`. The sole serialization source is `ModelRequest`:
system instruction, then a JSON user payload containing task description,
action limits, remaining intervention budget, remaining decision opportunities,
and ordered public decision history. It excludes seeds, truth, solver/evaluator
information, metrics, provenance, and raw diagnostics. The provider body uses
the OpenRouter chat-completions API and requests strict `json_schema` output for
exactly four numeric action fields with `additionalProperties=false`; the
existing local DAL-117 parser remains authoritative.

Metadata maps returned `id`, returned `model`, provider label `openrouter`,
usage prompt/completion tokens, usage cost when present, local elapsed request
time, and finish reason into provider-neutral metadata. The returned model is
distinct from the requested slug. Every event's operational metadata contains
the SHA-256 of the exact outbound JSON body; event sequence and artifact run ID
identify the decision. Public event history plus the frozen prompt/schema and
provider configuration permit request reconstruction and hash verification.
Prompt SHA-256 and all requested configuration are recorded in provenance.
Credentials and headers are never recorded.

Safe failure codes distinguish `configuration_failure`,
`authentication_failure`, `provider_unavailable`, `rate_limited`,
`provider_rejection`, and `malformed_api_response`. A valid HTTP response with
invalid scientist content follows the existing typed parser failure codes and
preserves operational metadata. No raw response body or provider exception is
surfaced to policy code. Each deliberate request consumes one controller
decision opportunity; provider failure terminates that run and consumes no
intervention.

The shared `PublicState` now exposes `remaining_decision_opportunities` to all
policies, not just the scientist. RunController computes it as opportunity cap
minus opportunities already used; rejected actions consume opportunities as
before. Four-argument `PublicState` construction remains a compatibility
convenience for non-controller callers and represents an unbounded count.

Manual exploratory smoke (not CI):

```bash
OPENROUTER_API_KEY=... julia +1.12.7 --project=. scripts/openrouter_pilot.jl
```

This uses one fixed seeded non-confirmatory world and writes normal raw
artifacts. Do not execute confirmatory runs in DAL-122.

## DAL-123 lock checklist

Before confirmation: run and review the manual pilot; verify this model and
endpoint still exist and continue supporting strict structured output; resolve
the temperature/top-p limitation (any change requires a prompt/config version
update); freeze exact prompt text/hash, schema/request contract, generation
settings, routing, failure/exclusion policy, budget/opportunity behavior,
seed/repetition plan, and immutable confirmatory seeds. Confirm metadata
capture and request reconstruction against persisted artifacts. Any model,
provider, or routing change is an explicit protocol amendment, never an
availability-based substitution.
