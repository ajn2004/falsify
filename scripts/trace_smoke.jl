using Falsify

struct TraceScientist <: AbstractModelClient
    responses::Vector{String}
    calls::Base.RefValue{Int}
end

function Falsify.request(client::TraceScientist, request::ModelRequest)
    client.calls[] += 1
    println("\nPOLICY REQUEST")
    show(stdout, request)
    println()
    ModelResponse(client.responses[client.calls[]]; metadata=ModelMetadata(provider="mock", model="trace"))
end

function action_json(x, v, drive, frequency)
    """{"initial_displacement_m":$x,"initial_velocity_m_per_s":$v,"drive_acceleration_m_per_s2":$drive,"drive_frequency_hz":$frequency}"""
end

world = generate_world(118; config=OscillatorConfig(2.0, 5))
truth = evaluator_truth(world)
println("WORLD")
println("  hidden ζ = $(truth.damping_ratio)       evaluator only")
println("  hidden ω₀ = $(truth.natural_frequency) rad/s       evaluator only")

client = TraceScientist([
    action_json(0.5, 0.0, 0.0, 0.0),
    action_json(0.5, 0.0, 0.2, 0.0), # deliberately invalid_drive
    action_json(-0.5, 0.1, 0.0, 0.0),
], Ref(0))
outcome = run_experiment(world, ScientistPolicy(client), RunConfig(2; retry_allowance=1))

for event in outcome.public.events
    println("\nDECISION $(event.sequence)")
    println("  budget after decision = $(event.remaining_budget)")
    println("  public history length before request = $(event.sequence - 1)")
    println("ACTION")
    show(stdout, event.requested_action)
    println("\nVALIDATION")
    println("  $(event.validation_code)")
    if event.observation === nothing
        println("PUBLIC REJECTION")
    else
        println("OBSERVATION")
        for measurement in event.observation.measurements
            println("  t=$(measurement.time_s)  x=$(measurement.displacement_m)")
        end
    end
end
println("\nTERMINAL: $(outcome.public.status), interventions=$(outcome.public.terminal.interventions_used)")
