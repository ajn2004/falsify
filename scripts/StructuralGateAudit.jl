module StructuralGateAudit

using JSON3, SHA, Random

export audit, audit_file
const AUDIT_VERSION = "3"
const CLASSES = ("linear", "duffing")
const OUTCOMES = ("linear", "duffing", "undetermined", "fit_failure")
const BOOTSTRAP_DRAWS = 10_000
const BOOTSTRAP_SEED = 20_261_012

getv(x, k) = x isa AbstractDict ? x[string(k)] : getproperty(x, Symbol(k))
asint(x, what) = x isa Integer ? Int(x) : throw(ArgumentError("$what must be an integer"))
asstr(x, what) = x isa AbstractString ? String(x) : throw(ArgumentError("$what must be a string"))
median_value(xs) = begin
    ys=sort!(collect(xs)); n=length(ys)
    n == 0 ? nothing : isodd(n) ? ys[(n+1)÷2] : (ys[n÷2] + ys[n÷2+1]) / 2
end

function wilson(successes, n; z=1.959963984540054)
    n == 0 && return (lower=nothing, upper=nothing)
    p = successes / n
    denom = 1 + z^2 / n
    center = (p + z^2 / (2n)) / denom
    half = z * sqrt(p * (1-p) / n + z^2 / (4n^2)) / denom
    (lower=max(0.0, center-half), upper=min(1.0, center+half))
end

function world_bootstrap(values; draws=BOOTSTRAP_DRAWS, seed=BOOTSTRAP_SEED)
    n = length(values)
    n > 0 || return (lower=nothing, upper=nothing)
    rng = MersenneTwister(seed)
    estimates = Vector{Float64}(undef, draws)
    for i in eachindex(estimates)
        sample = rand(rng, 1:n, n)
        estimates[i] = sum(values[j] for j in sample) / n
    end
    sort!(estimates)
    (lower=estimates[ceil(Int, 0.025draws)], upper=estimates[ceil(Int, 0.975draws)])
end

