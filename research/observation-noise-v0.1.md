# V0.1 observation-noise implementation

The physical oscillator and its numerical trajectory remain deterministic. The
measurement layer receives the protocol-sampled `CleanOscillatorObservation`
and returns the only policy-visible `Observation`.

V0.1 has exactly two conditions:

- `CleanObservation`: `yᵢ = xᵢ` exactly, with metadata `none`, `0.0 m`; no
  random number is generated.
- `GaussianObservationNoise(0.10)`: `yᵢ = xᵢ + εᵢ`, independently sampled
  `εᵢ ~ Normal(0, (0.10 m)²)` for each sample. The frozen scale is 0.10 m: 5%
  of the ±2 m action displacement bound and 10% of the default 1 m initial
  displacement. This makes measurement variation nontrivial relative to the
  signal while avoiding a noise scale intended to overwhelm it.

`RunConfig` owns noise condition and explicit nonnegative `noise_seed` (default
0 for reproducible clean/default runs). For Gaussian noise a local
`MersenneTwister` is created per accepted intervention, with seed
`(noise_seed + index * 0x9e3779b97f4a7c15) mod typemax(Int)`; `index` is the
1-based accepted-intervention position. The algorithm identifier is
`indexed-mt19937-julia-randn-v1` (Julia `randn`). Rejected actions and policy
failures do not allocate or advance a stream. World and RandomPolicy own
separate RNG streams.

Matched world runs share the preregistered noise seed schedule across policies.
At a given intervention index the generated standard-normal vector matches,
even if adaptive policies chose different controls; the signal is added
afterward. Therefore variates are paired by index, not actions or resulting
observations. Policy-visible metadata discloses only `noise_model` and
`noise_scale_m` (`none`/0 or `gaussian_additive`/0.10); per-measurement
uncertainty is the scale. Seeds and pre-noise clean signals are never exposed.

Exact replay requires world seed/configuration, noise seed/configuration,
recorded actions in order, and the same implementation/runtime. Provenance
stores the seed and noise configuration/version; public artifacts store the
observations and declared metadata. Clean evaluator trajectories remain
available only to evaluator-side scoring.
