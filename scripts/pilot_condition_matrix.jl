using Falsify
using Printf

"""Exploratory DAL-123 pilot matrix. Never invoked by CI; writes no raw artifacts
outside a temporary directory. Pilot worlds are declared exploratory and disjoint
from the confirmatory seed set.

Model-independent non-degeneracy question: does each candidate primary condition
leave the co-primary endpoints discriminative for non-adaptive baselines, or does
every reasonable design collapse to the numerical floor (or the 1.0 failure cap)?
"""

const PILOT_WORLDS = (7122123, 7122124, 7122125)
const BUDGETS = (1, 2, 4, 8)
# Per-world seed rule, identical to the confirmatory derivation rule.
noise_seed_for(world_seed) = world_seed + 1_000_000
random_policy_seed_for(world_seed) = world_seed + 2_000_000

function main()
    rows = NamedTuple[]
    mktempdir() do store
        for world_seed in PILOT_WORLDS
            world = generate_world(world_seed)
            truth = evaluator_truth(world)
            for (condition, noise) in (("clean", CleanObservation()),
                    ("gaussian_0.10", GaussianObservationNoise(0.10)))
                noise_seed = condition == "clean" ? 0 : noise_seed_for(world_seed)
                for budget in BUDGETS
                    for (policy_name, policy) in (("random",
                            RandomPolicy(random_policy_seed_for(world_seed))),
                        ("fixed_design", FixedDesignPolicy()))
                        config = RunConfig(budget; observation_noise=noise,
                            noise_seed)
                        outcome = run_experiment(world, policy, config;
                            root=joinpath(@__DIR__, ".."))
                        path = write_run(store, outcome.public, outcome.provenance,
                            outcome.evaluator)
                        metrics = score_run(path)
                        push!(rows, (; world_seed, condition, budget, policy_name,
                            status=metrics.completion_status,
                            fit_status=String(metrics.fit_status),
                            parameter_error=metrics.parameter_error,
                            heldout_prediction_error=metrics.heldout_prediction_error,
                            raw_heldout_rmse_m=metrics.raw_heldout_rmse_m,
                            zeta=truth.damping_ratio, omega0=truth.natural_frequency,
                            zeta_error=metrics.zeta_error,
                            omega0_error=metrics.omega0_error,
                            interventions=metrics.interventions_used,
                            opportunities=metrics.decision_opportunities_used,
                            invalid=metrics.invalid_action_count))
                    end
                end
            end
        end
    end

    out = joinpath(@__DIR__, "..", "results", "derived")
    mkpath(out)
    csv = joinpath(out, "pilot-condition-matrix-dal123.csv")
    open(csv, "w") do io
        println(io, "world_seed,condition,budget,policy,status,fit_status," *
            "parameter_error,heldout_prediction_error,raw_heldout_rmse_m," *
            "zeta,omega0,zeta_error,omega0_error,interventions,opportunities,invalid")
        for r in rows
            println(io, join((r.world_seed, r.condition, r.budget, r.policy_name,
                r.status, r.fit_status, r.parameter_error,
                r.heldout_prediction_error, something(r.raw_heldout_rmse_m, ""),
                r.zeta, r.omega0, something(r.zeta_error, ""),
                something(r.omega0_error, ""), r.interventions, r.opportunities,
                r.invalid), ","))
        end
    end
    println("wrote ", csv, " (", length(rows), " runs)")

    # Compact per-condition summary for the report.
    for condition in ("clean", "gaussian_0.10"), budget in BUDGETS
        subset = filter(r -> r.condition == condition && r.budget == budget, rows)
        pes = [r.parameter_error for r in subset]
        preds = [r.heldout_prediction_error for r in subset]
        @printf("%-14s budget=%d  parameter_error=[%s]  heldout=[%s]\n",
            condition, budget,
            join((@sprintf("%.3e", x) for x in pes), " "),
            join((@sprintf("%.3e", x) for x in preds), " "))
    end
end

main()
