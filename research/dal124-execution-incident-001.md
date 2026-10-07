# DAL-124 Execution Incident 001

## Incident record

- **Execution commit:** `3fcb8ef4cc01e354cac56f474f167f216248ab3e`
- **Affected run:** `0480b2bc-b2c3-4f2e-8d17-dfd19feeefb7`
- **Logical slot:** `8123001 / gaussian_0.10 / RandomPolicy`
- **Result:** Run completed normally: 8/8 interventions.

## Reason for invalidation

The repository-provenance parser called `strip()` on Git porcelain output. In a
Jujutsu-colocated repository, the first generated path was represented as
`" A results/..."`. Stripping its leading status-column whitespace caused the
path filter to misclassify generated execution output as source dirtiness.

## Scientific information observed before repair

No ScientistPolicy/frontier-model run was executed or scored. No H1/H2 analysis
was performed.

## Disposition

The entire execution instance was aborted. The affected run is retained for
audit but excluded from confirmatory analysis. A fresh execution plan will be
generated under the corrected runner commit.
