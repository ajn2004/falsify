# Exploratory, policy-independent v2 shortcut holdout and v3 finite-budget geometry.
using Falsify, Statistics, Random, JSON3
include(joinpath(@__DIR__, "..", "src", "evaluation", "V02Evaluation.jl"))
const E = V02Evaluation
const ROOT = normpath(joinpath(@__DIR__, ".."))
const TIMES = collect(range(0.0, 10.0; length=101))
const SIGMA = 0.05
const REPEATS = 3
const DISCOVERY_PER_CLASS = 8
const VALIDATION_PER_CLASS = 8
const ACTION_X = (-0.5, 0.0, 0.5)
const ACTION_V = (-0.5, 0.0, 0.5)
const DRIVE_GRID = ((0.0, 0.0), (0.25, 0.2), (0.25, 1.0), (0.25, 3.0),
    (0.5, 0.2), (0.5, 0.75), (0.5, 1.5), (0.5, 3.0),
    (-0.5, 0.2), (-0.5, 1.5), (-0.5, 3.0))
const BUDGETS = (1, 2, 4, 8)

function balanced_worlds(seed_range, per_class; version)
    selected = Dict("linear" => Any[], "duffing" => Any[])
    for seed in seed_range
        w = generate_duffing_world(seed; version)
        klass = string(w.truth.model_class)
        length(selected[klass]) < per_class && push!(selected[klass], w)
        all(length(selected[k]) == per_class for k in keys(selected)) && break
    end
    all(length(selected[k]) == per_class for k in keys(selected)) || error("class-balanced sample incomplete")
    vcat(selected["linear"], selected["duffing"])
end

function make_actions()
    unique([(x, v, a, iszero(a) ? 0.0 : f) for x in ACTION_X for v in ACTION_V for (a, f) in DRIVE_GRID])
end

function fit_record(truth, rows, sigma, action=nothing)
    cfg = E.V02EvaluatorConfig(structural_probes=((0.1,0.,0.,0.),(0.,0.,0.5,0.2),
        (0.5,0.,0.,0.),(0.,0.,0.5,0.3)), grid_points=5, max_iterations=500, tolerance=1e-7)
    lo = p -> E._objective(rows, (x, ts, z) -> E._simulate_struct(x, ts, z, 0.0), p)
    hi = p -> E._objective(rows, (x, ts, z) -> E._simulate_struct(x, ts, z[1:2], z[3]), p)
    sl, xl, rl = E._optimize(lo, [cfg.structural_zeta, cfg.structural_omega], cfg)
    sd, xd, rd = E._optimize(hi, [cfg.structural_zeta, cfg.structural_omega, cfg.structural_beta], cfg)
    result = (truth_class=string(truth.model_class), beta=truth.beta, zeta=truth.zeta,
        omega0=truth.omega0, action, fit_linear=String(sl), fit_duffing=String(sd),
        linear_score=nothing, duffing_score=nothing, delta_per_sample=nothing,
        selected_class="fit_failure", correct=false, selected_prediction_rmse=nothing)
    sl == :success && sd == :success || return result
    n = sum(length(r[3]) for r in rows)
    bic(rss, k) = begin
        total_rss = max(rss*n, eps(Float64))
        variance = sigma > 0 ? sigma^2 : total_rss/n
        (sigma > 0 ? total_rss/variance : n*log(max(variance, eps(Float64)))) + k*log(n)
    end
    bl, bd = bic(rl, 2), bic(rd, 3)
    selected = bl == bd ? "undetermined" : bl < bd ? "linear" : "duffing"
    prediction_rmse = nothing
    if selected != "undetermined"
        params, beta = selected == "linear" ? (xl, 0.0) : (xd[1:2], xd[3])
        ss, count = 0.0, 0
        for probe in cfg.structural_probes
            target = E._simulate_struct(collect(probe), TIMES, [truth.zeta, truth.omega0], truth.beta)
            prediction = E._simulate_struct(collect(probe), TIMES, params, beta)
            ss += sum(abs2, prediction .- target); count += length(target)
        end
        prediction_rmse = sqrt(ss/count)
    end
    merge(result, (linear_score=bl, duffing_score=bd, delta_per_sample=(bl-bd)/n,
        selected_class=selected, correct=selected==string(truth.model_class),
        selected_prediction_rmse=prediction_rmse))
