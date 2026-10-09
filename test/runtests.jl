using Falsify
using JSON3
using TOML
using Test
using UUIDs
using Random

struct ContractProbeEnvironment <: Falsify.AbstractEnvironment
    truth::Float64
    world_seed::Int
end
struct ContractProbeAction <: Falsify.AbstractExperimentAction
    control_value::Float64
end
struct ContractProbeObservation <: Falsify.AbstractPolicyObservation
    time_s::Tuple{Float64,Float64}
    measurement_a::Tuple{Float64,Float64}
    measurement_b::Tuple{Float64,Float64}
    noise_model::String
    noise_scale::Float64
end
import Falsify: environment_id, public_task, limits_for, metadata, evaluator_truth, action_schema,
    parse_action, validate_environment_action, execute_experiment, apply_environment_noise,
    public_action, public_observation
environment_id(::ContractProbeEnvironment) = "test_contract_probe"
public_task(::ContractProbeEnvironment) = Falsify.TaskDescription("Deterministic two-channel contract probe; control bounded in [0, 1].")
limits_for(::Falsify.TaskDescription) = (control_value=(0.0, 1.0), duration_s=1.0, cadence_s=1.0, max_samples=2)
metadata(w::ContractProbeEnvironment) = (world_seed=w.world_seed,)
evaluator_truth(w::ContractProbeEnvironment) = (gain=w.truth,)
action_schema(::ContractProbeEnvironment) = Dict("type"=>"object", "properties"=>Dict(
    "control_value"=>Dict("type"=>"number", "minimum"=>0, "maximum"=>1)),
    "required"=>["control_value"], "additionalProperties"=>false)
function parse_action(::Type{ContractProbeEnvironment}, content::AbstractString)
    parsed = JSON3.read(content)
    parsed isa JSON3.Object && Set(String(k) for k in keys(parsed)) == Set(["control_value"]) ||
        throw(Falsify.PolicyFailure(:malformed_response))
    x = parsed[:control_value]
    x isa Real && !(x isa Bool) || throw(Falsify.PolicyFailure(:invalid_field_type))
    ContractProbeAction(Float64(x))
end
validate_environment_action(::ContractProbeEnvironment, a::ContractProbeAction) =
    isfinite(a.control_value) && 0 <= a.control_value <= 1 ? Falsify.ValidationResult(true, :accepted) : Falsify.ValidationResult(false, :out_of_bounds)
execute_experiment(w::ContractProbeEnvironment, a::ContractProbeAction) =
    ContractProbeObservation((0.0, 1.0), (a.control_value, a.control_value), (w.truth*a.control_value, w.truth*a.control_value), "clean", 0.0)
apply_environment_noise(::ContractProbeEnvironment, obs::ContractProbeObservation, ::Falsify.CleanObservation, seed, index) = obs
function apply_environment_noise(::ContractProbeEnvironment, obs::ContractProbeObservation,
        noise::Falsify.GaussianObservationNoise, seed, index)
    rng = MersenneTwister(Falsify._noise_stream_seed(seed, index)); σ = noise.sigma_m
    ContractProbeObservation(obs.time_s,
        Tuple(x + σ*randn(rng) for x in obs.measurement_a),
        Tuple(x + σ*randn(rng) for x in obs.measurement_b), "gaussian_additive", σ)
end
public_action(::ContractProbeEnvironment, a::ContractProbeAction) = a
public_observation(::ContractProbeEnvironment, o::ContractProbeObservation) = o

include(joinpath(@__DIR__, "..", "scripts", "ConfirmatoryV01.jl"))
include(joinpath(@__DIR__, "..", "scripts", "materialize_confirmatory_scores_v0_1.jl"))
include(joinpath(@__DIR__, "..", "scripts", "analyze_confirmatory_v0_1.jl"))
include(joinpath(@__DIR__, "..", "scripts", "reliability_report_v0_2.jl"))

struct ContractProbeClient <: AbstractModelClient
    content::String
    seen::Base.RefValue{Union{Nothing,ModelRequest}}
end
Falsify.request(c::ContractProbeClient, req::ModelRequest) = (c.seen[] = req; ModelResponse(c.content))

