# Run artifact schema (V0)

Raw run artifacts are directories named by an opaque UUID under `results/raw/`.
Each finalized run contains three independent JSON documents:

- `public.json`: protocol-visible task/configuration, policy identity, ordered
  action/validation/observation events, public status, and terminal result.
- `provenance.json`: runtime and repository identity, manifest SHA-256,
  platform, and separate world/noise/policy seeds and repetition identity.
- `evaluator.json`: hidden oscillator truth, undisclosed condition identifiers,
  and evaluator-only metadata.

These files have intentionally distinct DTO types. The public DTO contains no
world reference or truth/seed fields; callers explicitly create evaluator data
from the evaluator-owned world. Never pass evaluator or provenance files to a
policy. File placement is organizational separation, not an access-control
mechanism: deployments must keep the evaluator/provenance side out of policy
reach.

The current schema version is `1`. `load_run` validates the version in every
document and rejects future/unknown versions instead of guessing how to
interpret them. A future incompatible shape should increment the version; no
migration framework is implied.

`write_run` accepts a complete finalized record, creates its run directory
exclusively, and refuses an existing identity. Treat files as immutable raw
evidence after writing; analysis should load these documents and derive new
outputs elsewhere, never repair or rewrite raw runs. A process interruption
during writing may leave an incomplete directory, which is preserved for
inspection and must not be reused.

Git commit, dirty status, Julia/package version, platform, and a SHA-256 of the
committed `Manifest.toml` are captured best-effort. An unavailable Git value is
`null`, not an assertion that the tree is clean. The dirty flag means
`git status --porcelain` reported any tracked or untracked change at capture
time. Randomness fields remain separate and may be null when unused. The
world-generation seed and condition assignments are evaluator-side provenance;
the public transcript records only participant-visible information.

Decision events preserve action controls, stable validation outcomes,
intervention consumption, observations, remaining budget, status, timing, and
an optional sanitized stable failure code. Public failures have a distinct DTO
that cannot contain evaluator diagnostics; diagnostic text is stored only in
evaluator failures. This compact tagged event is intended to permit future
provider-call events without adding provider execution to V0.

Downstream analysis should operate on `public.json`, `provenance.json`, and
`evaluator.json` loaded from disk. It must not need a live world, rerun the
simulator, or call a model. The transcript contains sampled observations and
actions, sufficient for audit; full replay orchestration is outside this
schema's current scope.
