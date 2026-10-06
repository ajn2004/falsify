using Falsify
using JSON3
using Random
using TOML
using Test

struct TestPolicy <: AbstractPolicy end
Falsify.next_action(::TestPolicy, ::PublicState) = ExperimentAction(
    initial_displacement_m=0.1, initial_velocity_m_per_s=0.0)
struct CountingPolicy <: AbstractPolicy
    calls::Base.RefValue{Int}
end
Falsify.next_action(p::CountingPolicy, state::PublicState) = (p.calls[] += 1; ExperimentAction())
Falsify.policy_identity(::CountingPolicy) = PolicyIdentity("counting_test")
Falsify.policy_configuration(::CountingPolicy) = (;)

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

struct FakeModelClient <: AbstractModelClient
    content::String
    fail::Bool
    captured::Base.RefValue{Union{Nothing,ModelRequest}}
end
function Falsify.request(client::FakeModelClient, request::ModelRequest)
    client.captured[] = request
    client.fail && error("private provider diagnostic with truth 0.123")
    ModelResponse(client.content; metadata=ModelMetadata(provider="mock", model="fixed"))
end

struct MalformedWithMetadata <: AbstractModelClient end
Falsify.request(::MalformedWithMetadata, ::ModelRequest) = ModelResponse("not-json";
    metadata=ModelMetadata(provider="mock", model="malformed", request_id="request-42",
        input_tokens=17, output_tokens=3, latency_s=0.25, cost=0.004))

@testset "provider-independent scientist policy" begin
    world = generate_world(7123; config=OscillatorConfig(1.0, 3))
    limits = limits_for(public_task(world))
    action0 = ExperimentAction(initial_displacement_m=0.25, initial_velocity_m_per_s=-0.1)
    observation = Observation((Measurement(0.0, 0.25, nothing), Measurement(0.5, 0.1, nothing)), nothing, nothing)
    prior = DecisionHistoryEntry(action0, true, :accepted, true, observation, nothing, 4)
    state = PublicState(policy_task(public_task(world)), limits, (prior,), 4)
    good = """{"initial_displacement_m":0.5,"initial_velocity_m_per_s":0.2,"drive_acceleration_m_per_s2":0.0,"drive_frequency_hz":0.0}"""
    captured = Ref{Union{Nothing,ModelRequest}}(nothing)
    policy = ScientistPolicy(FakeModelClient(good, false, captured))
    expected = ExperimentAction(initial_displacement_m=0.5, initial_velocity_m_per_s=0.2)
    @test next_action(policy, state) == expected
    req = captured[]
    @test req isa ModelRequest
    @test req.prompt_version == PROMPT_VERSION
    @test req.task_description == state.task.model_description
    @test req.remaining_intervention_budget == 4
    @test occursin("For an unforced experiment, set both drive_acceleration_m_per_s2 and drive_frequency_hz to 0.", req.system_instruction)
    @test occursin("For a driven experiment, drive_acceleration_m_per_s2 must be nonzero and drive_frequency_hz must be strictly positive.", req.system_instruction)
    @test req.limits.initial_displacement_m == limits.displacement_m
    @test req.history[1].action == action0
    @test req.history[1].observation.measurements[2].displacement_m == 0.1
    serialized = JSON3.write(req)
    @test !occursin("OscillatorWorld", serialized)
    @test !occursin("truth", serialized)
    @test !occursin("world_seed", serialized)
    @test !occursin("condition_id", serialized)
    @test !occursin("evaluator", serialized)
    @test !occursin("provenance", serialized)
    @test !occursin("advisor", serialized)
    @test !occursin(string(metadata(world).world_seed), serialized)
    @test fieldnames(ModelRequest) == (:prompt_version, :system_instruction, :task_description,
        :limits, :remaining_intervention_budget, :history)
    @test !hasfield(ModelRequest, :world)
    @test !hasfield(ModelRequest, :provenance)
    @test model_request(state) == model_request(state)
    @test !occursin("reasoning", lowercase(SCIENTIST_PROMPT))

    for (body, code) in (("{", :malformed_response),
            ("{\"initial_displacement_m\":0,\"initial_velocity_m_per_s\":0,\"drive_acceleration_m_per_s2\":0}", :missing_required_field),
            ("{\"initial_displacement_m\":\"0\",\"initial_velocity_m_per_s\":0,\"drive_acceleration_m_per_s2\":0,\"drive_frequency_hz\":0}", :invalid_field_type),
            ("{\"initial_displacement_m\":1e999,\"initial_velocity_m_per_s\":0,\"drive_acceleration_m_per_s2\":0,\"drive_frequency_hz\":0}", :nonfinite_field))
        fake = FakeModelClient(body, false, Ref{Union{Nothing,ModelRequest}}(nothing))
        err = try
            next_action(ScientistPolicy(fake), state)
            nothing
        catch e
            e
        end
        @test err isa PolicyFailure
        @test err.code == code
    end
    client_error = try
        next_action(ScientistPolicy(FakeModelClient(good, true, Ref{Union{Nothing,ModelRequest}}(nothing))), state)
        nothing
    catch e
        e
    end
    @test client_error isa PolicyFailure
    @test client_error.code == :client_failure
    @test !occursin("truth", sprint(showerror, client_error))
    malformed = try
        next_action(ScientistPolicy(MalformedWithMetadata()), state)
        nothing
    catch failure
        failure
    end
    @test malformed isa PolicyFailure
    @test malformed.code == :malformed_response
    @test malformed.operational_metadata.request_id == "request-42"
    @test malformed.operational_metadata.input_tokens == 17

    outside = """{"initial_displacement_m":99,"initial_velocity_m_per_s":0,"drive_acceleration_m_per_s2":0,"drive_frequency_hz":0}"""
    parsed_action = next_action(ScientistPolicy(FakeModelClient(outside, false,
        Ref{Union{Nothing,ModelRequest}}(nothing))), state)
    @test parsed_action.initial_displacement_m == 99
    @test validate_action(parsed_action, state).code == :out_of_bounds
    @test validate_action(expected, state).valid
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

