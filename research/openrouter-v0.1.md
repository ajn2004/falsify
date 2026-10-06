# DAL-122 OpenRouter treatment

This is a single frontier-model treatment, not a model comparison. The current
OpenRouter catalog and endpoint listing were checked on 2026-10-05: the selected
slug `openai/gpt-6.1-sol` is available on OpenAI-family endpoints, whose endpoint
metadata declares `response_format` and `structured_outputs` support. The
treatment pins the OpenAI provider family (`order=["openai"]`, `only=["openai"]`),
not one exact serving variant; fallbacks are disabled. The actual serving
provider/variant returned by the API is recorded per response and is not
inferred from routing configuration. DAL-123 must review and freeze this routing
choice; no pilot outcome informed the model choice.

`configs/v0.1-frontier.toml` freezes the model, provider order `openai`,
`allow_fallbacks=false`, reasoning effort `medium`, max completion tokens 512, prompt version
`scientist-v0-1`, and action schema version `experiment-action-v1`. `only` is
also set to `openai`, so no undeclared endpoint is eligible. OpenRouter's
`require_parameters=true` excludes endpoints lacking request parameters. There
is no application retry, model fallback, provider fallback, JSON repair,
response-healing plugin, tool use, or second completion. No provider seed is
supplied for V0.1; provider-level determinism is not claimed. The catalog endpoint does
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

Metadata maps gateway `openrouter`, returned serving `provider`, returned `id`, returned `model`,
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

This uses one fixed seeded non-confirmatory world under the primary noisy
condition (σ = 0.10, two interventions), writes normal raw artifacts, and
enforces the operational gate checklist recorded in
`research/pilot-report-dal123.md` — including proof that the second request
carried the first observation's serialized history. Do not execute
confirmatory runs in DAL-122.

## DAL-123 lock checklist

Resolved at version 3 (`falsify-v0.1-prereg-3`): the temperature/top-p
limitation is locked as a declared treatment property (the endpoint does not
advertise those parameters, so none are sent; provider-side defaults apply);
OpenAI-family routing is locked with the returned serving provider recorded per
response; prompt text/hash, `experiment-action-v1` schema, generation settings,
failure classification (including provider-outage codes classified as
infrastructure), budget/opportunity behavior, and the complete seed/repetition
plan (`v0.1-confirmatory-seeds-v2`) are frozen.

Still open — the live operational gate: run and review the manual pilot; verify
the model and endpoint still exist and support strict structured output;
confirm metadata capture (serving provider, request ID, tokens, latency, cost,
finish_reason) and request-hash reconstruction against the persisted artifact.
Any model, provider, or routing change is an explicit protocol amendment, never
an availability-based substitution.
