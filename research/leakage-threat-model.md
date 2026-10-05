# Leakage threat model

**Purpose:** Define what must not become observable to the experimental policy, and provide actionable review and test requirements for the hidden oscillator apparatus. This threat model applies to simulator, action/observation contracts, provider context construction, artifact/logging paths, and end-to-end tests.

## Assets and boundary

Protected information includes hidden physical parameters, clean/held-out trajectories, ground-truth labels, evaluator scores before the run is complete, world/noise seeds, undisclosed condition assignments, and simulator/evaluator internals. The policy may receive only the declared public task, permitted controls, its own action/observation history, and protocol-required public status. Anything serialized to a model request, returned by a tool, included in an exception, or accessible through a shared object is potentially observable.

The evaluator is authorized to use truth for scoring; authorization does not permit truth to cross into policy-facing state. Provider request/response logs are provenance records, not automatically participant-visible observations. Keep these roles separate and document access controls.

## Threat register

| Leakage source | Information potentially revealed | Scientific consequence | Mitigation | Test / verification strategy |
|---|---|---|---|---|
| Hidden parameters serialized into model context | `ζ`, `ω₀`, forcing parameters, initial truth, or encoded equivalents | Direct answer access substitutes for active inference | Construct policy input only from an allowlisted public-state representation; keep truth in evaluator-owned state | Serialize representative and adversarial worlds; assert protected values/field names are absent; compare context schemas across worlds |
| Ground truth or clean trajectories in errors | Parameters, trajectory arrays, evaluator comparison values | Failed actions or provider errors become an oracle | Map internal exceptions to stable, sanitized protocol errors; retain full diagnostics only in evaluator-side logs | Force failures using worlds with distinct truth; assert public error text is identical or truth-independent |
| Filenames, paths, or IDs correlated with parameters/conditions | Encoded parameter values, seed, condition, difficulty, or policy assignment | Inference from incidental identifiers rather than observations | Use opaque random/non-semantic participant-facing IDs; keep truth/condition labels out of filenames and context | Generate varied truth/conditions and inspect every policy-visible identifier/path for correlation or reversible encoding |
| Seeds exposed in prompts or tools | World generation, noise, or benchmark-set membership | Reconstructs truth or reveals paired/confirmatory structure | Keep all seed material evaluator-only; expose no seed-bearing debug/configuration endpoint | Scan serialized requests and tool outputs for seed fields and known test-seed values |
| Difficulty or ground-truth labels | Easy/hard, parameter-bin, success class, target proximity | Changes strategy with privileged class information and biases results | Do not expose labels unless a separately preregistered protocol explicitly requires them | Schema allowlist test; vary evaluator labels while holding public observations constant and verify context equality |
| Simulator debug output | Internal states, solver steps, clean signal, parameter-dependent diagnostics | Creates a side channel around measurement protocol | Disable debug output at policy boundary; distinguish evaluator diagnostics from public observations | Capture stdout/stderr and tool responses in integration tests; scan for hidden values and trajectory internals |
| Shared evaluator/policy structures | Mutable references to truth, score, clean trajectory, evaluator metadata | Policy can read or mutate evaluator-owned truth; contamination can invalidate scoring | Separate ownership and serialization; pass immutable/minimal public values, not environment/evaluator objects | Adversarial policy test attempts field enumeration/mutation; verify public serialization does not change when evaluator-only fields are added |
| Exception messages and stack traces | Internal filenames, source lines, state dumps, hidden values | Error path becomes a truth or condition oracle | Catch and sanitize at the boundary; do not return raw stack traces/provider internals to policy | Inject simulator, parser, and provider failures; assert public response conforms to fixed schema and contains no stack/source paths |
| Output paths and artifact names | Seeds, condition labels, policy assignment, hidden parameters | Policy or prompt tooling can infer experimental strata | Keep evaluator artifacts outside policy-accessible paths; use opaque identifiers for any public artifacts | Inspect paths exposed through tools/context; test with deliberately distinctive seed/condition labels |
| Timing artifacts | Parameter-dependent solver duration, cache hits, error-path latency, evaluator scoring time | Repeated queries may infer hidden configuration outside declared measurement | Avoid exposing evaluator timing; bound/standardize responses where feasible; record latency as an operational outcome without treating it as a measurement | Benchmark response latency across truth strata and error cases; assess whether differences are stable/actionable; document residual risk |
| Metadata exposed through tools | Environment configuration, package state, process variables, file listings, provenance | Hidden conditions or seeds revealed through a convenience interface | Expose only protocol-approved tool operations and fields; do not provide arbitrary filesystem/environment introspection | Enumerate tool schemas and responses; adversarially query metadata endpoints and verify deny/allow behavior |
| Provider logs confused with agent-visible state | Requests, hidden prompts, evaluator annotations, tool traces, or responses | Analysis may mistake private operational records for observations; logs may also leak if fed back | Label and store provider/evaluator logs separately from public transcript; never concatenate internal annotations into future context | Artifact schema test distinguishes public transcript from private provenance; inspect context assembly source and captured mock-provider requests |
| Noise/condition metadata | Noise seed, exact hidden noise realization, undisclosed condition | Could remove uncertainty or reveal benchmark assignment | Share only declared measurement metadata; do not expose noise RNG state or hidden labels | Compare prompts across noise conditions; assert only preregistered public fields vary |

Timing is a residual channel, not a guarantee of secrecy. If timing can reveal useful truth under repeated measurement, document it and control or measure the channel rather than assuming it is harmless.

## Required invariants for downstream work

- Policy input is built from an explicit allowlist, not by serializing environment/evaluator objects wholesale.
- Hidden truth and evaluator-only metadata remain inaccessible to policy code and absent from policy-visible serialized state.
- Seeds are separated by purpose and withheld from the policy.
- Only protocol-defined observations and sanitized validity/status responses cross the boundary.
- Internal errors, debug output, filenames, and provenance do not become policy observations.
- Public state is equivalent across policies for the same declared experimental history and condition; no policy receives privileged fields.
- Evaluator scoring occurs outside policy execution and does not mutate public state.
- A leakage test suite includes adversarial inspection of serialized context, error paths, tool metadata, and identifiers.
- Provider requests, public transcripts, evaluator-only artifacts, and operational logs are distinguishable in storage and access.

## Reusable code-review checklist

For each change that touches the environment, protocol, provider, artifacts, or tests:

- [ ] Is every policy-visible field named in the public-state contract?
- [ ] Can any field or identifier reveal physical truth, seed, condition, difficulty, or evaluator score directly or by encoding?
- [ ] Does context construction use an allowlist rather than generic serialization of a world, simulator, or evaluator object?
- [ ] Are action errors sanitized and independent of hidden state? Are raw exceptions confined to evaluator-side diagnostics?
- [ ] Could filenames, output paths, IDs, logs, debug output, stack traces, or timing reveal hidden information?
- [ ] Are seeds, RNG state, clean trajectories, held-out targets, and scoring data inaccessible to policy code and tools?
- [ ] Are provider logs and evaluator metadata kept distinct from the transcript supplied to the policy?
- [ ] Do all policies receive equivalent public observations and action opportunities?
- [ ] Do tests try distinct hidden truths and confirm that non-observation outputs do not vary in truth-revealing ways?
- [ ] Are any deliberate disclosures justified by the participant protocol and applied consistently?
- [ ] Is the change covered by a leakage regression test, including failure paths where applicable?

Any “yes” to a possible unapproved disclosure is a blocker until it is removed, explicitly preregistered as public information, or documented as a residual risk with justification and test coverage.
