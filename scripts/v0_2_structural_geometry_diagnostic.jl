# Policy-independent structural information map. No policies are instantiated.
using Falsify, Statistics, JSON3, Random
include(joinpath(@__DIR__, "..", "src", "evaluation", "V02Evaluation.jl"))
const E = V02Evaluation

const ROOT = normpath(joinpath(@__DIR__, ".."))
const SEED_RANGE = 9_570_000:9_579_999
const TRUTHS_PER_CLASS = 8
const X0S = (-0.5, 0.0, 0.5)
const V0S = (-0.5, 0.0, 0.5)
const DRIVES = ((0.0, 0.0), (0.5, 0.5), (1.0, 0.5), (0.5, 1.0),
    (1.0, 1.0), (0.5, 2.0), (1.0, 2.5), (-1.0, 1.0),
    (1.0, 0.15), (1.0, 0.20), (1.0, 0.25), (1.0, 0.30))
const NOISES = (("clean", 0.0), ("gaussian_0.05", 0.05))
const TIMES = collect(range(0.0, 10.0; length=101))

function sample_truths()
    selected = Dict("linear" => Any[], "duffing" => Any[])
    for seed in SEED_RANGE
        world = generate_duffing_world(seed)
        klass = string(world.truth.model_class)
        length(selected[klass]) < TRUTHS_PER_CLASS && push!(selected[klass], world)
        all(length(selected[k]) == TRUTHS_PER_CLASS for k in keys(selected)) && break
    end
    all(length(selected[k]) == TRUTHS_PER_CLASS for k in keys(selected)) || error("truth sampling incomplete")
    vcat(selected["linear"], selected["duffing"])
end

function action_grid()
    actions = NTuple{4,Float64}[]
    for x in X0S, v in V0S, (amp, freq) in DRIVES
        amp == 0.0 ? push!(actions, (x, v, 0.0, 0.0)) : push!(actions, (x, v, amp, freq))
    end
    unique(actions)
end

function fit_scores(world, action, sigma, noise_seed)
    clean = duffing_observe(world, ExperimentAction(initial_displacement_m=action[1],
        initial_velocity_m_per_s=action[2], drive_acceleration_m_per_s2=action[3],
        drive_frequency_hz=action[4]))
    rng = MersenneTwister(noise_seed)
    y = clean.displacement .+ sigma .* randn(rng, length(clean.displacement))
    rows = [(collect(action), TIMES, y, Float64[])]
    cfg = E.V02EvaluatorConfig(grid_points=5, max_iterations=120, tolerance=1e-7)
    linear_obj = p -> E._objective(rows, (a,t,z)->E._simulate_struct(a,t,z,0.0), p)
    duffing_obj = p -> E._objective(rows, (a,t,z)->E._simulate_struct(a,t,z[1:2],z[3]), p)
    sl, _, rl = E._optimize(linear_obj, [cfg.structural_zeta,cfg.structural_omega], cfg)
    sd, _, rd = E._optimize(duffing_obj, [cfg.structural_zeta,cfg.structural_omega,cfg.structural_beta], cfg)
    sl == :success && sd == :success || return (ok=false, delta=missing, selected="fit_failure")
    n = length(y)
    bic(rss,k) = begin
        r=max(rss*n,eps(Float64)); s2=sigma>0 ? sigma^2 : r/n
        (sigma>0 ? r/s2 : n*log(max(s2,eps(Float64)))) + k*log(n)
    end
    bl, bd = bic(rl,2), bic(rd,3)
    (ok=true, delta=(bl-bd)/n, selected=bl==bd ? "undetermined" : bl<bd ? "linear" : "duffing")
end

truths, actions = sample_truths(), action_grid()
rows = Any[]
for envelope in ((0.5,0.5),)
    # Report action-level information for each legal point in this public envelope.
    legal = filter(a -> abs(a[1]) <= envelope[1] && abs(a[2]) <= envelope[2], actions)
    for action in legal, (noise_label,sigma) in NOISES
        ds=Float64[]; class_ds=Dict("linear"=>Float64[],"duffing"=>Float64[]); correct=Bool[]; failures=0
        for (i,world) in enumerate(truths)
            fit=fit_scores(world, action, sigma, 9_580_000 + i*10_000 + round(Int, (action[1]+2)*100 + (action[2]+2)*10 + abs(action[3])*3 + action[4]))
            if fit.ok
                push!(ds,fit.delta); push!(class_ds[string(world.truth.model_class)],fit.delta)
                push!(correct,fit.selected==string(world.truth.model_class))
            else
                failures+=1
            end
        end
        push!(rows, (envelope_displacement_m=envelope[1], envelope_velocity_m_per_s=envelope[2],
            x0=action[1],v0=action[2],drive_acceleration=action[3],drive_frequency_hz=action[4],
            noise=noise_label,truths=length(truths),fit_failures=failures,
            median_delta_per_sample=isempty(ds) ? nothing : median(ds),
            linear_truth_median_delta=isempty(class_ds["linear"]) ? nothing : median(class_ds["linear"]),
            duffing_truth_median_delta=isempty(class_ds["duffing"]) ? nothing : median(class_ds["duffing"]),
            recovery=isempty(correct) ? nothing : mean(correct)))
    end
end

out=joinpath(ROOT,"results","pilot-v0.2","structural-geometry-v7","diagnostic.json")
mkpath(dirname(out))
write(out,JSON3.write((designation="exploratory policy-independent nuisance-refit structural diagnostic",
    truth_seeds=[w.provenance.world_seed for w in truths],class_counts=(linear=TRUTHS_PER_CLASS,duffing=TRUTHS_PER_CLASS),
    grid=(x0_m=X0S,v0_m_per_s=V0S,drive_settings=DRIVES),noise_conditions=NOISES,
    method="single-intervention linear and Duffing fits after nuisance refitting; BIC difference per sample",
    result_rows=rows)))
println("wrote $out (",length(rows)," action/noise/envelope rows)")