@testset "DAL-150 generic environment contract" begin
    probe = ContractProbeEnvironment(0.314159, 918273)
    seen = Ref{Union{Nothing,ModelRequest}}(nothing)
    out = run_experiment(probe, ScientistPolicy(ContractProbeClient("{\"control_value\":0.6}", seen)), RunConfig(1))
    @test out.public.status == "completed"
    @test out.public.environment_id == "test_contract_probe"
    @test out.public.action_schema_version == "1"
    @test out.public.policy_identity.version == GENERIC_PROMPT_VERSION
    @test out.public.observation_schema_version == "1"
    @test out.public.events[1].requested_action isa ContractProbeAction
    observation = out.public.events[1].observation
    @test observation isa ContractProbeObservation
    @test observation.measurement_a == (0.6, 0.6)
    @test observation.measurement_b == (0.1884954, 0.1884954)
    noisy_cfg = RunConfig(1; observation_noise=GaussianObservationNoise(0.05), noise_seed=817263)
    noisy1 = run_experiment(probe, ScientistPolicy(ContractProbeClient("{\"control_value\":0.6}", Ref{Union{Nothing,ModelRequest}}(nothing))), noisy_cfg)
    noisy2 = run_experiment(probe, ScientistPolicy(ContractProbeClient("{\"control_value\":0.6}", Ref{Union{Nothing,ModelRequest}}(nothing))), noisy_cfg)
    @test noisy1.public.events[1].observation == noisy2.public.events[1].observation
    @test noisy1.public.events[1].observation.noise_model == "gaussian_additive"
    invalid = run_experiment(probe, ScientistPolicy(ContractProbeClient("{\"control_value\":1.2}", Ref{Union{Nothing,ModelRequest}}(nothing))), RunConfig(1))
    @test invalid.public.events[1].validation_code == "out_of_bounds"
    @test classify_run(invalid.public.status, invalid.public.terminal.failure.code) == "behavioral_failure"
    @test seen[] !== nothing
    @test seen[].action_schema == action_schema(probe)
    public_payload = JSON3.write(seen[])
    for forbidden in ("0.314159", "918273", "world_seed", "noise_seed", "evaluator", "score", "truth",
            "hidden_class", "natural_frequency", "artifact_dir", "evaluator.json", "results/private")
        @test !occursin(forbidden, public_payload)
    end
    @test_throws PolicyFailure parse_action(ContractProbeEnvironment, "{\"different\":0.5}")

    cfg = OpenRouterConfig(model="mock/model", provider_order=["mock"], prompt_version=seen[].prompt_version)
    payload = Falsify.OpenRouterIntegration.openrouter_payload(cfg, seen[])
    schema = payload["response_format"]["json_schema"]["schema"]
    @test haskey(schema["properties"], "control_value")
    @test !haskey(schema["properties"], "initial_displacement_m")

    oscillator_state = PublicState(policy_task(public_task(generate_world(19))),
        limits_for(public_task(generate_world(19))), (), 1; action_schema=Falsify.legacy_action_schema(),
        policy_contract_profile=PROMPT_VERSION)
    oscillator_request = model_request(oscillator_state)
    oscillator_cfg = OpenRouterConfig(model="mock/model", provider_order=["mock"], prompt_version=oscillator_request.prompt_version)
    oscillator_payload = Falsify.OpenRouterIntegration.openrouter_payload(oscillator_cfg, oscillator_request)
    oscillator_schema = oscillator_payload["response_format"]["json_schema"]["schema"]
    @test haskey(oscillator_schema["properties"], "initial_displacement_m")
    @test all(value == Dict("type"=>"number") for value in values(oscillator_schema["properties"]))
    oscillator_user = JSON3.read(oscillator_payload["messages"][2].content)
    @test Set(Symbol.(keys(oscillator_user))) == Set((:task_description, :action_limits,
        :remaining_intervention_budget, :remaining_decision_opportunities, :public_decision_history))
    oscillator_run = run_experiment(generate_world(19),
        ScientistPolicy(ContractProbeClient("{}", Ref{Union{Nothing,ModelRequest}}(nothing))), RunConfig(1))
    @test oscillator_run.public.policy_identity.version == PROMPT_VERSION

    # A future environment may intentionally share V0.1's controls without inheriting its contract.
    same_schema_state = PublicState(policy_task(public_task(probe)), limits_for(public_task(probe)), (), 1;
        action_schema=Falsify.legacy_action_schema(), policy_contract_profile=GENERIC_PROMPT_VERSION)
    same_schema_request = model_request(same_schema_state)
    @test same_schema_request.prompt_version == GENERIC_PROMPT_VERSION
    @test policy_identity(ScientistPolicy(ContractProbeClient("{}", Ref{Union{Nothing,ModelRequest}}(nothing))), probe).version == GENERIC_PROMPT_VERSION
    generic_cfg = OpenRouterConfig(model="mock/model", provider_order=["mock"], prompt_version=GENERIC_PROMPT_VERSION)
    generic_payload = Falsify.OpenRouterIntegration.openrouter_payload(generic_cfg, same_schema_request)
    generic_user = JSON3.read(generic_payload["messages"][2].content)
    @test haskey(generic_user, :action_schema)

    mktempdir() do root
        path = write_run(root, out.public, out.provenance, out.evaluator)
        loaded = load_run(path)
        @test loaded.public.environment_id == "test_contract_probe"
        @test loaded.public.action_schema_version == "1"
        public_json = read(joinpath(path, "public.json"), String)
        @test !occursin("0.314159", public_json)
        @test !occursin("918273", public_json)
        @test occursin("0.314159", read(joinpath(path, "evaluator.json"), String))
        @test occursin("control_value", public_json)
        @test occursin("measurement_b", public_json)
        attempt = run_attempt(probe,
            ScientistPolicy(ContractProbeClient("{\"control_value\":0.4}", Ref{Union{Nothing,ModelRequest}}(nothing))),
            RunConfig(1); artifacts_root=joinpath(root, "attempts"), ledger_path=joinpath(root, "ledger.jsonl"))
        @test attempt.classification == "completed"
        @test attempt.outcome.public.environment_id == "test_contract_probe"
        @test isfile(joinpath(attempt.artifact_dir, "public.json"))
    end

    @test classify_run("failed", "provider_unavailable") == "infrastructure"
    @test classify_run("failed", "invalid_action") == "behavioral_failure"
    @test classify_run("aborted", "apparatus_exception") == "apparatus_failure"
end