end

function observe_rows(world, actions, sigma, noise_seed)
    truth = world.truth
    rows = Any[]
    for (i, action) in enumerate(actions)
        a = collect(action)
        clean = E._simulate_struct(a, TIMES, [truth.zeta, truth.omega0], truth.beta)
        rng = MersenneTwister(noise_seed + i)
        y = sigma == 0 ? clean : clean .+ sigma .* randn(rng, length(clean))
        push!(rows, (a, TIMES, y, Float64[]))
    end
    rows
end

function v2_shortcut_holdout()
    worlds = balanced_worlds(9_610_000:9_619_999, 12; version="2")
    action = (0.5, 0.5, 1.0, 0.2)
    records = Any[]
    for (wi, world) in enumerate(worlds), rep in 1:REPEATS
        rows = observe_rows(world, [action], SIGMA, 10_100_000 + 1_000wi + 10rep)
        push!(records, merge(fit_record(world.truth, rows, SIGMA, action),
            (world_seed=world.provenance.world_seed, noise_replicate=rep)))
    end
    (seeds=[w.provenance.world_seed for w in worlds], action, records)
end

function v3_action_map()
    worlds = balanced_worlds(9_620_000:9_629_999, DISCOVERY_PER_CLASS; version="3")
    actions = make_actions()
    records = Any[]
    for (wi, world) in enumerate(worlds), (ai, action) in enumerate(actions)
        clean_rows = observe_rows(world, [action], 0.0, 10_200_000 + 1_000wi + ai)
        clean_signal = sqrt(mean(abs2, clean_rows[1][3]))
        push!(records, merge(fit_record(world.truth, clean_rows, 0.0, action),
            (world_seed=world.provenance.world_seed, condition="clean_descriptive",
             signal_rms=clean_signal, signal_peak=maximum(abs, clean_rows[1][3]), sigma_over_signal_rms=0.0)))
        for rep in 1:REPEATS
            rows = observe_rows(world, [action], SIGMA, 10_300_000 + 100_000wi + 100ai + rep)
            push!(records, merge(fit_record(world.truth, rows, SIGMA, action),
                (world_seed=world.provenance.world_seed, condition="gaussian_0.05", noise_replicate=rep,
                 signal_rms=clean_signal, signal_peak=maximum(abs, clean_rows[1][3]),
                 sigma_over_signal_rms=clean_signal > 0 ? SIGMA/clean_signal : nothing)))
        end
    end
    (seeds=[w.provenance.world_seed for w in worlds], actions, records)
end

function random_schedule(world, seed, budget)
    task = public_task(world)
    limits = limits_for(task)
    policy = RandomPolicy(seed)
    [Falsify.next_action(policy, PublicState(policy_task(task), limits, (), budget-i+1, budget-i+1;
        action_schema=action_schema(world), policy_contract_profile=Falsify.policy_contract_profile(world))) for i in 1:budget]
end

function budget_schedules(world)
    limits = limits_for(public_task(world))
    single = fill(ExperimentAction(initial_displacement_m=0.5, initial_velocity_m_per_s=0.5,
        drive_acceleration_m_per_s2=0.5, drive_frequency_hz=0.2), 8)
    diverse_tuples = ((0.5,0.5,0.,0.),(-0.5,0.,0.,0.),(0.,-0.5,0.,0.),
        (0.5,0.5,0.5,0.2),(-0.5,0.5,-0.5,0.75),(0.5,-0.5,0.5,1.5),
        (-0.5,-0.5,-0.5,3.),(0.,0.,0.5,0.2))
    diverse = [ExperimentAction(initial_displacement_m=a[1], initial_velocity_m_per_s=a[2],
        drive_acceleration_m_per_s2=a[3], drive_frequency_hz=a[4]) for a in diverse_tuples]
    fixed = Falsify._fixed_design(limits)
    (; single, diverse, fixed)
