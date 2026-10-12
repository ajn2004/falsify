# Policy-independent structural information map for Duffing environment v2.
using Falsify, Statistics, Random, JSON3
include(joinpath(@__DIR__, "..", "src", "evaluation", "V02Evaluation.jl"))
const E = V02Evaluation
const ROOT = normpath(joinpath(@__DIR__, ".."))
const SEED_RANGE = 9_590_000:9_599_999
const PER_CLASS = 8
const TIMES = collect(range(0.0, 10.0; length=101))
const REPEATS = 3
const SIGMA = 0.05
const X0S = (-0.5, 0.0, 0.5)
const V0S = (-0.5, 0.0, 0.5)
const DRIVES = ((0.0, 0.0), (0.5, 0.2), (0.5, 1.0), (0.5, 2.5),
    (1.0, 0.2), (1.0, 0.5), (1.0, 1.0), (1.0, 2.5), (-1.0, 1.0))

function balanced_truths()
    selected = Dict("linear" => Any[], "duffing" => Any[])
    for seed in SEED_RANGE
        w = generate_duffing_world(seed)
        c = string(w.truth.model_class)
        length(selected[c]) < PER_CLASS && push!(selected[c], w)
        all(length(selected[k]) == PER_CLASS for k in keys(selected)) && break
    end
    all(length(selected[k]) == PER_CLASS for k in keys(selected)) || error("fresh truth sample incomplete")
    vcat(selected["linear"], selected["duffing"])
end

function legal_actions()
    actions = NTuple{4,Float64}[]
    for x in X0S, v in V0S, (a, f) in DRIVES
        push!(actions, (x, v, a, a == 0.0 ? 0.0 : f))
    end
    unique(actions)
end

function evaluate(world, action, sigma, repetition, truth_index, action_index, cfg)
    t = TIMES
    a = collect(action)
    truth = world.truth
    clean = E._simulate_struct(a, t, [truth.zeta, truth.omega0], truth.beta)
    rng = MersenneTwister(9_600_000 + 100_000truth_index + 100action_index + repetition)
    y = sigma == 0 ? clean : clean .+ sigma .* randn(rng, length(clean))
    rows = [(a, t, y, Float64[])]
    # Keep the same objective signature while separately fitting β as a nuisance parameter.
    lo = p -> E._objective(rows, (x, ts, z) -> E._simulate_struct(x, ts, z, 0.0), p)
    do_ = p -> E._objective(rows, (x, ts, z) -> E._simulate_struct(x, ts, z[1:2], z[3]), p)
    sl, xl, rl = E._optimize(lo, [cfg.structural_zeta, cfg.structural_omega], cfg)
    sd, xd, rd = E._optimize(do_, [cfg.structural_zeta, cfg.structural_omega, cfg.structural_beta], cfg)
    n = length(y)
    result = (truth_class=string(truth.model_class), beta=truth.beta, zeta=truth.zeta,
        omega0=truth.omega0, action=action, noise=sigma == 0 ? "clean" : "gaussian_0.05",
        repetition=repetition, fit_linear=String(sl), fit_duffing=String(sd),
        signal_rms=sqrt(mean(abs2, clean)), signal_peak=maximum(abs, clean),
        sigma_over_signal_rms=sqrt(mean(abs2, clean)) > 0 ? sigma / sqrt(mean(abs2, clean)) : nothing,
        linear_score=nothing, duffing_score=nothing, delta_per_sample=nothing,
        selected_class="fit_failure", correct=false, selected_prediction_rmse=nothing)
    sl == :success && sd == :success || return result
    bic(rss, k) = begin
        r = max(rss * n, eps(Float64))
        s2 = sigma > 0 ? sigma^2 : r / n
        (sigma > 0 ? r / s2 : n * log(max(s2, eps(Float64)))) + k * log(n)
    end
    bl, bd = bic(rl, 2), bic(rd, 3)
    delta = (bl - bd) / n
    selected = bl == bd ? "undetermined" : bl < bd ? "linear" : "duffing"
    pred_rmse = nothing
    if selected != "undetermined"
        params, beta = selected == "linear" ? (xl, 0.0) : (xd[1:2], xd[3])
        ss = 0.0
        count = 0
        for probe in cfg.structural_probes
            target = E._simulate_struct(collect(probe), t, [truth.zeta, truth.omega0], truth.beta)
            pred = E._simulate_struct(collect(probe), t, params, beta)
            ss += sum(abs2, pred .- target)
            count += length(target)
        end
        pred_rmse = sqrt(ss / count)
    end
    merge(result, (linear_score=bl, duffing_score=bd, delta_per_sample=delta,
        selected_class=selected, correct=selected == string(truth.model_class),
        selected_prediction_rmse=pred_rmse))
end

truths, actions = balanced_truths(), legal_actions()
cfg = E.V02EvaluatorConfig(grid_points=5, max_iterations=500, tolerance=1e-7)
rows = Any[]
for (ti, world) in enumerate(truths), (ai, action) in enumerate(actions)
    push!(rows, evaluate(world, action, 0.0, 0, ti, ai, cfg))
    for rep in 1:REPEATS
        push!(rows, evaluate(world, action, SIGMA, rep, ti, ai, cfg))
    end
end

out = joinpath(ROOT, "results", "pilot-v0.2", "structural-action-map-v8", "diagnostic.json")
mkpath(dirname(out))
write(out, JSON3.write((designation="exploratory policy-independent v2 finite-noise nuisance-refit action map",
    environment_version="2", truth_seeds=[w.provenance.world_seed for w in truths],
    class_counts=(linear=PER_CLASS, duffing=PER_CLASS), action_count=length(actions),
    repeats_per_noisy_action_truth=REPEATS, noise_conditions=(("clean", 0.0), ("gaussian_0.05", SIGMA)),
    schedule=(duration_s=10.0, samples=101, interval_s=0.1),
    grid=(x0_m=X0S, v0_m_per_s=V0S, drive_settings=DRIVES),
    optimizer=(grid_points=cfg.grid_points, max_iterations=cfg.max_iterations, tolerance=cfg.tolerance),
    method="same-sample linear/Duffing nuisance fits; known-sigma Gaussian BIC; selected-model prediction error on frozen v2 probes",
    rows)))
println("wrote ", out, " (", length(actions), " actions, ", length(rows), " truth/noise rows)")