@testset "DAL-152 linear versus Duffing environment" begin
    worlds = [generate_duffing_world(seed) for seed in 1:64]
    @test any(w -> w.truth.model_class == Falsify.linear, worlds)
    @test any(w -> w.truth.model_class == Falsify.duffing, worlds)
    @test generate_duffing_world(42).truth == generate_duffing_world(42).truth
    @test generate_duffing_world(42).truth.beta == (generate_duffing_world(42).truth.model_class == Falsify.linear ? 0.0 : generate_duffing_world(42).truth.beta)
    @test all(w -> DUFFING_ZETA_RANGE[1] <= w.truth.zeta <= DUFFING_ZETA_RANGE[2] &&
        DUFFING_OMEGA_RANGE[1] <= w.truth.omega0 <= DUFFING_OMEGA_RANGE[2] &&
        (w.truth.model_class == Falsify.linear ? w.truth.beta == 0.0 : DUFFING_BETA_RANGE[1] <= w.truth.beta <= DUFFING_BETA_RANGE[2]), worlds)

    @test action_schema(first(filter(w -> w.truth.model_class == Falsify.duffing, worlds))) == Falsify.legacy_action_schema()
    linear_world = DuffingWorld(DuffingTruth(Falsify.linear, 0.15, 1.3, 0.0), OscillatorConfig(),
        DuffingMetadata("Tsit5", 1e-9, 1e-11, 1, v"0.0.0"))
    duffing_world = DuffingWorld(DuffingTruth(Falsify.duffing, 0.15, 1.3, 0.5), OscillatorConfig(),
        DuffingMetadata("Tsit5", 1e-9, 1e-11, 1, v"0.0.0"))
    low = ExperimentAction(initial_displacement_m=0.2)
    high = ExperimentAction(initial_displacement_m=1.5)
    distance(world_a, world_b, action) = sqrt(sum(abs2, duffing_observe(world_a, action).displacement .-
        duffing_observe(world_b, action).displacement) / 101)
    @test distance(linear_world, duffing_world, high) > 20distance(linear_world, duffing_world, low)
    exact = duffing_observe(linear_world, high)
    reference = observe(Falsify.OscillatorWorld(Falsify.OscillatorTruth(0.15, 1.3), OscillatorConfig(),
        Falsify.OscillatorMetadata("Tsit5", 1e-9, 1e-11, 1, v"0.0.0")),
        OscillatorExperiment(initial_displacement=1.5))
    @test exact.displacement ≈ reference.displacement atol=1e-9
    bad_action = ExperimentAction(drive_frequency_hz=0.8)
    @test validate_environment_action(linear_world, bad_action).code == :invalid_drive
    @test validate_environment_action(duffing_world, bad_action).code == :invalid_drive
    clean_trace = duffing_observe(duffing_world, low)
    noisy_a = Falsify.apply_environment_noise(duffing_world, clean_trace, GaussianObservationNoise(0.1), 77, 1)
    noisy_b = Falsify.apply_environment_noise(linear_world, duffing_observe(linear_world, low), GaussianObservationNoise(0.1), 77, 1)
    @test noisy_a isa Observation && noisy_b isa Observation
    @test length(noisy_a.measurements) == length(noisy_b.measurements) == 101
    @test noisy_a.noise_model == noisy_b.noise_model == "gaussian_additive"

    public_artifacts = Falsify.PublicRunArtifact[]
    for world in (linear_world, duffing_world)
        @test Falsify.policy_contract_profile(world) == GENERIC_PROMPT_VERSION
        @test policy_task(public_task(world)) == policy_task(public_task(duffing_world))
        @test action_schema(world) == Falsify.legacy_action_schema()
    end
    seen = Ref{Union{Nothing,ModelRequest}}(nothing)
    client = ContractProbeClient("{\"initial_displacement_m\":0.2,\"initial_velocity_m_per_s\":0.0,\"drive_acceleration_m_per_s2\":0.0,\"drive_frequency_hz\":0.0}", seen)
    req = model_request(PublicState(policy_task(public_task(duffing_world)), limits_for(public_task(duffing_world)), (), 1;
        action_schema=action_schema(duffing_world), policy_contract_profile=Falsify.policy_contract_profile(duffing_world)))
    @test req.prompt_version == GENERIC_PROMPT_VERSION
    payload = Falsify.OpenRouterIntegration.openrouter_payload(OpenRouterConfig(model="mock/model",
        provider_order=["mock"], prompt_version=GENERIC_PROMPT_VERSION), req)
    @test haskey(JSON3.read(payload["messages"][2].content), :action_schema)

    for world in (linear_world, duffing_world)
        random_outcome = run_experiment(world, RandomPolicy(123), RunConfig(2))
        @test random_outcome.public.status == "completed"
        @test random_outcome.public.environment_id == "linear_vs_duffing_v0_2"
        @test length(random_outcome.public.events) == 2

        fixed_outcome = run_experiment(world, FixedDesignPolicy(), RunConfig(2))
        @test fixed_outcome.public.status == "completed"
        @test fixed_outcome.public.environment_id == "linear_vs_duffing_v0_2"
        @test length(fixed_outcome.public.events) == 2

        local_seen = Ref{Union{Nothing,ModelRequest}}(nothing)
        policy = ScientistPolicy(ContractProbeClient("{\"initial_displacement_m\":0.2,\"initial_velocity_m_per_s\":0.0,\"drive_acceleration_m_per_s2\":0.0,\"drive_frequency_hz\":0.0}", local_seen))
        outcome = run_experiment(world, policy, RunConfig(1))
        @test outcome.public.status == "completed"
        @test outcome.public.environment_id == "linear_vs_duffing_v0_2"
        @test outcome.public.policy_identity.version == GENERIC_PROMPT_VERSION
        @test local_seen[].prompt_version == GENERIC_PROMPT_VERSION
        @test length(outcome.public.events[1].observation.measurements) == 101
        push!(public_artifacts, outcome.public)
        @test !(:world_seed in fieldnames(typeof(local_seen[])))
        @test !(:evaluator_metadata in fieldnames(typeof(local_seen[])))
        @test !occursin(string(world.truth.zeta), local_seen[].task_description)
        @test !occursin(string(world.truth.omega0), local_seen[].task_description)
        mktempdir() do root
            attempt = run_attempt(world, ScientistPolicy(ContractProbeClient(
                "{\"initial_displacement_m\":0.2,\"initial_velocity_m_per_s\":0.0,\"drive_acceleration_m_per_s2\":0.0,\"drive_frequency_hz\":0.0}",
                Ref{Union{Nothing,ModelRequest}}(nothing))), RunConfig(1);
                artifacts_root=joinpath(root, "runs"), ledger_path=joinpath(root, "ledger.jsonl"))
            @test attempt.classification == "completed"
            @test attempt.outcome.public.environment_id == "linear_vs_duffing_v0_2"
            public_text = read(joinpath(attempt.artifact_dir, "public.json"), String)
            @test occursin("H_L:", public_text) && occursin("H_D:", public_text)
            @test !occursin("model_class", public_text)
            @test !occursin("evaluator.json", public_text)
        end
    end
    left, right = public_artifacts
    @test left.environment_id == right.environment_id
    @test left.environment_version == right.environment_version
    @test left.task_description == right.task_description
    @test left.action_limits == right.action_limits
    @test left.policy_identity == right.policy_identity
    @test keys(JSON3.read(JSON3.write(left))) == keys(JSON3.read(JSON3.write(right)))
    @test typeof(left.events[1].requested_action) == typeof(right.events[1].requested_action)
    @test typeof(left.events[1].observation) == typeof(right.events[1].observation)
end

@testset "DAL-155 reliability report reconciliation" begin
    R = ReliabilityReportV02
    root = normpath(joinpath(@__DIR__, ".."))
    frozen = R.summarize(joinpath(root, "results", "confirmatory-v0.1-prereg-4"))
    @test frozen.total_logical_slots == 40
    @test frozen.total_raw_attempts == 60
    @test frozen.completed_slots == 25
    @test frozen.behavioral_terminal_slots == 4
    @test frozen.infrastructure_terminal_slots == 11
    @test frozen.recovered_infrastructure_slots == 9
    retry_slots = unique(a.slot_id for a in frozen.attempts if count(x -> x.slot_id == a.slot_id, frozen.attempts) == 2)
    @test length(retry_slots) == 20
    @test all(slot -> sort([x.attempt_number for x in frozen.attempts if x.slot_id == slot]) == [1, 2], retry_slots)

    mktempdir() do temp
        execution = joinpath(temp, "results", "execution")
        mkpath(execution)
        write(joinpath(execution, "execution-plan.json"), JSON3.write((protocol_id="fixture-v1", slots=[
            (slot_id="s1", policy="scientist", condition_id="clean", world_seed=1),
            (slot_id="s2", policy="scientist", condition_id="clean", world_seed=2)])))
        write(joinpath(execution, "execution-state.json"), JSON3.write((;
            slots=[
            (slot_id="s1", run_ids=["a1", "a2"]), (slot_id="s2", run_ids=["a3"]),
            (slot_id="other", run_ids=["b1"])]
        )))
        ledger = [
            (run_id="a1", classification="infrastructure", terminal_failure_code="provider_unavailable", decision_opportunities_used=0),
            (run_id="a2", classification="completed", terminal_failure_code=nothing, decision_opportunities_used=1),
            (run_id="a3", classification="apparatus_failure", terminal_failure_code="apparatus_exception", decision_opportunities_used=1),
            (run_id="b1", classification="completed", terminal_failure_code=nothing, decision_opportunities_used=1)]
        open(joinpath(execution, "run-ledger.jsonl"), "w") do io
            foreach(x -> (write(io, JSON3.write(x)); write(io, '\n')), ledger)
        end
        journal = [(event="attempt_started", run_id="a1", slot_id="s1", policy="scientist", repetition_id="first", condition_id="clean"),
            (event="attempt_started", run_id="a2", slot_id="s1", policy="scientist", repetition_id="second", condition_id="clean"),
            (event="attempt_started", run_id="a3", slot_id="s2", policy="scientist", repetition_id="only", condition_id="clean"),
            (event="attempt_started", run_id="b1", slot_id="other", policy="random", repetition_id="only", condition_id="clean")]
        open(joinpath(execution, "attempt-journal.jsonl"), "w") do io
            foreach(x -> (write(io, JSON3.write(x)); write(io, '\n')), journal)
        end
        report = R.summarize(execution)
        @test report.total_raw_attempts == 3
        @test report.all_policy_raw_attempts == 4
        @test [a.attempt_number for a in report.attempts if a.slot_id == "s1"] == [1, 2]
        @test report.recovered_infrastructure_slots == 1
        @test report.apparatus_failure_slots == ["s2"]
        @test !report.gate_pass
    end