end

function budget_validation()
    worlds = balanced_worlds(9_630_000:9_639_999, VALIDATION_PER_CLASS; version="3")
    records = Any[]
    for (wi, world) in enumerate(worlds)
        schedules = budget_schedules(world)
        policy_schedules = [("single_max_low_frequency", 1, schedules.single),
            ("diverse_open_loop", 1, schedules.diverse), ("fixed_design", 1, schedules.fixed)]
        for policyrep in 1:3
            push!(policy_schedules, ("random", policyrep,
                random_schedule(world, 10_400_000 + 10_000wi + policyrep, 8)))
        end
        for (strategy, design_rep, schedule) in policy_schedules, noise_rep in 1:REPEATS, budget in BUDGETS
            actions = [(a.initial_displacement_m, a.initial_velocity_m_per_s,
                a.drive_acceleration_m_per_s2, a.drive_frequency_hz) for a in schedule[1:budget]]
            rows = observe_rows(world, actions, SIGMA,
                10_500_000 + 100_000wi + 10_000design_rep + 100noise_rep)
            result = fit_record(world.truth, rows, SIGMA, nothing)
            push!(records, merge(result, (world_seed=world.provenance.world_seed,
                strategy, design_replicate=design_rep, noise_replicate=noise_rep, budget)))
        end
    end
    (seeds=[w.provenance.world_seed for w in worlds], records)
end

v2 = v2_shortcut_holdout()
action_map = v3_action_map()
budgets = budget_validation()
out = joinpath(ROOT, "results", "pilot-v0.2", "structural-v3-gate-v1", "diagnostic.json")
mkpath(dirname(out))
write(out, JSON3.write((designation="exploratory v2 shortcut holdout and v3 finite-noise action/budget gate",
    environment=(id="linear_vs_duffing_v0_2",candidate_version="3",x0_m=(-0.5,0.5),v0_m_per_s=(-0.5,0.5),
        drive_acceleration_m_per_s2=(-0.5,0.5),drive_frequency_hz=(0.0,3.0),duration_s=10.0,samples=101,
        zeta=DUFFING_ZETA_RANGE,omega0=DUFFING_OMEGA_RANGE,beta=DUFFING_BETA_RANGE),
    noise_sigma_m=SIGMA,repeated_noise_replicates=REPEATS,
    v2_shortcut_holdout=(truth_count=length(v2.seeds),class_counts=(linear=12,duffing=12),seeds=v2.seeds,
        action=v2.action,records=v2.records),
    v3_action_map=(truth_count=2DISCOVERY_PER_CLASS,class_counts=(linear=DISCOVERY_PER_CLASS,duffing=DISCOVERY_PER_CLASS),
        seeds=action_map.seeds,action_count=length(action_map.actions),actions=action_map.actions,records=action_map.records),
    v3_budget_validation=(truth_count=2VALIDATION_PER_CLASS,class_counts=(linear=VALIDATION_PER_CLASS,duffing=VALIDATION_PER_CLASS),
        seeds=budgets.seeds,budgets=BUDGETS,strategies=("single_max_low_frequency","diverse_open_loop","fixed_design","random"),
        random_design_replicates=3,noise_replicates=REPEATS,records=budgets.records))))
println("wrote ", out, "; v2 shortcut truths=", length(v2.seeds),
    "; v3 action map=", length(action_map.seeds), " truths × ", length(action_map.actions),
    " actions; v3 budget truths=", length(budgets.seeds))