@testset "non-adaptive experimental baselines" begin
    world = generate_world(481; config=OscillatorConfig(1.0, 11))
    limits = limits_for(public_task(world))
    task = policy_task(public_task(world))
    empty_state = PublicState(task, limits, (), 12)
    controls(action) = (action.initial_displacement_m, action.initial_velocity_m_per_s,
        action.drive_acceleration_m_per_s2, action.drive_frequency_hz)

    random_sequence(seed) = [next_action(RandomPolicy(seed), empty_state)] # independent instance sanity
    function sequence(seed)
        policy = RandomPolicy(seed)
        [next_action(policy, empty_state) for _ in 1:12]
    end
    @test controls.(sequence(42)) == controls.(sequence(42))
    @test controls.(sequence(42)) != controls.(sequence(43))
    baseline = sequence(42)
    for action in baseline
        @test validate_action(action, empty_state).valid
        @test limits.displacement_m[1] <= action.initial_displacement_m <= limits.displacement_m[2]
        @test limits.velocity_m_per_s[1] <= action.initial_velocity_m_per_s <= limits.velocity_m_per_s[2]
        @test action.drive_acceleration_m_per_s2 == 0 ? action.drive_frequency_hz == 0 : action.drive_frequency_hz > 0
    end
    # Global random consumption cannot perturb the policy-owned RNG stream.
    first = sequence(901)
    rand(MersenneTwister(1), 10_000)
    @test controls.(sequence(901)) == controls.(first)

    policy = FixedDesignPolicy()
    action0 = ExperimentAction(initial_displacement_m=0.0)
    obs_a = Observation((Measurement(0.0, -100.0, nothing),), nothing, nothing)
    previous_entry = DecisionHistoryEntry(action0, true, :accepted, true, obs_a, nothing, 11)
    design = [next_action(policy, PublicState(task, limits,
        ntuple(_ -> previous_entry, i-1), 12-i+1)) for i in 1:12]
    @test all(a -> validate_action(a, empty_state).valid, design)
    # Different measurement values at the same history length do not change the choice.
    obs_b = Observation((Measurement(0.0, 100.0, nothing),), nothing, nothing)
    h_a = (DecisionHistoryEntry(action0, true, :accepted, true, obs_a, nothing, 11),)
    h_b = (DecisionHistoryEntry(action0, true, :accepted, true, obs_b, nothing, 11),)
    @test controls(next_action(policy, PublicState(task, limits, h_a, 12))) ==
        controls(next_action(policy, PublicState(task, limits, h_b, 12)))
    @test controls.(design[1:4]) != controls.(design[5:8])
    @test controls(design[1]) == controls(design[11]) # deterministic cycling after base design
    @test controls(next_action(policy, empty_state)) == controls(design[1]) # budget-independent prefix
    @test policy_identity(RandomPolicy(5)).name == "random"
    @test policy_configuration(RandomPolicy(5)) == (seed=5, driven_probability=0.5)
    @test policy_identity(policy).name == "fixed_design"
    @test policy_configuration(policy).cycling == "repeat_from_first_point"

    for budget in (1, 3, 8, 12)
        short = PublicState(task, limits, (), budget)
        @test validate_action(next_action(policy, short), short).valid
    end
    @test_throws ArgumentError next_action(policy, PublicState(task, limits, (), 0))
    exhausted_state = PublicState(task, limits, (), 0)
    @test_throws ArgumentError next_action(RandomPolicy(42), exhausted_state)
    @test !validate_action(next_action(RandomPolicy(42), empty_state), exhausted_state).valid
    @test !validate_action(next_action(policy, empty_state), exhausted_state).valid

    driven_frequencies = sort(unique(a.drive_frequency_hz for a in Falsify._fixed_design(limits)
        if a.drive_acceleration_m_per_s2 != 0))
    @test driven_frequencies == [0.75, 1.875, 3.0]
    @test fieldtypes(RandomPolicy) == (Int, MersenneTwister, Float64)
    @test !any(T -> T === OscillatorWorld, fieldtypes(RandomPolicy))
    @test !any(T -> T === OscillatorWorld, fieldtypes(FixedDesignPolicy))
