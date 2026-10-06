using Falsify
using Random
using TOML
using Test

struct TestPolicy <: AbstractPolicy end
Falsify.next_action(::TestPolicy, ::PublicState) = ExperimentAction(
    initial_displacement_m=0.1, initial_velocity_m_per_s=0.0)

@testset "Falsify package bootstrap" begin
    @test Base.pkgversion(Falsify) == v"0.1.0"

    first_run = rand(MersenneTwister(112), 8)
    second_run = rand(MersenneTwister(112), 8)
    @test first_run == second_run

    config_path = joinpath(@__DIR__, "..", "configs", "smoke.toml")
    config = TOML.parsefile(config_path)
    @test config["noise_seed"] == 211
    @test config["final_time"] > 0

    mktemp() do path, _
        open(path, "w") do io
            TOML.print(io, Dict("values" => first_run))
        end
        @test TOML.parsefile(path)["values"] == first_run
    end
end

@testset "Hidden damped oscillator" begin
    config = OscillatorConfig(4.0, 41; reltol=1e-10, abstol=1e-12)
    world_a = generate_world(481; config)
    world_b = generate_world(481; config)
    action = OscillatorExperiment(initial_displacement=0.7, initial_velocity=-0.2)
    observation_a = observe(world_a, action)
    observation_b = observe(world_b, action)
    @test evaluator_truth(world_a) == evaluator_truth(world_b)
    @test evaluator_truth(world_a) != evaluator_truth(generate_world(482; config))
    for seed in 0:100
        truth_i = evaluator_truth(generate_world(seed; config))
        @test 0.05 <= truth_i.damping_ratio <= 0.40
        @test 0.80 <= truth_i.natural_frequency <= 2.00
    end
    @test observation_a.times == observation_b.times
    @test observation_a.displacement ≈ observation_b.displacement atol=1e-12 rtol=1e-12
    @test metadata(world_a).solver == "Tsit5"
    @test metadata(world_a).world_seed == 481
    @test metadata(world_a).reltol == config.reltol
    @test metadata(world_a).package_version == Base.pkgversion(Falsify)

    # Unforced underdamped analytic solution validates the equation and initial conditions.
    truth = evaluator_truth(world_a)
    beta = truth.damping_ratio * truth.natural_frequency
    wd = truth.natural_frequency * sqrt(1 - truth.damping_ratio^2)
    x0, v0 = action.initial_displacement, action.initial_velocity
    analytic(t) = exp(-beta*t) * (x0*cos(wd*t) + (v0 + beta*x0)/wd*sin(wd*t))
    @test observation_a.displacement ≈ analytic.(observation_a.times) atol=2e-8 rtol=2e-8

    task = public_task(world_a)
    @test Set(fieldnames(typeof(task))) == Set((:model_description, :final_time, :sample_count,
        :displacement_bounds, :velocity_bounds, :drive_acceleration_bounds_m_per_s2, :drive_frequency_bounds_hz))
    @test !(:truth in fieldnames(typeof(task)))
    @test !(:world_seed in fieldnames(typeof(task)))
    @test !occursin(string(metadata(world_a).world_seed), sprint(show, task))
    @test policy_task(task) == TaskDescription(task.model_description)
    @test fieldnames(typeof(policy_task(task))) == (:model_description,)
    @test_throws ArgumentError observe(world_a, OscillatorExperiment(drive_acceleration_m_per_s2=2.0))
end
@testset "experiment and observation contract" begin
    world = generate_world(481; config=OscillatorConfig(1.0, 11))
    task = public_task(world)
    limits = limits_for(task)
    public_description = policy_task(task)
    state = PublicState(public_description, limits, (), 2)
    valid = ExperimentAction(initial_displacement_m=0.1, initial_velocity_m_per_s=0.0)
    @test validate_action(valid, state) == ValidationResult(true, :accepted)
    @test validate_action(ExperimentAction(initial_displacement_m=2.1,
        initial_velocity_m_per_s=0.0), state).code == :out_of_bounds
    @test validate_action(ExperimentAction(initial_displacement_m=0.0,
        initial_velocity_m_per_s=0.0, drive_acceleration_m_per_s2=-0.2,
        drive_frequency_hz=1.0), state).valid
    exhausted = PublicState(public_description, limits, (), 0)
    @test validate_action(valid, exhausted) == ValidationResult(false, :budget_exhausted)
    @test !hasfield(PublicState, :advisor_context)
    @test fieldtype(PublicState, :history) <: Tuple
    @test fieldtype(Observation, :measurements) <: Tuple
    @test hasfield(Observation, :noise_scale_m)
    @test !hasfield(Observation, :noise_scale)
    @test fieldtype(PublicState, :task) === TaskDescription
    @test !hasfield(TaskDescription, :final_time)
    @test ExperimentAction !== OscillatorExperiment
    @test to_environment_action(valid) isa OscillatorExperiment
    @test to_environment_action(valid).initial_displacement == valid.initial_displacement_m
    @test_throws ArgumentError ActionLimits(displacement_m=(2.0, 1.0), velocity_m_per_s=(-1.0, 1.0),
        drive_acceleration_m_per_s2=(-1.0, 1.0), drive_frequency_hz=(0.0, 3.0),
        duration_s=1.0, cadence_s=0.1, max_samples=11)
    @test next_action(TestPolicy(), state).initial_displacement_m == valid.initial_displacement_m
    obs = policy_observation(observe(world, to_environment_action(valid)))
    @test length(obs.measurements) == task.sample_count
    @test obs.noise_model === nothing
    @test obs.noise_scale_m === nothing
end