end

@testset "V0.1 attempt-level frozen score materialization" begin
    M = ConfirmatoryScoreMaterializer
    root = normpath(joinpath(@__DIR__, ".."))
    rows = M.attempt_records(root)
    @test length(rows) == 140
    @test count(r -> r.score_status == "unscored_infrastructure", rows) == 31
    @test count(r -> r.score_status == "scored_behavioral_failure", rows) == 4
    @test all(r -> r.protocol_id == "falsify-v0.1-prereg-4", rows)
    @test all(r -> r.score_status != "unscored_infrastructure" ||
        (r.parameter_error === nothing && r.prediction_error === nothing), rows)
    @test all(r -> r.classification != "behavioral_failure" ||
        (r.parameter_error == 1.0 && r.prediction_error == 1.0), rows)
    @test !any(occursin("damping_ratio", String(k)) || occursin("natural_frequency", String(k))
        for k in keys(M.score_row(first(rows))))

    mktempdir() do temp
        rawdir = joinpath(temp, "results", "raw")
        mkpath(joinpath(rawdir, "prereg-run"))
        write(joinpath(rawdir, "prereg-run", "public.json"), "original")
        scoped = M.protocol_artifact_hash(temp, ["prereg-run", "missing-run"])
        mkpath(joinpath(rawdir, "future-run"))
        write(joinpath(rawdir, "future-run", "public.json"), "unrelated")
        @test M.protocol_artifact_hash(temp, ["missing-run", "prereg-run"]) == scoped
        write(joinpath(rawdir, "prereg-run", "public.json"), "modified")
        @test M.protocol_artifact_hash(temp, ["prereg-run", "missing-run"]) != scoped
    end

    completed = first(filter(r -> r.classification == "completed", rows))
    rawdir = joinpath(root, "results", "raw")
    artifact_dir = joinpath(rawdir, completed.run_id)
    direct = score_run(load_run(artifact_dir))
    @test completed.parameter_error == direct.parameter_error
    @test completed.prediction_error == direct.heldout_prediction_error
    @test completed.parameter_success == direct.success

    raw_hash = M.file_tree_hash(rawdir)
    execution_hash = M.file_tree_hash(joinpath(root, "results", "confirmatory-v0.1-prereg-4"))
    rerun = M.attempt_records(root)
    @test map(M.score_row, rows) == map(M.score_row, rerun)
    @test M.file_tree_hash(rawdir) == raw_hash
    @test M.file_tree_hash(joinpath(root, "results", "confirmatory-v0.1-prereg-4")) == execution_hash
    @test all(r -> !hasproperty(r, :hypothesis) && !hasproperty(r, :paired_difference), rows)
end

@testset "DAL-125 locked persisted-artifact analysis contracts" begin
    A=ConfirmatoryV01Analysis
    root=normpath(joinpath(@__DIR__,".."))
    resolved=A.resolve_attempts(root)
    @test length(resolved.attempts)==140
    @test length(resolved.slots)==120
    @test count(s->s.terminal_infrastructure,resolved.slots)==11
    @test all(s->s.repetition_id!="scientist-2"&&s.repetition_id!="scientist-3",resolved.slots)
    @test count(s->s.condition_id=="gaussian_0.10"&&s.terminal_infrastructure,resolved.slots)==4
    @test count(s->s.condition_id=="clean"&&s.terminal_infrastructure,resolved.slots)==7
    @test count(s->s.resolution=="behavioral_failure",resolved.slots)==4
    @test all(s->s.resolution!="behavioral_failure" ||
        (s.parameter_error==1.0&&s.prediction_error==1.0),resolved.slots)
    differences=[-0.5,0.25,0.1,-0.2]
    b1=A.paired_bootstrap(differences); b2=A.paired_bootstrap(differences)
    @test b1==b2
    @test b1.resamples==10_000 && b1.seed==9_123_999 && b1.n_worlds==4
    @test b1.mean_difference≈sum(differences)/4
    @test_throws ErrorException A.paired_bootstrap(differences;resamples=9999)
    @test_throws ErrorException A.paired_bootstrap(differences;seed=3)
    both=[(hypothesis="H1",ci_high=-0.01),(hypothesis="H1",ci_high=-0.02)]
    one=[(hypothesis="H1",ci_high=-0.01),(hypothesis="H1",ci_high=0.0)]
    @test A.hypothesis_supported(both,"H1")
    @test !A.hypothesis_supported(one,"H1")
    @test !occursin("score_run(",read(joinpath(root,"scripts","analyze_confirmatory_v0_1.jl"),String))
    @test !occursin("using Falsify",read(joinpath(root,"scripts","analyze_confirmatory_v0_1.jl"),String))
    before=ConfirmatoryScoreMaterializer.file_tree_hash(joinpath(root,"results","raw"))
    first_result=A.analyze(root)
    primary_path=joinpath(root,"results","derived","v0.1-confirmatory","primary_results.json")
    first_primary=read(primary_path,String)
    figure_path=joinpath(root,"results","derived","v0.1-confirmatory","figures","primary-paired-endpoints.svg")
    first_figure=read(figure_path,String)
    second_result=A.analyze(root)
    @test first_result.effects==second_result.effects
    @test first_primary==read(primary_path,String)
    @test first_figure==read(figure_path,String)
    @test ConfirmatoryScoreMaterializer.file_tree_hash(joinpath(root,"results","raw"))==before
    @test A.hypothesis_supported(first_result.effects,"H1")==first_result.H1
    @test A.hypothesis_supported(first_result.effects,"H2")==first_result.H2
end

