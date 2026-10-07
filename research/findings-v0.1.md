# Falsify V0.1 Confirmatory Findings

## Protocol

Executed protocol: `falsify-v0.1-prereg-4`. H1/H2 use gaussian_0.10 only; clean is descriptive apparatus validation. Endpoints are the persisted frozen evaluator scores. Paired-world bootstrap: 10,000 resamples, seed 9123999, percentile two-sided 95% intervals.

## Execution integrity

Attempt-level population reconciles to 140 attempts: 109 scientifically scored, 4 behavioral failures, and 31 infrastructure-unscored attempts. Retries were resolved only after retaining all attempt rows. No experiment/provider was invoked by this analysis.

## Analysis population

Primary preregistered worlds: 30. Retained matched blocks: 26. Excluded blocks: 4. Infrastructure-triggering slot(s):

- World `8123003`: `scientist` terminal infrastructure after retry.
- World `8123013`: `scientist` terminal infrastructure after retry.
- World `8123023`: `scientist` terminal infrastructure after retry.
- World `8123028`: `scientist` terminal infrastructure after retry.

All terminal infrastructure slots (including clean descriptive slots):

- `clean` world `8123003`, `scientist`: retry1 `7f91e9f2-7ce6-471f-8396-c81fa2161e81` remained infrastructure.
- `clean` world `8123004`, `scientist`: retry1 `64e9f169-2c66-45d1-a991-9747e137037a` remained infrastructure.
- `clean` world `8123005`, `scientist`: retry1 `0d57d37f-abe1-4e0a-8090-4aa3aafe28d5` remained infrastructure.
- `clean` world `8123006`, `scientist`: retry1 `9527d268-a724-441b-bb5c-73063c077db3` remained infrastructure.
- `clean` world `8123007`, `scientist`: retry1 `8c14c368-b7b6-48ab-b752-1ce0509400e8` remained infrastructure.
- `clean` world `8123009`, `scientist`: retry1 `ef66cc1a-a5e5-429d-bdb2-d47215e3d10a` remained infrastructure.
- `clean` world `8123010`, `scientist`: retry1 `331d8556-6378-4f81-a6dd-5b99bfa4caf1` remained infrastructure.
- `gaussian_0.10` world `8123003`, `scientist`: retry1 `d92e4b71-b482-408b-8edc-3976571e65f8` remained infrastructure.
- `gaussian_0.10` world `8123013`, `scientist`: retry1 `6190ba2e-e9d2-462b-9051-e2765ea6c5a1` remained infrastructure.
- `gaussian_0.10` world `8123023`, `scientist`: retry1 `b37a4f60-768d-4a91-99b3-2a080a2f1b39` remained infrastructure.
- `gaussian_0.10` world `8123028`, `scientist`: retry1 `ff7de49a-e82b-4729-ad54-e2cb41ea69d9` remained infrastructure.

## H1: Scientist vs Random

| Endpoint | N worlds | Scientist mean | Baseline mean | Mean paired difference | 95% CI low | 95% CI high | Superiority? |
|---|---:|---:|---:|---:|---:|---:|---|
| parameter_error | 26 | 0.043481384992031656 | 0.004758576693380627 | 0.03872280829865105 | -0.001059500683295039 | 0.11614371117390494 | No |
| prediction_error | 26 | 0.039260863195671 | 0.000834339420810683 | 0.03842652377486032 | -0.00023010313013364494 | 0.11543661042643666 | No |

**Overall hypothesis: not supported.** Both co-primary endpoint intervals must independently lie below zero.

## H2: Scientist vs Fixed Design

| Endpoint | N worlds | Scientist mean | Baseline mean | Mean paired difference | 95% CI low | 95% CI high | Superiority? |
|---|---:|---:|---:|---:|---:|---:|---|
| parameter_error | 26 | 0.043481384992031656 | 0.00397278289490108 | 0.0395086020971306 | -0.0005917931053886504 | 0.11732819050251223 | No |
| prediction_error | 26 | 0.039260863195671 | 0.0007748461024942815 | 0.038486017093176735 | -0.0001225941715255722 | 0.11546676062260415 | No |

**Overall hypothesis: not supported.** Both co-primary endpoint intervals must independently lie below zero.

## gaussian_0.10 policy performance (descriptive)

These are logical-slot distributions; Scientist is n=26, the paired analysis population. Baseline descriptives include all observed slots; the confirmatory contrasts use only the retained matched blocks.

