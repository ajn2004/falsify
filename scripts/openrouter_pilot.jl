using Falsify
using JSON3

"""One seeded, non-confirmatory live smoke. Never invoked by CI."""
function main()
    isempty(strip(get(ENV, "OPENROUTER_API_KEY", ""))) && error("Set OPENROUTER_API_KEY to run the OpenRouter pilot")
    config_path = joinpath(@__DIR__, "..", "configs", "v0.1-frontier.toml")
    config = load_openrouter_config(config_path)
    world = generate_world(7122122)
    policy = ScientistPolicy(OpenRouterClient(config))
    outcome = run_experiment(world, policy,
        RunConfig(1; max_decision_opportunities=2); repetition_id="pilot-dal122")
    println("NON-CONFIRMATORY PILOT — exploratory only")
    println("run_id: ", outcome.public.run_id)
    for event in outcome.public.events
        println("decision ", event.sequence, ": action=", event.requested_action,
            " validation=", event.validation_code, " failure=", event.failure === nothing ? nothing : event.failure.code,
            " metadata=", event.operational_metadata)
    end
    println("status: ", outcome.public.status)
    provenance = capture_provenance(outcome.public.run_id; root=joinpath(@__DIR__, ".."), world,
        repetition_id="pilot-dal122", configuration=(pilot=true, protocol_phase="exploratory",
            policy=policy_configuration(policy), max_decision_opportunities=2, retry_allowance=1))
    path = write_run(joinpath(@__DIR__, "..", "results", "raw"), outcome.public,
        provenance, outcome.evaluator)
    println("artifact: ", path)
end

main()