@testset "DAL-124 frozen confirmatory matrix" begin
    root = normpath(joinpath(@__DIR__, ".."))
    seeds = TOML.parsefile(joinpath(root, "research", "confirmatory-seeds-v0.1-prereg-4.toml"))
    slots = ConfirmatoryV01.build_matrix(joinpath(root, "research", "confirmatory-seeds-v0.1-prereg-4.toml"))
    @test length(slots) == 120
    @test count(s -> s["policy"] == "scientist", slots) == 40
    @test count(s -> s["policy"] in ("random", "fixed_design"), slots) == 80
    @test count(s -> s["condition_id"] == "gaussian_0.10", slots) == 90
    @test count(s -> s["condition_id"] == "clean", slots) == 30
    @test length(unique(s["world_seed"] for s in slots if s["condition_id"] == "gaussian_0.10")) == 30
    @test length(unique(s["world_seed"] for s in slots if s["condition_id"] == "clean")) == 10
    @test Set(s["world_seed"] for s in slots if s["condition_id"] == "clean") == Set(8123001:8123010)
    @test all(s["repetition_id"] ∉ ("scientist-2", "scientist-3") for s in slots)
    @test ConfirmatoryV01.nominal_provider_requests(slots) == 320
    @test Set(ConfirmatoryV01.analysis_conditions()) == Set(["gaussian_0.10"])
    @test all(Set(s["policy"] for s in slots if s["world_seed"] == world && s["condition_id"] == condition) ==
        Set(["random", "fixed_design", "scientist"]) for condition in ("gaussian_0.10", "clean")
        for world in unique(s["world_seed"] for s in slots if s["condition_id"] == condition))
    @test all(s["intervention_budget"] == 8 && s["max_decision_opportunities"] == 16 for s in slots)
    @test all(s["noise_seed"] == only(filter(w -> w["world_seed"] == s["world_seed"], seeds["worlds"]))["noise_seed"] for s in slots)
    @test all(s["policy"] != "random" || s["policy_seed"] == only(filter(w -> w["world_seed"] == s["world_seed"], seeds["worlds"]))["random_policy_seed"] for s in slots)
    @test all(s["policy"] != "fixed_design" || s["policy_seed"] === nothing for s in slots)
    @test isempty(intersect(Set(w["world_seed"] for w in seeds["worlds"]), Set([7122123,7122124,7122125,7122126])))
    @test ConfirmatoryV01.retry_decision(String[]) == :pending
    @test ConfirmatoryV01.retry_decision(["completed"]) == :completed
    @test ConfirmatoryV01.retry_decision(["behavioral_failure"]) == :behavioral_failure
    @test ConfirmatoryV01.retry_decision(["infrastructure"]) == :retry
    @test ConfirmatoryV01.retry_decision(["infrastructure", "infrastructure"]) == :terminal_infrastructure
    @test ConfirmatoryV01.retry_decision(["infrastructure", "completed"]) == :completed
    @test ConfirmatoryV01.retry_decision(["infrastructure", "behavioral_failure"]) == :behavioral_failure
end

@testset "DAL-124 restart invariants" begin
    @test isempty(Falsify.RunArtifacts._source_dirty_text(
        " A results/confirmatory-v0.1-prereg-4/execution-state.json\n" *
        " A results/raw/abc/public.json"))
    @test !isempty(Falsify.RunArtifacts._source_dirty_text(
        " A results/confirmatory-v0.1-prereg-4/execution-state.json\n" *
        " M src/Falsify.jl"))
    @test Falsify.classify_run("completed", nothing) == "completed"
    @test Falsify.classify_run("failed", "provider_unavailable") == "infrastructure"
    @test Falsify.classify_run("failed", "rate_limited") == "infrastructure"
    @test Falsify.classify_run("failed", "authentication_failure") == "infrastructure"
    @test Falsify.classify_run("failed", "malformed_api_response") == "infrastructure"
    @test Falsify.classify_run("failed", "invalid_action") == "behavioral_failure"
    @test Falsify.classify_run("failed", "malformed_response") == "behavioral_failure"
    @test Falsify.classify_run("failed", "missing_required_field") == "behavioral_failure"
    @test Falsify.classify_run("failed", "nonfinite_field") == "behavioral_failure"
    @test Falsify.classify_run("aborted", nothing) == "apparatus_failure"
    @test all(code -> Falsify.classify_run("failed", code) == "infrastructure",
        Falsify.PROVIDER_INFRASTRUCTURE_CODES)
    @test !(:apparatus_exception in Symbol.(Falsify.PROVIDER_INFRASTRUCTURE_CODES))
    @test ConfirmatoryV01.retry_decision(["infrastructure"]) == :retry
    @test ConfirmatoryV01.retry_decision(["behavioral_failure"]) == :behavioral_failure
    @test_throws ErrorException ConfirmatoryV01.retry_decision(["apparatus_failure"])

    root = normpath(joinpath(@__DIR__, ".."))
    matrix = ConfirmatoryV01.build_matrix(joinpath(root, "research", "confirmatory-seeds-v0.1-prereg-4.toml"))
    fixed = first(filter(s -> s["policy"] == "fixed_design", matrix))
    random = first(filter(s -> s["policy"] == "random", matrix))
    record(policy, repetition, classification, slot) = (condition_id=slot["condition_id"],
        world_seed=slot["world_seed"], policy_name=policy, repetition_id=repetition, classification=classification)
    @test length(ConfirmatoryV01._attempts_for([record("fixed_design", "fixed", "completed", fixed)], fixed)) == 1
    @test isempty(ConfirmatoryV01._attempts_for([record("random", "random", "completed", random)], fixed))
    @test ConfirmatoryV01.retry_decision(["behavioral_failure"]) == :behavioral_failure
    @test ConfirmatoryV01.retry_decision(["infrastructure"]) == :retry
    @test ConfirmatoryV01.retry_decision(["infrastructure", "infrastructure"]) == :terminal_infrastructure
    @test ConfirmatoryV01.retry_decision(["infrastructure", "completed"]) == :completed
    saved = [merge(copy(s), Dict("status"=>"completed", "run_ids"=>["id"], "retry_status"=>"not_used")) for s in matrix]
    @test ConfirmatoryV01._restore_mutable_slots(matrix, saved)[1]["status"] == "completed"
    corrupted = deepcopy(saved); corrupted[1]["noise_seed"] += 1
    @test_throws ErrorException ConfirmatoryV01._restore_mutable_slots(matrix, corrupted)
    mktempdir() do dir
        run(`git -C $dir init -q`)
        run(`git -C $dir -c user.name=test -c user.email=test@example.com commit --allow-empty -qm init`)
        mkpath(joinpath(dir, "results", "raw")); write(joinpath(dir, "results", "raw", "out"), "ok")
        mkpath(joinpath(dir, "results", "confirmatory-v0.1-prereg-4")); write(joinpath(dir, "results", "confirmatory-v0.1-prereg-4", "state"), "ok")
        @test isempty(ConfirmatoryV01._source_dirty(dir))
        mkpath(joinpath(dir, "results", "raw"))
        write(joinpath(dir, "results", "raw", "example"), "intent to add")
        run(`git -C $dir add -N results/raw/example`)
        @test isempty(ConfirmatoryV01._source_dirty(dir))
        provenance = capture_provenance(string(uuid4()); root=dir)
        @test provenance.dirty_working_tree === false
        provenance = capture_provenance(string(uuid4()); root=dir)
        @test provenance.dirty_working_tree === false
        write(joinpath(dir, "unrelated-source.jl"), "changed")
        @test !isempty(ConfirmatoryV01._source_dirty(dir))
        provenance = capture_provenance(string(uuid4()); root=dir)
        @test provenance.dirty_working_tree === true
    end