| Policy | Endpoint | N | Mean | Median | Q25 | Q75 |
|---|---|---:|---:|---:|---:|---:|
| random | parameter_error | 30 | 0.0046921939848212045 | 0.0023584397107279196 | 0.0015267815747835151 | 0.007784666416056211 |
| random | prediction_error | 30 | 0.0008142754035800933 | 0.0006218947815318966 | 0.00044373067535891905 | 0.0010001877348014775 |
| fixed_design | parameter_error | 30 | 0.004038317770121892 | 0.0026330852253123845 | 0.0019714085307562974 | 0.004017348718337278 |
| fixed_design | prediction_error | 30 | 0.0007484283666069489 | 0.00063388290225952 | 0.0004485312608156159 | 0.0008512001763252332 |
| scientist | parameter_error | 26 | 0.04348138499203168 | 0.002266486141860774 | 0.001643799137727541 | 0.008803249708984372 |
| scientist | prediction_error | 26 | 0.039260863195671014 | 0.0006082382918098654 | 0.00042762569427266155 | 0.0012574103069582798 |

Success threshold is `parameter_error ≤ 0.10`; counts are descriptive in `success_summary.csv`.


## Clean descriptive condition

Clean results are descriptive only and do not enter H1/H2.

| Policy | Endpoint | N | Mean | Median |
|---|---|---:|---:|---:|
| random | parameter_error | 10 | 1.6219584742792506e-9 | 1.5629205749649166e-9 |
| random | prediction_error | 10 | 4.5947633152818127e-10 | 4.226305968461268e-10 |
| fixed_design | parameter_error | 10 | 1.6219584563623355e-9 | 1.5629205749649166e-9 |
| fixed_design | prediction_error | 10 | 4.5947624218141367e-10 | 4.226305968461268e-10 |
| scientist | parameter_error | 3 | 1.0 | 1.0 |
| scientist | prediction_error | 3 | 1.0 | 1.0 |

Success at parameter_error ≤ 0.10:

| Condition | Policy | N scored | Successes | Rate |
|---|---|---:|---:|---:|
| gaussian_0.10 | random | 30 | 30 | 1.0 |
| gaussian_0.10 | fixed_design | 30 | 30 | 1.0 |
| gaussian_0.10 | scientist | 26 | 25 | 0.9615384615384616 |
| clean | random | 10 | 10 | 1.0 |
| clean | fixed_design | 10 | 10 | 1.0 |
| clean | scientist | 3 | 0 | 0.0 |

Clean-vs-noisy means are also in `clean_noisy_descriptive.csv`. These remain descriptive; clean results do not enter H1/H2.


## Behavioral and infrastructure failures

| Condition | Policy | Completed | Behavioral | First infra | Recovered retry | Terminal infra | Invalid actions | Decision opportunities |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| gaussian_0.10 | random | 30 | 0 | 0 | 0 | 0 | 0 | 240 |
| gaussian_0.10 | fixed_design | 30 | 0 | 0 | 0 | 0 | 0 | 240 |
| gaussian_0.10 | scientist | 25 | 1 | 12 | 8 | 4 | 0 | 203 |
| clean | random | 10 | 0 | 0 | 0 | 0 | 0 | 80 |
| clean | fixed_design | 10 | 0 | 0 | 0 | 0 | 0 | 80 |
| clean | scientist | 0 | 3 | 8 | 1 | 7 | 0 | 9 |

Behavioral-failure slots are retained with persisted score 1.0. They occurred at:

- `gaussian_0.10` world `8123002`, `scientist`; primary matched block retained: true.
- `clean` world `8123001`, `scientist`; primary matched block retained: false.
- `clean` world `8123002`, `scientist`; primary matched block retained: false.
- `clean` world `8123008`, `scientist`; primary matched block retained: false.

## Cost and latency

Reconstructed from persisted operational metadata: 344 requests, 2773398 input tokens, 74739 output tokens, $0.7709560399999997 recorded cost, 1688.6768774986267 s summed recorded latency. These totals exactly match the executor summary. ScientistPolicy requests are included across both conditions and all attempts. Per-policy details and the explicit count of missing per-request metadata are in `operational_summary.csv` and `operational_metadata_missing.csv` respectively. Missing values were not recoded to zero.


## Exploratory efficiency observations

Run-level final scores are paired with valid interventions and decision opportunities in `run_metrics.csv`; `intervention-use.svg` is descriptive. The repository has no frozen prefix-scoring mechanism. Full prefix error trajectories require a separately specified evaluator extension; no new estimator was introduced here.


## Limitations

This is one controlled damped-oscillator task, one model treatment, and one scientist repetition per preregistered world. It does not establish general scientific reasoning or adaptive superiority over an LLM open-loop design. Infrastructure exclusions reduce the matched primary population.


## Exact reproducibility commands

```bash
julia +1.12.7 --project=. scripts/analyze_confirmatory_v0_1.jl
```

