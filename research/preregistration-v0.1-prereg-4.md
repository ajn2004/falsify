# V0.1 preregistration amendment: prereg-4

**Protocol ID:** `falsify-v0.1-prereg-4`
**Status:** Frozen before the next confirmatory execution. This is the protocol DAL-124 must use.
**Supersedes:** `falsify-v0.1-prereg-3` for the next execution only; prereg-3 remains preserved as historical provenance in [`preregistration-v0.1.md`](preregistration-v0.1.md).

## Amendment record

Prereg-3 is superseded because its projected API cost was judged too high. The revision is made before any ScientistPolicy confirmatory outcome is used or collected for this protocol decision; no treatment outcome informed the amendment. The only prior confirmatory attempt was one RandomPolicy baseline run, invalidated as part of an aborted execution caused by an implementation/provenance defect. That aborted execution is retained separately for audit and is not part of prereg-4. Runner/provenance and recovery-classification defects have since been corrected. Pilot results are unchanged and remain exploratory. This document records the cost decision as a new dated protocol version and does not rewrite prereg-3.

## Frozen design

### Primary confirmatory condition

Use all 30 worlds (`8123001:8123030`) with `gaussian_0.10` observations (Gaussian additive noise, σ = 0.10 m). Run RandomPolicy once, FixedDesignPolicy once, and ScientistPolicy exactly once per world (`scientist-1`). This yields 90 primary logical slots: 30 per policy. ScientistPolicy's nominal cost is 240 requests (30 × 8 decisions).

H1 and H2 apply **only** to these 30 matched Gaussian worlds. H1 requires ScientistPolicy to strictly outperform RandomPolicy on both normalized parameter-identification error and held-out prediction error. H2 requires strict superiority over FixedDesignPolicy on both endpoints. There is no equivalence margin. For each endpoint and paired-world contrast, use the preregistered two-sided 95% paired-world bootstrap interval, 10,000 whole-world resamples, bootstrap seed `9123999`; inference remains paired by world. With one ScientistPolicy repetition per world, there is no within-world ScientistPolicy replication estimate. No variance estimate will be manufactured or substituted.

### Clean apparatus control

Use only the first 10 worlds (`8123001:8123010`) with clean observations; run each of the three policies once per world, with ScientistPolicy repetition `scientist-1`. This yields 30 descriptive slots and 80 nominal ScientistPolicy requests. Clean data are apparatus validation only and are excluded from confirmatory H1/H2 inference.

### Full matrix and budgets

The total is 120 logical slots: 40 ScientistPolicy and 80 baseline slots, with 320 nominal provider requests. The 8-intervention budget and maximum 16 decision opportunities per run are unchanged. Retry semantics, matched-block exclusions, action/observation interface, prompt, schema, hidden-state boundary, estimator, metrics, and intervention semantics are unchanged from prereg-3. No new worlds are generated in response to outcomes.

Seed identities remain fixed: world `8123001:8123030`; noise `9123001:9123030`; RandomPolicy `10123001:10123030`; bootstrap `9123999`. Clean uses the same world/noise seed identities (the clean process consumes no noise RNG).

### Treatment

Treatment model is `openai/gpt-5.6-luna`, provider order `openai`, OpenAI provider only, fallback disabled, 512 max completion tokens, medium reasoning effort, prompt `scientist-v0-1`, schema `experiment-action-v1`. Requests use strict structured JSON experiment-action output. No seed, temperature, top-p, hidden retries, JSON repair, response healing, or tool calls; one completion per decision opportunity. The prompt and scientist-facing interface are not changed because the model changed. Provenance must capture exact model and routing configuration, reasoning effort, prompt hash, schema version, and canonical request hash.

### Recovery and analysis

The repaired shared infrastructure/behavioral classifier is canonical for execution and crash reconciliation. There is no in-run retry; behavioral failures are never retried. An infrastructure-invalidated logical run may have at most one `-retry1` attempt using the same condition and preregistered seeds. Both attempts stay durably ledgered; a second infrastructure failure leaves the slot missing. Apply the existing frozen matched-primary-block exclusion rule.

Report the clean control descriptively, separately from H1/H2. Do not pool it with the Gaussian primary condition or use it to support confirmatory claims. All other prereg-3 decisions not explicitly amended here remain in force.