function audit(records; strategies, world_seeds, design_replicates, budgets,
        noise_replicates, class_counts, metadata=(;), source_sha256=nothing)
    raw_strategies=map(x->asstr(x,"strategy"),collect(strategies))
    raw_seeds=map(x->asint(x,"world seed"),collect(world_seeds))
    raw_budgets=map(x->asint(x,"budget"),collect(budgets))
    raw_noise=map(x->asint(x,"noise replicate"),collect(noise_replicates))
    length(unique(raw_strategies))==length(raw_strategies) || throw(ArgumentError("duplicate declared strategies"))
    length(unique(raw_seeds))==length(raw_seeds) || throw(ArgumentError("duplicate declared world seeds"))
    length(unique(raw_budgets))==length(raw_budgets) || throw(ArgumentError("duplicate declared budgets"))
    length(unique(raw_noise))==length(raw_noise) || throw(ArgumentError("duplicate declared noise replicates"))
    strategies = sort!(raw_strategies)
    seeds = sort!(raw_seeds)
    budget_ids = sort!(raw_budgets)
    noise_ids = sort!(raw_noise)
    !isempty(strategies) && !isempty(seeds) && !isempty(budget_ids) && !isempty(noise_ids) ||
        throw(ArgumentError("declared audit matrix dimensions must be nonempty"))
    expected_designs = Dict{String,Vector{Int}}()
    for (strategy, ids) in design_replicates
        design_ids=map(x->asint(x,"design replicate"),collect(ids))
        length(unique(design_ids))==length(design_ids) || throw(ArgumentError("duplicate declared design replicates"))
        expected_designs[asstr(strategy, "strategy")] = sort!(design_ids)
        isempty(design_ids) && throw(ArgumentError("design replicate IDs must be nonempty"))
    end
    Set(keys(expected_designs)) == Set(strategies) || throw(ArgumentError("design replicate manifest must declare exactly each strategy"))

    expected_keys = Set{NTuple{5,Any}}()
    for strategy in strategies, seed in seeds, design in expected_designs[strategy], budget in budget_ids, noise in noise_ids
        push!(expected_keys, (strategy, seed, design, budget, noise))
    end
    seen = Set{NTuple{5,Any}}()
    normalized = Any[]
    rows = collect(records)
    for r in rows
        strategy = asstr(getv(r, "strategy"), "strategy")
        seed = asint(getv(r, "world_seed"), "world_seed")
        design = asint(getv(r, "design_replicate"), "design_replicate")
        noise = asint(getv(r, "noise_replicate"), "noise_replicate")
        budget = asint(getv(r, "budget"), "budget")
        key = (strategy, seed, design, budget, noise)
        key in expected_keys || throw(ArgumentError("unexpected observation combination $key"))
        key in seen && throw(ArgumentError("duplicate observation for $key"))
        push!(seen, key)

        klass = asstr(getv(r, "truth_class"), "truth_class")
        klass in CLASSES || throw(ArgumentError("unknown truth class $klass"))
        selected = getv(r, "selected_class")
        selected = selected === nothing ? "undetermined" : asstr(selected, "selected_class")
        fitl = getv(r, "fit_linear"); fitd = getv(r, "fit_duffing")
        converged = fitl == "success" && fitd == "success"
        selected in ("linear", "duffing", "undetermined", "fit_failure") || throw(ArgumentError("invalid selected class $selected"))
        if hasproperty(r, :correct) || (r isa AbstractDict && haskey(r, "correct"))
            correct = getv(r, "correct")
            if converged && correct !== nothing
                Bool(correct) == (selected == klass) || throw(ArgumentError("correct flag disagrees with selected class"))
            end
        end
        pred = getv(r, "selected_prediction_rmse")
        pred !== nothing && (!(pred isa Real) || !isfinite(pred) || pred < 0) &&
            throw(ArgumentError("invalid selected prediction RMSE"))
        push!(normalized, (strategy, seed, design, budget, klass, noise, selected,
            converged, pred === nothing ? nothing : Float64(pred), String(fitl), String(fitd)))
    end
    missing = setdiff(expected_keys, seen)
    isempty(missing) || throw(ArgumentError("incomplete declared audit matrix: $(length(missing)) combinations missing; first=$(first(sort!(collect(missing))))"))
    length(seen) == length(expected_keys) || throw(ArgumentError("audit matrix size mismatch"))

    world_classes = Dict{Int,String}()
    grouped = Dict{Tuple{String,Int,Int,Int},Vector{Any}}()
    for r in normalized
        seed, klass = r[2], r[5]
        haskey(world_classes, seed) && world_classes[seed] != klass &&
            throw(ArgumentError("truth class inconsistent for physical world $seed"))
        world_classes[seed] = klass
        push!(get!(grouped, r[1:4], Any[]), r)
    end
    observed_counts=Dict(c=>count(==(c),values(world_classes)) for c in CLASSES)
    declared_counts=Dict(c=>asint(getv(class_counts,c),"declared $c world count") for c in CLASSES)
    observed_counts==declared_counts || throw(ArgumentError("truth-class counts disagree with declared world manifest"))
    allgroups = Dict{Tuple{String,Int,Int,Int},Vector{Any}}()
    for (key, group) in grouped
        sort!(group; by=r->r[6])
        [r[6] for r in group] == noise_ids || throw(ArgumentError("inconsistent noise replicate IDs for $key"))
        length(unique(r[5] for r in group)) == 1 || throw(ArgumentError("truth class changed within $key"))
        allgroups[key] = group
    end

    summary = Any[]
    for strategy in strategies, budget in budget_ids
        selected_groups = sort!([(key, group) for (key, group) in allgroups if key[1] == strategy && key[4] == budget];
            by=x->(x[1][2], x[1][3]))
        confusion = Dict(c=>Dict(o=>0 for o in OUTCOMES) for c in CLASSES)
        group_outcomes = Dict{Tuple{Int,Int},String}()
        failed_observations = 0
        failures = 0
        for (key, group) in selected_groups
            klass = group[1][5]
            converged = all(r->r[8], group)
            failed_observations += count(r->!r[8], group)
            winner = if !converged
                failures += 1
                "fit_failure"
            else
                votes = Dict(o=>count(r->r[7] == o, group) for o in ("linear","duffing","undetermined"))
                top = maximum(values(votes)); best = [o for o in ("linear","duffing","undetermined") if votes[o] == top]
                length(best) == 1 ? only(best) : "undetermined"
            end
            confusion[klass][winner] += 1 # one outcome per world-design schedule
            group_outcomes[(key[2],key[3])] = winner
        end
        class_accuracy = Any[]
        for (ci, klass) in enumerate(CLASSES)
            class_seeds = [seed for seed in seeds if world_classes[seed] == klass]
            # Each world's score averages its design replicates first; worlds then have equal weight.
            world_fractions = [sum(group_outcomes[(seed,design)] == klass for design in expected_designs[strategy]) /
                length(expected_designs[strategy]) for seed in class_seeds]
            bootstrap = world_bootstrap(world_fractions; seed=BOOTSTRAP_SEED + 100budget + ci)
            ensemble_outcomes = String[]
            for seed in class_seeds
                votes = Dict(o=>count(design->group_outcomes[(seed,design)] == o, expected_designs[strategy]) for o in OUTCOMES)
                top = maximum(values(votes)); best = [o for o in OUTCOMES if votes[o] == top]
                push!(ensemble_outcomes, length(best) == 1 ? only(best) : "undetermined")
            end
            ensemble_correct = count(==(klass), ensemble_outcomes)
            push!(class_accuracy, (class=klass, distinct_physical_worlds=length(class_seeds),
                equal_world_mean_correct_design_fraction=isempty(world_fractions) ? nothing : sum(world_fractions)/length(world_fractions),
                per_world_correct_design_fractions=world_fractions,
                world_cluster_bootstrap_95pct=(lower=bootstrap.lower, upper=bootstrap.upper,
                    draws=BOOTSTRAP_DRAWS, seed=BOOTSTRAP_SEED + 100budget + ci),
                design_outcome_majority=(aggregation_level=length(expected_designs[strategy]) > 1 ?
                        "majority across independent schedules; descriptive ensemble only" : "single schedule outcome",
                    correct_worlds=ensemble_correct, distinct_worlds=length(class_seeds),
                    wilson_95pct=wilson(ensemble_correct,length(class_seeds)))))
        end
        preds = [r[9] for (_,g) in selected_groups for r in g if r[8] && r[9] !== nothing]
        missing_preds = count(r->r[8] && r[9] === nothing, (r for (_,g) in selected_groups for r in g))
        push!(summary, (strategy, budget, distinct_physical_worlds=length(seeds),
            design_replicates=length(expected_designs[strategy]), world_design_groups=length(selected_groups),
            noise_replicates=length(noise_ids), class_conditional_confusion_world_design_groups=confusion,
            class_accuracy_by_physical_world=class_accuracy, nonconvergent_world_design_groups=failures,
            nonconvergent_observation_rows=failed_observations,
            selected_prediction_rmse=(aggregation_level="converged observation rows only",
                observation_rows_with_value=length(preds), observation_rows_total=length(selected_groups)*length(noise_ids),
                missing_prediction_converged_observation_rows=missing_preds,
                excluded_nonconvergent_observation_rows=failed_observations, median_m=median_value(preds))))
    end
    (audit_version=AUDIT_VERSION, source_sha256, metadata, summary=summary)