end

@testset "immutable run artifacts and provenance" begin
    mktempdir() do temp
        world = generate_world(9182; config=OscillatorConfig(1.0, 3))
        run_id = new_run_id()
        @test run_id != string(9182)
        @test occursin(r"^[0-9a-f-]{36}$", run_id)
        action = ExperimentAction(initial_displacement_m=0.25)
        observation = policy_observation(observe(world, to_environment_action(action)))
        event = RunEvent(1, action, true, "accepted", true, observation, 1, "completed", 0.02, nothing)
        failure = PublicFailure("provider_timeout"; public_message="Policy request timed out", stage_index=2)
        evaluator_failure = EvaluatorFailure("provider_timeout"; diagnostic="private detail", stage_index=2)
        terminal = TerminalResult("completed", nothing, nothing, 1, 1, 0)
        failure_event = RunEvent(2, nothing, false, "provider_timeout", false, nothing, 1,
            "failed", nothing, failure)
        public = PublicRunArtifact(; run_id, status="completed", finalized_at="2026-10-05T00:00:00Z", task_description="oscillator task",
            action_limits=artifact_limits(ActionLimits(displacement_m=(-2.0, 2.0), velocity_m_per_s=(-1.0, 1.0),
                drive_acceleration_m_per_s2=(-1.0, 1.0), drive_frequency_hz=(0.0, 3.0), duration_s=1.0,
                cadence_s=0.5, max_samples=3)), intervention_budget=1,
            protocol_settings=ProtocolSettings(false), policy_identity=PolicyIdentity("test"),
            events=[event, failure_event], terminal)
        provenance = capture_provenance(run_id; root=normpath(joinpath(@__DIR__, "..")), world,
            noise_seed=32, policy_seed=7)
        @test_throws ArgumentError capture_provenance(run_id; world, world_seed=1234)
        evaluator = Falsify.RunArtifacts.evaluator_artifact(world, run_id;
            condition_id="clean", evaluator_metadata=(fixture="test",), failures=[evaluator_failure])
        path = write_run(temp, public, provenance, evaluator)
        loaded = load_run(path)
        @test loaded.public.schema_version == 1
        @test loaded.public.run_id == run_id
        @test loaded.public.events[1].requested_action.initial_displacement_m == 0.25
        @test loaded.public.events[1].observation.measurements[2].displacement_m == observation.measurements[2].displacement_m
        @test loaded.public.events[2].failure.code == "provider_timeout"
        @test !haskey(loaded.public.events[2].failure, :diagnostic)
        @test loaded.evaluator.failures[1].diagnostic == "private detail"
        @test loaded.evaluator.truth.damping_ratio == evaluator.damping_ratio
        @test loaded.provenance.world_seed == 9182
        @test loaded.provenance.noise_seed == 32
        @test loaded.provenance.policy_seed == 7
        @test loaded.provenance.configuration.solver == "Tsit5"
        @test loaded.provenance.configuration.final_time_s == 1.0
        spoofed = capture_provenance(run_id; root=temp, world,
            configuration=(solver="not_the_world_solver", reltol=9.0))
        @test spoofed.configuration.solver == "Tsit5"
        @test spoofed.configuration.reltol == metadata(world).reltol
        @test loaded.provenance.git_commit === nothing || occursin(r"^[0-9a-f]{40}$", loaded.provenance.git_commit)
        @test loaded.provenance.manifest_sha256 !== nothing
        @test_throws ArgumentError write_run(temp, public, provenance, evaluator)

        public_text = read(joinpath(path, "public.json"), String)
        @test !occursin("damping_ratio", public_text)
        @test !occursin("natural_frequency", public_text)
        @test !occursin("world_seed", public_text)
        @test !occursin("9182", public_text)
        @test !occursin("clean", public_text)
        @test !occursin("private detail", public_text)
        @test !(:world_seed in fieldnames(PublicRunArtifact))
        @test !(:truth in fieldnames(PublicRunArtifact))
        @test !hasfield(PublicRunArtifact, :world)
        @test occursin("9182", read(joinpath(path, "provenance.json"), String))
        @test occursin("damping_ratio", read(joinpath(path, "evaluator.json"), String))
        @test_throws Exception PublicRunArtifact(world=world)

        @test failure_event.failure.code == "provider_timeout"
        @test !hasfield(PublicFailure, :diagnostic)
        @test_throws MethodError PublicRunArtifact(; run_id, status="completed", task_description="bad",
            action_limits=(;), intervention_budget=0, protocol_settings=(;), policy_identity=(;))
        @test !occursin("Stacktrace", public_text)

        open(joinpath(path, "public.json"), "w") do io
            write(io, replace(public_text, "\"schema_version\":1" => "\"schema_version\":99"))
        end
        @test_throws ArgumentError load_run(path)
    end