end
using JSON3
using HTTP
using Random
using SHA
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
struct SevenThenFail <: AbstractPolicy
    calls::Base.RefValue{Int}
end
function Falsify.next_action(p::SevenThenFail, state::PublicState)
    p.calls[] += 1
    p.calls[] <= 7 || throw(PolicyFailure(:malformed_response))
    Falsify.next_action(FixedDesignPolicy(), state)
end
Falsify.policy_identity(::SevenThenFail) = PolicyIdentity("seven_then_fail")
Falsify.policy_configuration(::SevenThenFail) = (;)

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
    @test req.remaining_decision_opportunities == typemax(Int)
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
        :limits, :action_schema, :remaining_intervention_budget, :remaining_decision_opportunities, :history)
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

@testset "OpenRouter adapter contract" begin
    cfg = load_openrouter_config(joinpath(@__DIR__, "..", "configs", "v0.1-frontier.toml"))
    @test cfg.model == "openai/gpt-5.6-luna"
    @test cfg.provider_order == ["openai"]
    @test !cfg.allow_fallbacks
    treatment = TOML.parsefile(joinpath(@__DIR__, "..", "configs", "v0.1-frontier.toml"))
    @test treatment == Dict("model"=>"openai/gpt-5.6-luna", "provider_order"=>["openai"],
        "allow_fallbacks"=>false, "max_completion_tokens"=>512, "reasoning_effort"=>"medium",
        "prompt_version"=>"scientist-v0-1", "schema_version"=>"experiment-action-v1")
    world = generate_world(912; config=OscillatorConfig(1.0, 3))
    limits = limits_for(public_task(world))
    state = PublicState(policy_task(public_task(world)), limits, (), 8, 16)
    req = model_request(state)
    calls = Ref(0)
    captured = Ref{Any}(nothing)
    response_body = JSON3.write((id="req-abc", model="openai/gpt-5.6-luna-20260929",
        openrouter_metadata=(endpoints=(available=[(provider="OpenAI Flex", model="openai/gpt-5.6-luna", selected=true)], total=1),),
        choices=[(finish_reason="stop", message=(content="""{"initial_displacement_m":0.5,"initial_velocity_m_per_s":0.1,"drive_acceleration_m_per_s2":0.0,"drive_frequency_hz":0.0}""",))],
        usage=(prompt_tokens=22, completion_tokens=9, cost=0.0003)))
    fake_transport = function(url, headers, body)
        calls[] += 1
        captured[] = (url=url, headers=headers, body=body)
        HTTP.Response(200, ["content-type"=>"application/json"], response_body)
    end
    client = OpenRouterClient(cfg; transport=fake_transport, key_getter=()->"secret-test-key")
    policy = ScientistPolicy(client)
    decision = Falsify.next_decision(policy, state)
    @test decision.action == ExperimentAction(initial_displacement_m=0.5, initial_velocity_m_per_s=0.1)
    @test decision.operational_metadata.request_id == "req-abc"
    @test decision.operational_metadata.model == "openai/gpt-5.6-luna-20260929"
    @test decision.operational_metadata.gateway == "openrouter"
    @test decision.operational_metadata.provider == "OpenAI Flex"
    treatment = policy_configuration(client)
    @test treatment.provider_only == ["openai"]
    @test treatment.require_parameters
    @test treatment.response_format == "strict_json_schema"
    @test decision.operational_metadata.input_tokens == 22
    @test decision.operational_metadata.output_tokens == 9
    @test decision.operational_metadata.cost == 0.0003
    @test decision.operational_metadata.finish_reason == "stop"
    @test decision.operational_metadata.latency_s >= 0
    @test decision.operational_metadata.request_sha256 == bytes2hex(sha256(captured[].body))
    @test calls[] == 1
    outbound = JSON3.read(captured[].body)
    @test outbound.model == cfg.model
    @test outbound.provider.order == ["openai"]
    @test outbound.provider.only == ["openai"]
    @test outbound.provider.allow_fallbacks == false
    @test outbound.provider.require_parameters == true
    @test outbound.max_completion_tokens == cfg.max_completion_tokens
    @test !haskey(outbound, :max_tokens)
    @test outbound.usage.include == true
    @test outbound.reasoning.effort == "medium"
    @test any(p -> p.first == "X-OpenRouter-Metadata" && p.second == "enabled", captured[].headers)
    @test outbound.response_format.json_schema.strict == true
    @test Set(String.(keys(outbound.response_format.json_schema.schema.properties))) == Set((
        "initial_displacement_m", "initial_velocity_m_per_s", "drive_acceleration_m_per_s2", "drive_frequency_hz"))
    @test outbound.response_format.json_schema.schema.additionalProperties == false
    @test occursin("remaining_decision_opportunities", captured[].body)
    for forbidden in ("world", "truth", "seed", "evaluator", "provenance", "solver", "held_out", "metric")
        @test !occursin(forbidden, lowercase(captured[].body))
    end
    @test !occursin("secret-test-key", captured[].body)
    @test !occursin("secret-test-key", sprint(showerror, PolicyFailure(:provider_unavailable)))
    @test !occursin("secret-test-key", JSON3.write(Falsify.RunArtifacts._public(
        run_experiment(world, ScientistPolicy(OpenRouterClient(cfg; transport=fake_transport,
            key_getter=()->"secret-test-key")), RunConfig(1)).public)))

    failures = Ref(0)
    error_body = JSON3.write((error=(message="diagnostic must not persist",), openrouter_metadata=(endpoints=(available=[(provider="OpenAI Flex", model="openai/gpt-5.6-luna", selected=true)], total=1),)))
    failing = OpenRouterClient(cfg; key_getter=()->"secret", transport=(args...)->begin
        failures[] += 1
        HTTP.Response(429, error_body)
    end)
    failure = try request(failing, req); nothing catch e; e end
    @test failure isa PolicyFailure
    @test failure.code == :rate_limited
    @test failure.operational_metadata.gateway == "openrouter"
    @test failure.operational_metadata.http_status == 429
    @test failure.operational_metadata.provider == "OpenAI Flex"
    @test !occursin("diagnostic", JSON3.write(failure.operational_metadata))
    @test failure.operational_metadata.request_sha256 !== nothing
    @test failures[] == 1
    missing_key = try request(OpenRouterClient(cfg; key_getter=()->"", transport=fake_transport), req); nothing catch e; e end
    @test missing_key isa PolicyFailure
    @test missing_key.code == :configuration_failure
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
    @test fieldtype(typeof(state), :task) === TaskDescription
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
    @test obs.noise_model == "none"
    @test obs.noise_scale_m == 0.0
    @test [m.displacement_m for m in obs.measurements] == observe(world, to_environment_action(valid)).displacement
