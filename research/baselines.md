# V0 non-adaptive baselines

The random and fixed-design policies are minimum controls for comparisons under
matched public state, action limits, and intervention budgets. They are not
claims of optimal experimental design.

## Seeded random policy

`RandomPolicy(seed; driven_probability=0.5)` owns a `MersenneTwister` seeded
only by the policy seed. Each decision independently samples displacement and
velocity uniformly over their public ranges. With probability
`driven_probability`, when a valid driven setting exists (a nonzero allowed
amplitude and positive allowed frequency), it chooses an allowed nonzero
amplitude endpoint uniformly and samples frequency uniformly over the positive
part of its public range. Otherwise it selects the valid unforced setting
`(amplitude, frequency) = (0, 0)`. If only one mode is available, it uses that
mode. Limits that admit neither mode fail explicitly. Duration and cadence are
protocol-owned and never sampled. Reusing a policy instance advances its
private stream; the same seed and call sequence reproduce the same actions.

## Fixed design

`FixedDesignPolicy` first lists four unforced initial-condition settings at the
low/low, high/low, low/high, and high/high corners of the public displacement
and velocity ranges, when zero amplitude and frequency are allowed. It then
lists driven settings at each available nonzero amplitude endpoint (negative
then positive) crossed with the low, midpoint, and high of the positive public
frequency interval. Initial displacement and velocity are at their respective
range midpoints for driven settings. Duplicate frequencies for a singleton
range are retained once. If the public limits allow only one mode, that mode's
settings form the design; if no valid design point exists, selection fails
explicitly. The policy returns the prefix indexed by public history length and
cycles from the first point when history exceeds the design length. Observation
values are never read. Different public limits produce their corresponding
deterministic design.

## Provenance and limitations

`policy_identity` returns `random` or `fixed_design`, version `v0`;
`policy_configuration` exposes the random seed/probability or fixed schedule
rule. DAL-115 already provides `PolicyIdentity` and `ProvenanceArtifact.policy_seed`;
a future run controller should put identity in the public run DTO, configuration
in provenance, and set `policy_seed` for `RandomPolicy` (not expose that
provenance to the policy). A fixed policy has no policy RNG seed.

These controls do not infer physical parameters and do not adapt to measurements.
The random mixture probability and fixed sequence are declared baseline
choices, not tuned against benchmark outcomes. Fisher-information, Bayesian,
and other active-design controls remain out of scope.