end

struct SequenceClient <: AbstractModelClient
    calls::Base.RefValue{Int}
    requests::Vector{ModelRequest}
end
function Falsify.request(client::SequenceClient, req::ModelRequest)
    push!(client.requests, req); client.calls[] += 1
    bodies = ["""{"initial_displacement_m":0.2,"initial_velocity_m_per_s":0,"drive_acceleration_m_per_s2":0,"drive_frequency_hz":0}""",
        """{"initial_displacement_m":0.2,"initial_velocity_m_per_s":0,"drive_acceleration_m_per_s2":0,"drive_frequency_hz":1}""",
        """{"initial_displacement_m":0.3,"initial_velocity_m_per_s":0,"drive_acceleration_m_per_s2":0,"drive_frequency_hz":0}"""]
    ModelResponse(bodies[min(client.calls[], length(bodies))]; metadata=ModelMetadata(provider="mock", model="deterministic", request_id="r$(client.calls[])", input_tokens=4))
end

@testset "deterministic complete run controller" begin
    world = generate_world(9182; config=OscillatorConfig(1.0, 5))
    fixed = run_experiment(world, FixedDesignPolicy(), RunConfig(2); root=normpath(joinpath(@__DIR__, "..")))
    @test fixed.public.status == "completed"
    @test fixed.public.terminal.interventions_used == 2
    @test fixed.public.terminal.decision_opportunities_used == 2
    @test length(fixed.public.events) == 2

    runrandom(seed) = run_experiment(world, RandomPolicy(seed), RunConfig(3); root=normpath(joinpath(@__DIR__, ".."))).public.events
    a, b = runrandom(81), runrandom(81)
    controls(events) = [(e.requested_action, e.observation) for e in events]
    @test controls(a) == controls(b)
    @test controls(a) != controls(runrandom(82))
    random_outcome = run_experiment(world, RandomPolicy(81), RunConfig(1);
        root=normpath(joinpath(@__DIR__, "..")))
    @test random_outcome.provenance.policy_seed == 81

    client = SequenceClient(Ref(0), ModelRequest[])
    outcome = run_experiment(world, ScientistPolicy(client), RunConfig(2; retry_allowance=1);
        root=normpath(joinpath(@__DIR__, "..")))
    @test outcome.public.status == "completed"
    @test outcome.public.terminal.interventions_used == 2
    @test outcome.public.terminal.decision_opportunities_used == 3
    @test outcome.public.terminal.invalid_action_count == 1
    @test outcome.public.events[2].validation_code == "invalid_drive"
    @test !outcome.public.events[2].consumed_intervention
    @test outcome.public.events[2].remaining_budget == 1
    @test client.requests[3].history[2].validation_code == "invalid_drive"
    @test client.requests[3].history[2].remaining_budget == 1
    @test outcome.public.events[1].operational_metadata.provider == "mock"
    @test all(e -> e.status == "running", outcome.public.events[1:end-1])
    @test outcome.public.events[end].status == outcome.public.terminal.status

    failureclient = FakeModelClient("", true, Ref{Union{Nothing,ModelRequest}}(nothing))
    failure = run_experiment(world, ScientistPolicy(failureclient), RunConfig(2); root=normpath(joinpath(@__DIR__, "..")))
    @test failure.public.status == "failed"
    @test failure.public.terminal.decision_opportunities_used == 1
    @test failure.public.terminal.interventions_used == 0
    @test failure.public.events[1].failure.code == "client_failure"
    @test failure.public.events[end].status == failure.public.terminal.status
    malformed_run = run_experiment(world, ScientistPolicy(MalformedWithMetadata()), RunConfig(2);
        root=normpath(joinpath(@__DIR__, "..")))
    @test malformed_run.public.events[1].failure.code == "malformed_response"
    @test malformed_run.public.events[1].operational_metadata.request_id == "request-42"
    @test malformed_run.public.events[1].operational_metadata.input_tokens == 17
    @test !occursin("private provider", JSON3.write(Falsify.RunArtifacts._public(failure.public)))

    counter = Ref(0)
    limited = run_experiment(world, CountingPolicy(counter), RunConfig(4; max_decision_opportunities=2);
        root=normpath(joinpath(@__DIR__, "..")))
    @test counter[] == 2
    @test limited.public.status == "failed"
    @test limited.public.terminal.decision_opportunities_used == 2
    zero = run_experiment(world, CountingPolicy(counter), RunConfig(0); root=normpath(joinpath(@__DIR__, "..")))
    @test counter[] == 2
    @test zero.public.status == "completed"

    mktempdir() do dir
        path = write_run(dir, outcome.public, outcome.provenance, outcome.evaluator)
        loaded = load_run(path)
        @test loaded.public.run_id == loaded.provenance.run_id == loaded.evaluator.run_id
        loaded_actions = [(e.requested_action.initial_displacement_m, e.requested_action.initial_velocity_m_per_s,
            e.requested_action.drive_acceleration_m_per_s2, e.requested_action.drive_frequency_hz) for e in loaded.public.events]
        original_actions = [(e.requested_action.initial_displacement_m, e.requested_action.initial_velocity_m_per_s,
            e.requested_action.drive_acceleration_m_per_s2, e.requested_action.drive_frequency_hz) for e in outcome.public.events]
        @test loaded_actions == original_actions
        for (loaded_event, original_event) in zip(loaded.public.events, outcome.public.events)
            @test (loaded_event.observation === nothing) == (original_event.observation === nothing)
            if original_event.observation !== nothing
                loaded_values = [m.displacement_m for m in loaded_event.observation.measurements]
                original_values = [m.displacement_m for m in original_event.observation.measurements]
                @test loaded_values ≈ original_values atol=1e-12 rtol=1e-12
            end
        end
        replay_client = SequenceClient(Ref(0), ModelRequest[])
        replay = run_experiment(generate_world(loaded.provenance.world_seed; config=OscillatorConfig(1.0, 5)),
            ScientistPolicy(replay_client), RunConfig(2; retry_allowance=1); root=normpath(joinpath(@__DIR__, "..")))
        @test [(e.requested_action, e.validation_code) for e in replay.public.events] ==
            [(e.requested_action, e.validation_code) for e in outcome.public.events]
        for (a_event, b_event) in zip(replay.public.events, outcome.public.events)
            a_event.observation === nothing && continue
            @test [m.displacement_m for m in a_event.observation.measurements] ≈
                [m.displacement_m for m in b_event.observation.measurements] atol=1e-12 rtol=1e-12
        end
        text = read(joinpath(path, "public.json"), String)
        for protected in ("damping_ratio", "natural_frequency", "world_seed", "condition_id", "solver", "provenance", "advisor")
            @test !occursin(protected, text)
        end
        @test !hasfield(PublicState, :world)
        @test !hasfield(PublicState, :provenance)
        @test !hasfield(PublicState, :advisor_context)
        @test validate_run_events(outcome.public.events, 2, outcome.public.terminal)
    end