end

@testset "controlled observation noise" begin
    @test_throws ArgumentError GaussianObservationNoise(0)
    @test_throws ArgumentError GaussianObservationNoise(-0.1)
    @test_throws ArgumentError GaussianObservationNoise(Inf)
    clean = CleanOscillatorObservation(collect(1.0:1000.0), zeros(1000))
    clean_obs = apply_measurement_process(clean, CleanObservation(), 12, 1)
    @test all(m -> m.displacement_m === 0.0, clean_obs.measurements)
    @test clean_obs.noise_model == "none" && clean_obs.noise_scale_m == 0.0
    noisy = GaussianObservationNoise(0.1)
    a = apply_measurement_process(clean, noisy, 12, 1)
    b = apply_measurement_process(clean, noisy, 12, 1)
    c = apply_measurement_process(clean, noisy, 13, 1)
    eps = [m.displacement_m for m in a.measurements]
    @test eps == [m.displacement_m for m in b.measurements]
    @test eps != [m.displacement_m for m in c.measurements]
    empirical_mean = sum(eps) / length(eps)
    empirical_variance = sum((x - empirical_mean)^2 for x in eps) / (length(eps) - 1)
    @test abs(empirical_mean) < 0.01
    @test empirical_variance ≈ 0.01 atol=0.0015
    @test a.noise_model == "gaussian_additive" && a.noise_scale_m == 0.1
    serialized = JSON3.write(a)
    @test !occursin("noise_seed", serialized)
    @test !hasfield(typeof(a), :clean_measurements)
    @test !hasfield(typeof(a), :noise_seed)
    # Independent local noise generation cannot alter world or policy RNG.
    truth0 = evaluator_truth(generate_world(991))
    apply_measurement_process(clean, noisy, 71, 1)
    @test evaluator_truth(generate_world(991)) == truth0
    policy_state = PublicState(TaskDescription("task"), ActionLimits(displacement_m=(-2.,2.),
        velocity_m_per_s=(-2.,2.), drive_acceleration_m_per_s2=(-1.,1.), drive_frequency_hz=(0.,3.),
        duration_s=1., cadence_s=.5, max_samples=3), (), 2)
    policy_before = next_action(RandomPolicy(827), policy_state)
    apply_measurement_process(clean, noisy, 72, 2)
    @test next_action(RandomPolicy(827), policy_state) == policy_before
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
    @test fixed.public.protocol_settings.observation_noise_disclosed

    noisy_config = RunConfig(2; retry_allowance=1, observation_noise=GaussianObservationNoise(0.1), noise_seed=441)
    noisy_run = run_experiment(world, FixedDesignPolicy(), noisy_config; root=normpath(joinpath(@__DIR__, "..")))
    @test noisy_run.provenance.noise_seed == 441
    @test noisy_run.provenance.configuration.noise_condition == "gaussian"
    @test noisy_run.provenance.configuration.sigma_m == 0.1
    @test noisy_run.public.events[1].observation.noise_model == "gaussian_additive"
    @test noisy_run.public.protocol_settings.observation_noise_disclosed
    @test !occursin("noise_seed", JSON3.write(Falsify.RunArtifacts._public(noisy_run.public)))
    replay_noise = run_experiment(world, FixedDesignPolicy(), noisy_config; root=normpath(joinpath(@__DIR__, "..")))
    @test [e.observation for e in replay_noise.public.events] == [e.observation for e in noisy_run.public.events]

    # Rejected decisions don't consume an accepted-intervention noise index.
    reject_then_accept = SequenceClient(Ref(0), ModelRequest[])
    rejected_noise_run = run_experiment(world, ScientistPolicy(reject_then_accept),
        RunConfig(2; retry_allowance=1, observation_noise=GaussianObservationNoise(0.1), noise_seed=441);
        root=normpath(joinpath(@__DIR__, "..")))
    @test rejected_noise_run.public.events[2].validation_valid === false
    rejected_action = rejected_noise_run.public.events[3].requested_action
    clean_after_reject = observe(world, to_environment_action(rejected_action))
    expected_after_reject = apply_measurement_process(clean_after_reject,
        GaussianObservationNoise(0.1), 441, 2)
    @test rejected_noise_run.public.events[3].observation == expected_after_reject

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
    @test client.requests[1].remaining_decision_opportunities == 3
    @test client.requests[3].remaining_decision_opportunities == 1
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

struct SecondCallThrow <: AbstractPolicy
    calls::Base.RefValue{Int}
end
function Falsify.next_action(p::SecondCallThrow, ::PublicState)
    p.calls[] += 1
    p.calls[] >= 2 && throw(ErrorException("simulated apparatus defect"))
    ExperimentAction(initial_displacement_m=0.2)
end
Falsify.policy_identity(::SecondCallThrow) = PolicyIdentity("second_call_throw")
Falsify.policy_configuration(::SecondCallThrow) = (;)

struct ThrowingIdentityPolicy <: AbstractPolicy end
Falsify.next_action(::ThrowingIdentityPolicy, ::PublicState) = ExperimentAction(initial_displacement_m=0.2)
Falsify.policy_identity(::ThrowingIdentityPolicy) = error("identity defect")
Falsify.policy_configuration(::ThrowingIdentityPolicy) = (;)

