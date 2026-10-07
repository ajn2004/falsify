# V0.1 evaluator score materialization

The DAL-124 artifact writer persisted evaluator-owned truth and failure metadata in each immutable run artifact, but did not serialize the frozen evaluator's final endpoint scores. This omission was identified before DAL-125 statistical analysis: no endpoint summaries, figures, confidence intervals, H1/H2 decisions, or findings were inspected before the materialization procedure was fixed.

The scientific evaluator (`score_run`) was frozen before the confirmatory experiment. This correction only runs that evaluator against immutable, persisted prereg-4 observations and materializes its attempt-level results in `results/derived/v0.1-evaluator/`. It does not change scoring rules, resolve retries, exclude matched worlds, or perform statistical analysis. No experiment was rerun, and no provider/model was called.

Reproduce the evaluator-output materialization with:

```bash
julia +1.12.7 --project=. scripts/materialize_confirmatory_scores_v0_1.jl
```