end

function audit_file(input::AbstractString; output=nothing)
    bytes = read(input)
    d = JSON3.read(bytes)
    v = d.v3_budget_validation
    strategies = String.(collect(v.strategies))
    designs = Dict(s => (s == "random" ? collect(1:Int(v.random_design_replicates)) : [1]) for s in strategies)
    noise_ids = collect(1:Int(v.noise_replicates))
    meta = (designation="derived exploratory audit; not independent validation",
        source=relpath(input, normpath(joinpath(@__DIR__, ".."))), source_designation=String(d.designation),
        environment=d.environment, noise_sigma_m=Float64(d.noise_sigma_m),
        seed_provenance=(world_seeds=sort!(Int.(collect(v.seeds))), class_counts=v.class_counts,
            validation_seed_range=extrema(Int.(collect(v.seeds)))),
        evaluator=(score_version="v0.2-score-1", budget_values=v.budgets, strategies=v.strategies,
            design_replicates=designs, noise_replicates=noise_ids,
            optimizer=(grid_points=5, max_iterations=500, tolerance=1e-7),
            schedule=(duration_s=10.0, samples=101, sigma_m=Float64(d.noise_sigma_m))),
        random_schedule_estimand="equal-world mean of correct fractions over sampled independent schedules; physical-world cluster bootstrap")
    result = audit(v.records; strategies, world_seeds=v.seeds, design_replicates=designs,
        budgets=v.budgets, noise_replicates=noise_ids, class_counts=v.class_counts,
        metadata=meta, source_sha256=bytes2hex(sha256(bytes)))
    output === nothing || write(output, JSON3.write(result))
    result
end

end