@testset "infrastructure failure classification" begin
    world = generate_world(9182; config=OscillatorConfig(1.0, 5))

    # An unexpected (non-PolicyFailure) exception aborts the run durably,
    # preserving the already-executed public history.
    outcome = run_experiment(world, SecondCallThrow(Ref(0)), RunConfig(3);
        root=normpath(joinpath(@__DIR__, "..")))
    @test outcome.public.status == "aborted"
    @test outcome.public.terminal.failure.code == APPARATUS_FAILURE_CODE
    @test outcome.public.terminal.interventions_used == 1
    @test outcome.public.terminal.decision_opportunities_used == 2
    @test outcome.public.terminal.invalid_action_count == 0
    @test length(outcome.public.events) == 2
    @test outcome.public.events[2].failure.code == APPARATUS_FAILURE_CODE
    @test outcome.public.events[2].consumed_intervention == false
    @test outcome.evaluator.failures[1].code == APPARATUS_FAILURE_CODE
    @test outcome.evaluator.failures[1].diagnostic == "ErrorException"
    @test outcome.evaluator.evaluator_metadata.abort_stage == "decision"
    mktempdir() do dir
        path = write_run(dir, outcome.public, outcome.provenance, outcome.evaluator)
        public_text = read(joinpath(path, "public.json"), String)
        @test occursin("apparatus_exception", public_text)
        @test !occursin("ErrorException", public_text)
        @test !occursin("simulated", public_text)
        @test occursin("ErrorException", read(joinpath(path, "evaluator.json"), String))
        metrics = score_run(path)
        @test metrics.run_class == "infrastructure"
        @test isnan(metrics.parameter_error)
        @test isnan(metrics.heldout_prediction_error)
        @test !metrics.success
        @test metrics.completion_status == "aborted"
        @test metrics.interventions_used == 1
        @test metrics.error_improvement_per_intervention === nothing
    end

    # Behavioral PolicyFailure termination is unchanged and stays behavioral.
    mktempdir() do dir
        ledger = joinpath(dir, "ledger.jsonl")
        store = joinpath(dir, "raw")
        attempt = run_attempt(world, ScientistPolicy(MalformedWithMetadata()), RunConfig(3);
            root=normpath(joinpath(@__DIR__, "..")), artifacts_root=store,
            ledger_path=ledger, repetition_id="rep-1", condition_id="clean")
        @test attempt.classification == "behavioral_failure"
        @test attempt.outcome.public.status == "failed"
        @test attempt.artifact_dir !== nothing
        record = JSON3.read(strip(read(ledger, String)))
        @test record.classification == "behavioral_failure"
        @test record.status == "failed"
        @test record.run_id == attempt.run_id
        @test record.condition_id == "clean"
        @test record.noise_seed == 0
        @test record.terminal_failure_code == "malformed_response"
    end

    # A provider outage producing no usable model response is classified
    # infrastructure, not behavioral, at both runner and scoring levels.
    provider_policy = ScientistPolicy(OpenRouterClient(
        load_openrouter_config(joinpath(@__DIR__, "..", "configs", "v0.1-frontier.toml"));
        key_getter=()->"key", transport=(args...) -> throw(ErrorException("connection reset"))))
    attempt, record, provider_metrics = mktempdir() do dir
        ledger = joinpath(dir, "ledger.jsonl")
        attempt = run_attempt(world, provider_policy, RunConfig(3);
            root=normpath(joinpath(@__DIR__, "..")),
            artifacts_root=joinpath(dir, "raw"), ledger_path=ledger)
        (attempt, JSON3.read(strip(read(ledger, String))),
            score_run(attempt.artifact_dir))
    end
    @test attempt.outcome.public.status == "failed"
    @test attempt.outcome.public.terminal.failure.code == "provider_unavailable"
    @test attempt.classification == "infrastructure"
    @test record.classification == "infrastructure"
    @test provider_metrics.run_class == "infrastructure"
    @test isnan(provider_metrics.parameter_error)
    @test isnan(provider_metrics.heldout_prediction_error)
    @test !provider_metrics.success

    # An exception escaping run_experiment finalization still yields a durable
    # aborted record and a ledger line (partial events are not finalizable).
    mktempdir() do dir
        ledger = joinpath(dir, "ledger.jsonl")
        store = joinpath(dir, "raw")
        attempt = run_attempt(world, ThrowingIdentityPolicy(), RunConfig(2);
            root=normpath(joinpath(@__DIR__, "..")), artifacts_root=store,
            ledger_path=ledger)
    @test attempt.classification == "apparatus_failure"
        @test attempt.outcome !== nothing
        @test attempt.outcome.public.status == "aborted"
        @test attempt.outcome.public.policy_identity.name == "unidentified"
        @test isempty(attempt.outcome.public.events)
        @test attempt.artifact_dir !== nothing
        loaded = load_run(attempt.artifact_dir)
        @test loaded.public.status == "aborted"
        @test loaded.evaluator.failures[1].code == APPARATUS_FAILURE_CODE
        @test loaded.evaluator.failures[1].diagnostic == "ErrorException"
        @test loaded.evaluator.evaluator_metadata.unfinalized_events == true
        record = JSON3.read(strip(read(ledger, String)))
        @test record.classification == "apparatus_failure"
        @test record.terminal_failure_code == APPARATUS_FAILURE_CODE
        @test_throws ErrorException ConfirmatoryV01.retry_decision([record.classification])
    end

    # Persistence failure is an apparatus defect, never retry-eligible provider infrastructure.
    mktempdir() do dir
        blocker = joinpath(dir, "not-a-directory")
        write(blocker, "occupied")
        ledger = joinpath(dir, "ledger.jsonl")
        attempt = run_attempt(world, FixedDesignPolicy(), RunConfig(1);
            root=normpath(joinpath(@__DIR__, "..")), artifacts_root=blocker,
            ledger_path=ledger)
        @test attempt.outcome !== nothing
        @test attempt.artifact_dir === nothing
        @test attempt.classification == "apparatus_failure"
        record = JSON3.read(strip(read(ledger, String)))
        @test record.classification == "apparatus_failure"
        @test record.terminal_failure_code == "artifact_persistence_failure"
        @test_throws ErrorException ConfirmatoryV01.retry_decision([record.classification])
        @test record.status == "completed"
        @test record.artifact_dir === nothing
    end

    # A clean supervised attempt records a completed classification.
    mktempdir() do dir
        ledger = joinpath(dir, "ledger.jsonl")
        attempt = run_attempt(world, FixedDesignPolicy(), RunConfig(1);
            root=normpath(joinpath(@__DIR__, "..")), artifacts_root=joinpath(dir, "raw"),
            ledger_path=ledger)
        @test attempt.classification == "completed"
        @test attempt.outcome.public.status == "completed"
        @test score_run(attempt.artifact_dir).run_class == "completed"
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

    # Good partial evidence does not rescue a behaviorally failed run.
    partial_failure = run_experiment(world, SevenThenFail(Ref(0)), RunConfig(8))
    mktempdir() do dir
        path = write_run(dir, partial_failure.public, partial_failure.provenance, partial_failure.evaluator)
        metrics = score_run(path)
        @test metrics.fit_status == :success
        @test metrics.fit_objective_m2 !== nothing
        @test metrics.parameter_error == 1.0
        @test metrics.heldout_prediction_error == 1.0
        @test !metrics.success
        @test metrics.completion_status == "failed"
    end
end