end

@testset "persisted evaluator scientific metrics" begin
    world = generate_world(411; config=OscillatorConfig(10.0, 101))
    actions = (
        ExperimentAction(initial_displacement_m=1.0),
        ExperimentAction(initial_displacement_m=0.0, initial_velocity_m_per_s=1.0),
        ExperimentAction(initial_displacement_m=0.0, drive_acceleration_m_per_s2=0.5,
            drive_frequency_hz=0.75),
    )
    evidence = [(a, policy_observation(observe(world, to_environment_action(a)))) for a in actions]
    fit = Falsify.SystemIdentification.fit_oscillator(evidence)
    truth = evaluator_truth(world)
    @test fit.status == :success
    @test fit.zeta ≈ truth.damping_ratio atol=2e-5
    @test fit.omega0 ≈ truth.natural_frequency atol=2e-5
    @test Falsify.SystemIdentification.fit_oscillator(Tuple[]).status == :insufficient_evidence
    single_fit = Falsify.SystemIdentification.fit_oscillator(evidence[1:1])
    alternate_world = generate_world(412; config=OscillatorConfig(10.0, 101))
    contradictory = (actions[1], policy_observation(observe(alternate_world, to_environment_action(actions[1]))))
    combined_fit = Falsify.SystemIdentification.fit_oscillator((evidence[1], contradictory))
    @test abs(combined_fit.zeta-single_fit.zeta) + abs(combined_fit.omega0-single_fit.omega0) > 1e-3

    # Exact noiseless evidence gives near-zero held-out error and parameter error.
    outcome = run_experiment(world, FixedDesignPolicy(), RunConfig(8))
    mktempdir() do dir
        path = write_run(dir, outcome.public, outcome.provenance, outcome.evaluator)
        metrics = score_run(path)
        @test metrics.fit_status == :success
        @test metrics.parameter_error < 1e-4
        @test metrics.raw_heldout_rmse_m < 1e-4
        @test metrics.heldout_prediction_error < 1e-4
        @test metrics.success
        @test metrics.interventions_used == 8
        @test metrics.decision_opportunities_used == 8
        @test score_run(load_run(path)).parameter_error == metrics.parameter_error

        # Policy identity is metadata only: renamed policy with identical evidence scores identically.
        public_text = read(joinpath(path, "public.json"), String)
        renamed_text = replace(public_text, "\"name\":\"fixed_design\"" => "\"name\":\"different_policy\"")
        other_root = joinpath(dir, "renamed")
        mkpath(other_root)
        other_path = joinpath(other_root, outcome.public.run_id)
        mkpath(other_path)
        for filename in ("provenance.json", "evaluator.json")
            cp(joinpath(path, filename), joinpath(other_path, filename))
        end
        write(joinpath(other_path, "public.json"), renamed_text)
        @test score_run(other_path).parameter_error == metrics.parameter_error
    end

    # A deliberately displaced estimate worsens both normalized physical errors.
    zeta, omega = truth.damping_ratio, truth.natural_frequency
    exact = sqrt(((0.0/0.35)^2 + (0.0/1.2)^2)/2)
    displaced = sqrt((((zeta+0.05-zeta)/0.35)^2 + ((omega+0.2-omega)/1.2)^2)/2)
    @test displaced > exact
    @test displaced/(1+displaced) > exact/(1+exact)

    # Zero-observation behavioral failure remains finite and maximally bad.
    failed = run_experiment(world, ScientistPolicy(MalformedWithMetadata()), RunConfig(8))
    mktempdir() do dir
        path = write_run(dir, failed.public, failed.provenance, failed.evaluator)
        metrics = score_run(path)
        @test metrics.fit_status == :insufficient_evidence
        @test metrics.parameter_error == 1.0
        @test metrics.heldout_prediction_error == 1.0
        @test isfinite(metrics.parameter_error) && isfinite(metrics.heldout_prediction_error)
        @test !metrics.success
        @test metrics.completion_status == "failed"
        @test metrics.model_calls == 1
        @test metrics.input_tokens == 17
        @test metrics.estimated_cost == 0.004
    end
end
