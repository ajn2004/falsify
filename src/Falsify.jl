
module Falsify

const RUNTIME_OUTPUT_PREFIXES = ("results/raw/", "results/confirmatory-v0.1-prereg-4/")

using OrdinaryDiffEqTsit5: Tsit5
using Random: MersenneTwister, rand, randn
using SciMLBase: ODEProblem, solve
using JSON3
using SHA

export OscillatorConfig, OscillatorExperiment, CleanOscillatorObservation,
       OscillatorTaskDescription, OscillatorMetadata, OscillatorWorld,
       generate_world, observe, public_task, evaluator_truth, metadata

export AbstractEnvironment, AbstractExperimentAction, AbstractPolicyObservation,
       environment_id, environment_version, action_schema, action_schema_version,
       observation_schema_version, parse_action, validate_environment_action,
       execute_experiment, apply_environment_noise, public_action, public_observation,
       environment_provenance, legacy_action_schema, legacy_parse_action, validate_schedule,
       decision_with_parser

export ObservationNoise, CleanObservation, GaussianObservationNoise,
       apply_measurement_process, NOISE_IMPLEMENTATION_VERSION

abstract type ObservationNoise end
"""Private simulator/world abstraction. Only explicit public DTOs cross to policies."""
abstract type AbstractEnvironment end
policy_contract_profile(::AbstractEnvironment) = "scientist-v0-2-schema-driven-v1"
abstract type AbstractExperimentAction end
abstract type AbstractPolicyObservation end

environment_id(::AbstractEnvironment) = throw(MethodError(environment_id, ()))
environment_version(::AbstractEnvironment) = "1"
action_schema_version(::AbstractEnvironment) = "1"
observation_schema_version(::AbstractEnvironment) = "1"
action_schema(::AbstractEnvironment) = throw(MethodError(action_schema, ()))
parse_action(::Type{<:AbstractEnvironment}, ::AbstractString) = throw(MethodError(parse_action, ()))
validate_environment_action(::AbstractEnvironment, ::AbstractExperimentAction) = throw(MethodError(validate_environment_action, ()))
execute_experiment(::AbstractEnvironment, ::AbstractExperimentAction) = throw(MethodError(execute_experiment, ()))
apply_environment_noise(::AbstractEnvironment, clean, noise::ObservationNoise, seed, index) =
    throw(MethodError(apply_environment_noise, ()))
public_action(::AbstractEnvironment, action::AbstractExperimentAction) = throw(MethodError(public_action, ()))
public_observation(::AbstractEnvironment, observation::AbstractPolicyObservation) = throw(MethodError(public_observation, ()))
environment_provenance(::AbstractEnvironment) = (;)
struct CleanObservation <: ObservationNoise end
struct GaussianObservationNoise <: ObservationNoise
    sigma_m::Float64
    function GaussianObservationNoise(sigma_m::Real)
        isfinite(sigma_m) && sigma_m > 0 || throw(ArgumentError("sigma_m must be finite and positive"))
        new(Float64(sigma_m))
    end
end
const NOISE_IMPLEMENTATION_VERSION = "indexed-mt19937-julia-randn-v1"


"""Numerical and sampling configuration. Defaults are part of V0 apparatus."""
struct OscillatorConfig
    final_time::Float64
    sample_count::Int
    reltol::Float64
    abstol::Float64
    function OscillatorConfig(final_time::Real=10.0, sample_count::Integer=101; reltol=1e-9, abstol=1e-11)
        final_time > 0 || throw(ArgumentError("final_time must be positive"))
        sample_count >= 2 || throw(ArgumentError("sample_count must be at least 2"))
        reltol > 0 && abstol > 0 || throw(ArgumentError("solver tolerances must be positive"))
        new(Float64(final_time), Int(sample_count), Float64(reltol), Float64(abstol))
    end
end

"""Environment-native intervention in SI units; drive acceleration is m/s²."""
Base.@kwdef struct OscillatorExperiment
    initial_displacement::Float64 = 1.0
    initial_velocity::Float64 = 0.0
    drive_acceleration_m_per_s2::Float64 = 0.0
    drive_frequency_hz::Float64 = 0.0
end

struct CleanOscillatorObservation
    times::Vector{Float64}
    displacement::Vector{Float64}
end

"""Only protocol-approved information; safe to provide to an experimental policy."""
struct OscillatorTaskDescription
    model_description::String
    final_time::Float64
    sample_count::Int
    displacement_bounds::Tuple{Float64,Float64}
    velocity_bounds::Tuple{Float64,Float64}
    drive_acceleration_bounds_m_per_s2::Tuple{Float64,Float64}
    drive_frequency_bounds_hz::Tuple{Float64,Float64}
end

struct OscillatorMetadata
    solver::String
    reltol::Float64
    abstol::Float64
    world_seed::Int
    package_version::VersionNumber
end

struct OscillatorTruth
    damping_ratio::Float64
    natural_frequency::Float64
end

"""Evaluator-owned world. Do not pass this object to a policy."""
struct OscillatorWorld <: AbstractEnvironment
    truth::OscillatorTruth
    config::OscillatorConfig
    provenance::OscillatorMetadata
end

const ZETA_RANGE = (0.05, 0.40)
const OMEGA_RANGE = (0.80, 2.00)
const X0_RANGE = (-2.0, 2.0)
const V0_RANGE = (-2.0, 2.0)
const DRIVE_ACCELERATION_RANGE = (-1.0, 1.0)
const DRIVE_FREQUENCY_RANGE = (0.0, 3.0)

"""Generate truth using independent, explicit world-generation RNG state."""
function generate_world(seed::Integer; config::OscillatorConfig=OscillatorConfig())
    seed >= 0 || throw(ArgumentError("seed must be nonnegative"))
    rng = MersenneTwister(seed)
    truth = OscillatorTruth(
        ZETA_RANGE[1] + rand(rng) * (ZETA_RANGE[2] - ZETA_RANGE[1]),
        OMEGA_RANGE[1] + rand(rng) * (OMEGA_RANGE[2] - OMEGA_RANGE[1]),
    )
    OscillatorWorld(truth, config, OscillatorMetadata("Tsit5", config.reltol, config.abstol,
        Int(seed), something(Base.pkgversion(@__MODULE__), v"0.0.0")))
end

"""Return policy-visible task information, without seeds, truth, or solver internals."""
public_task(world::OscillatorWorld) = OscillatorTaskDescription(
    "x'' + 2ζω₀x' + ω₀²x = a_d*sin(2πf*t); displacement in meters, time in seconds, drive acceleration in m/s²",
    world.config.final_time, world.config.sample_count, X0_RANGE, V0_RANGE, DRIVE_ACCELERATION_RANGE, DRIVE_FREQUENCY_RANGE)

metadata(world::OscillatorWorld) = world.provenance
environment_provenance(world::OscillatorWorld) = (solver=world.provenance.solver,
    reltol=world.config.reltol, abstol=world.config.abstol,
    final_time_s=world.config.final_time, sample_count=world.config.sample_count)
evaluator_truth(world::OscillatorWorld) = (damping_ratio=world.truth.damping_ratio,
    natural_frequency=world.truth.natural_frequency)

function validate(action::OscillatorExperiment)
    within(value, bounds) = isfinite(value) && bounds[1] <= value <= bounds[2]
    within(action.initial_displacement, X0_RANGE) || throw(ArgumentError("invalid experiment action"))
    within(action.initial_velocity, V0_RANGE) || throw(ArgumentError("invalid experiment action"))
    within(action.drive_acceleration_m_per_s2, DRIVE_ACCELERATION_RANGE) || throw(ArgumentError("invalid experiment action"))
    within(action.drive_frequency_hz, DRIVE_FREQUENCY_RANGE) || throw(ArgumentError("invalid experiment action"))
    nothing
end

"""Run one valid intervention and return the protocol-sampled clean displacement."""
function observe(world::OscillatorWorld, action::OscillatorExperiment)
    validate(action)
    zeta, omega0 = world.truth.damping_ratio, world.truth.natural_frequency
    forcing(t) = action.drive_acceleration_m_per_s2 * sin(2pi * action.drive_frequency_hz * t)
    function oscillator!(du, u, _, t)
        du[1] = u[2]
        du[2] = forcing(t) - 2zeta * omega0 * u[2] - omega0^2 * u[1]
    end
    times = collect(range(0.0, world.config.final_time; length=world.config.sample_count))
    problem = ODEProblem(oscillator!, [action.initial_displacement, action.initial_velocity],
        (0.0, world.config.final_time))
    solution = solve(problem, Tsit5(); saveat=times, reltol=world.config.reltol,
        abstol=world.config.abstol, dense=false)
    CleanOscillatorObservation(times, Float64[point[1] for point in solution.u])
end
export ExperimentAction, to_environment_action, Measurement, Observation, PublicState, ActionLimits,
       TaskDescription, policy_task, ValidationResult, validate_action, AbstractPolicy, next_action, limits_for, policy_observation,
       DecisionHistoryEntry, PolicyDecision, OperationalMetadata, PolicyFailure, policy_seed, next_decision

"""Policy-facing oscillator controls, with SI units explicit in field names."""
Base.@kwdef struct ExperimentAction <: AbstractExperimentAction
    initial_displacement_m::Float64 = 1.0
    initial_velocity_m_per_s::Float64 = 0.0
    drive_acceleration_m_per_s2::Float64 = 0.0
    drive_frequency_hz::Float64 = 0.0
end
const V01_ACTION_SCHEMA = Dict("type"=>"object", "properties"=>Dict(
    "initial_displacement_m"=>Dict("type"=>"number"),
    "initial_velocity_m_per_s"=>Dict("type"=>"number"),
    "drive_acceleration_m_per_s2"=>Dict("type"=>"number"),
    "drive_frequency_hz"=>Dict("type"=>"number")),
    "required"=>["initial_displacement_m", "initial_velocity_m_per_s", "drive_acceleration_m_per_s2", "drive_frequency_hz"],
    "additionalProperties"=>false)
legacy_action_schema() = V01_ACTION_SCHEMA
to_environment_action(a::ExperimentAction) = OscillatorExperiment(
    initial_displacement=a.initial_displacement_m,
    initial_velocity=a.initial_velocity_m_per_s,
    drive_acceleration_m_per_s2=a.drive_acceleration_m_per_s2,
    drive_frequency_hz=a.drive_frequency_hz)

struct ActionLimits
    displacement_m::Tuple{Float64,Float64}
    velocity_m_per_s::Tuple{Float64,Float64}
    drive_acceleration_m_per_s2::Tuple{Float64,Float64}
    drive_frequency_hz::Tuple{Float64,Float64}
    duration_s::Float64
    cadence_s::Float64
    max_samples::Int
    function ActionLimits(; displacement_m, velocity_m_per_s, drive_acceleration_m_per_s2,
            drive_frequency_hz, duration_s, cadence_s, max_samples)
        for (name, bounds) in ((:displacement_m, displacement_m), (:velocity_m_per_s, velocity_m_per_s),
                (:drive_acceleration_m_per_s2, drive_acceleration_m_per_s2), (:drive_frequency_hz, drive_frequency_hz))
            length(bounds) == 2 && all(isfinite, bounds) && bounds[1] <= bounds[2] ||
                throw(ArgumentError("$name must be a finite ordered range"))
        end
        isfinite(duration_s) && duration_s > 0 || throw(ArgumentError("duration_s must be finite and positive"))
        isfinite(cadence_s) && cadence_s > 0 || throw(ArgumentError("cadence_s must be finite and positive"))
        max_samples >= 1 || throw(ArgumentError("max_samples must be positive"))
        new(Tuple(Float64.(displacement_m)), Tuple(Float64.(velocity_m_per_s)),
            Tuple(Float64.(drive_acceleration_m_per_s2)), Tuple(Float64.(drive_frequency_hz)),
            Float64(duration_s), Float64(cadence_s), Int(max_samples))
    end
end
struct ValidationResult
    valid::Bool
    code::Symbol
end
struct Measurement
    time_s::Float64
    displacement_m::Float64
    uncertainty_m::Union{Nothing,Float64}
end
struct Observation <: AbstractPolicyObservation
    measurements::Tuple{Vararg{Measurement}}
    noise_model::Union{Nothing,String}
    noise_scale_m::Union{Nothing,Float64}
end
public_action(::OscillatorWorld, action::ExperimentAction) = action
public_observation(::OscillatorWorld, observation::Observation) = observation
struct TaskDescription
    model_description::String
end
policy_task(task::OscillatorTaskDescription) = TaskDescription(task.model_description)
policy_task(task) = task
"""One policy-visible decision, including rejected attempts and safe failures."""
struct DecisionHistoryEntry
    requested_action::Union{Nothing,AbstractExperimentAction}
    validation_valid::Union{Nothing,Bool}
    validation_code::Union{Nothing,Symbol}
    consumed_intervention::Bool
    observation::Union{Nothing,AbstractPolicyObservation}
    failure_code::Union{Nothing,Symbol}
    remaining_budget::Int
end

struct PublicState{T,L}
    task::T
    limits::L
    history::Tuple
    remaining_budget::Int
    remaining_decision_opportunities::Int
    action_schema::Union{Nothing,AbstractDict}
    policy_contract_profile::String
end
PublicState(task, limits, history, remaining_budget, remaining_decision_opportunities=typemax(Int);
        action_schema=nothing, policy_contract_profile="scientist-v0-1") =
    PublicState(task, limits, history, remaining_budget, remaining_decision_opportunities, action_schema,
        String(policy_contract_profile))
limits_for(task::OscillatorTaskDescription) = ActionLimits(
    displacement_m=task.displacement_bounds, velocity_m_per_s=task.velocity_bounds,
    drive_acceleration_m_per_s2=task.drive_acceleration_bounds_m_per_s2,
    drive_frequency_hz=task.drive_frequency_bounds_hz, duration_s=task.final_time,
    cadence_s=task.final_time / (task.sample_count - 1), max_samples=task.sample_count)
policy_observation(clean::CleanOscillatorObservation) = Observation(
    Tuple(Measurement(t, x, 0.0) for (t, x) in zip(clean.times, clean.displacement)),
    "none", 0.0)
function _noise_stream_seed(seed::Integer, intervention_index::Integer)
    seed >= 0 || throw(ArgumentError("noise seed must be nonnegative"))
    intervention_index > 0 || throw(ArgumentError("intervention index must be positive"))
    Int(mod(BigInt(seed) + BigInt(intervention_index) * 0x9e3779b97f4a7c15, BigInt(typemax(Int))))
end
function apply_measurement_process(clean::CleanOscillatorObservation, ::CleanObservation,
        seed::Integer, intervention_index::Integer)
    seed >= 0 || throw(ArgumentError("noise seed must be nonnegative"))
    intervention_index > 0 || throw(ArgumentError("intervention index must be positive"))
    Observation(Tuple(Measurement(t, x, 0.0) for (t, x) in zip(clean.times, clean.displacement)), "none", 0.0)
end
function apply_measurement_process(clean::CleanOscillatorObservation, noise::GaussianObservationNoise,
        seed::Integer, intervention_index::Integer)
    rng = MersenneTwister(_noise_stream_seed(seed, intervention_index))
    Observation(Tuple(Measurement(t, x + noise.sigma_m * randn(rng), noise.sigma_m)
        for (t, x) in zip(clean.times, clean.displacement)), "gaussian_additive", noise.sigma_m)
end
abstract type AbstractPolicy end
function next_action(::AbstractPolicy, ::PublicState)
    throw(MethodError(next_action, ()))
end
"""Uniform policy-call value with optional provider-neutral operational metadata."""
Base.@kwdef struct OperationalMetadata
    gateway::Union{Nothing,String}=nothing
    provider::Union{Nothing,String}=nothing
    model::Union{Nothing,String}=nothing
    request_id::Union{Nothing,String}=nothing
    input_tokens::Union{Nothing,Int}=nothing
    output_tokens::Union{Nothing,Int}=nothing
    latency_s::Union{Nothing,Float64}=nothing
    cost::Union{Nothing,Float64}=nothing
    finish_reason::Union{Nothing,String}=nothing
    request_sha256::Union{Nothing,String}=nothing
    http_status::Union{Nothing,Int}=nothing
end
struct PolicyDecision{A<:AbstractExperimentAction}
    action::A
    operational_metadata::Union{Nothing,OperationalMetadata}
end
next_decision(policy::AbstractPolicy, state::PublicState) = PolicyDecision(next_action(policy, state), nothing)
decision_with_parser(policy::AbstractPolicy, state::PublicState, parser::Function) = next_decision(policy, state)
struct PolicyFailure <: Exception
    code::Symbol
    operational_metadata::Union{Nothing,OperationalMetadata}
end
function parse_action(::Type{OscillatorWorld}, content::AbstractString)
    parsed = try
        JSON3.read(content)
    catch
        if occursin(r"\b(?:NaN|[-+]?Infinity)\b", content) || any(eachmatch(r":\s*(-?\d+(?:\.\d+)?[eE][+-]?\d+)", content)) do m
                value = tryparse(BigFloat, m.captures[1])
                value !== nothing && !isfinite(Float64(value))
            end
            throw(PolicyFailure(:nonfinite_field))
        end
        throw(PolicyFailure(:malformed_response))
    end
    parsed isa JSON3.Object || throw(PolicyFailure(:malformed_response))
    fields = ("initial_displacement_m", "initial_velocity_m_per_s",
        "drive_acceleration_m_per_s2", "drive_frequency_hz")
    keys_seen = Set(String(k) for k in keys(parsed))
    any(field -> !(field in keys_seen), fields) && throw(PolicyFailure(:missing_required_field))
    keys_seen == Set(fields) || throw(PolicyFailure(:malformed_response))
    values = Float64[]
    for field in fields
        value = parsed[Symbol(field)]
        value isa Real && !(value isa Bool) || throw(PolicyFailure(:invalid_field_type))
        number = Float64(value)
        isfinite(number) || throw(PolicyFailure(:nonfinite_field))
        push!(values, number)
    end
    ExperimentAction(initial_displacement_m=values[1], initial_velocity_m_per_s=values[2],
        drive_acceleration_m_per_s2=values[3], drive_frequency_hz=values[4])
end
legacy_parse_action(content::AbstractString) = parse_action(OscillatorWorld, content)
PolicyFailure(code::Symbol) = PolicyFailure(code, nothing)
Base.showerror(io::IO, failure::PolicyFailure) = print(io, "policy failure: ", failure.code)
policy_seed(::AbstractPolicy) = nothing
function validate_action(a::ExperimentAction, state::PublicState)
    l = state.limits
    inrange(x, r) = isfinite(x) && r[1] <= x <= r[2]
    if state.remaining_budget <= 0
        return ValidationResult(false, :budget_exhausted)
    elseif !all((inrange(a.initial_displacement_m, l.displacement_m),
                 inrange(a.initial_velocity_m_per_s, l.velocity_m_per_s),
                 inrange(a.drive_acceleration_m_per_s2, l.drive_acceleration_m_per_s2),
                 inrange(a.drive_frequency_hz, l.drive_frequency_hz)))
        return ValidationResult(false, :out_of_bounds)
    elseif a.drive_acceleration_m_per_s2 == 0 && a.drive_frequency_hz != 0
        return ValidationResult(false, :invalid_drive)
    elseif a.drive_acceleration_m_per_s2 != 0 && a.drive_frequency_hz <= 0
        return ValidationResult(false, :invalid_drive)
    elseif l.cadence_s <= 0 || l.duration_s <= 0 || l.max_samples < 1
        return ValidationResult(false, :invalid_schedule)
    elseif floor(Int, l.duration_s / l.cadence_s) + 1 > l.max_samples
        return ValidationResult(false, :sample_budget_exceeded)
    end
    ValidationResult(true, :accepted)
end
function validate_schedule(limits)
    hasproperty(limits, :duration_s) && hasproperty(limits, :cadence_s) && hasproperty(limits, :max_samples) ||
        return ValidationResult(false, :invalid_schedule)
    d, c, n = limits.duration_s, limits.cadence_s, limits.max_samples
    (isfinite(d) && d > 0 && isfinite(c) && c > 0 && n >= 1) || return ValidationResult(false, :invalid_schedule)
    floor(Int, d / c) + 1 <= n || return ValidationResult(false, :sample_budget_exceeded)
    ValidationResult(true, :accepted)
end

environment_id(::OscillatorWorld) = "damped_oscillator_v0_1"
policy_contract_profile(::OscillatorWorld) = "scientist-v0-1"
action_schema(::OscillatorWorld) = legacy_action_schema()
validate_environment_action(::OscillatorWorld, action::ExperimentAction) =
    _validate_oscillator_environment_action(action)
function _validate_oscillator_environment_action(a::ExperimentAction)
    inrange(x, bounds) = isfinite(x) && bounds[1] <= x <= bounds[2]
    all((inrange(a.initial_displacement_m, X0_RANGE), inrange(a.initial_velocity_m_per_s, V0_RANGE),
        inrange(a.drive_acceleration_m_per_s2, DRIVE_ACCELERATION_RANGE), inrange(a.drive_frequency_hz, DRIVE_FREQUENCY_RANGE))) ||
        return ValidationResult(false, :out_of_bounds)
    (a.drive_acceleration_m_per_s2 == 0 && a.drive_frequency_hz != 0) && return ValidationResult(false, :invalid_drive)
    (a.drive_acceleration_m_per_s2 != 0 && a.drive_frequency_hz <= 0) && return ValidationResult(false, :invalid_drive)
    ValidationResult(true, :accepted)
end
execute_experiment(world::OscillatorWorld, action::ExperimentAction) = observe(world, to_environment_action(action))
apply_environment_noise(::OscillatorWorld, clean::CleanOscillatorObservation, noise::ObservationNoise, seed, index) =
    apply_measurement_process(clean, noise, seed, index)

include("artifacts/RunArtifacts.jl")
using .RunArtifacts: PublicRunArtifact, ProvenanceArtifact, EvaluatorArtifact,
    RunEvent, PublicFailure, EvaluatorFailure, TerminalResult, new_run_id, capture_provenance,
    ArtifactActionLimits, ProtocolSettings, PolicyIdentity, artifact_limits, evaluator_artifact, write_run, load_run
export PublicRunArtifact, ProvenanceArtifact, EvaluatorArtifact, RunEvent,
        PublicFailure, EvaluatorFailure, TerminalResult, ArtifactActionLimits, ProtocolSettings,
       PolicyIdentity, artifact_limits, new_run_id, capture_provenance, evaluator_artifact, write_run, load_run
include("baselines/RandomPolicy.jl")
include("baselines/FixedDesignPolicy.jl")
export RandomPolicy, FixedDesignPolicy, policy_identity, policy_configuration
policy_identity(policy, ::AbstractEnvironment) = policy_identity(policy)

include("agents/ScientistPolicy.jl")
using .ScientistPolicyAPI: AbstractModelClient, ModelRequest, ModelResponse, ModelMetadata,
      RequestLimits, RequestMeasurement, RequestObservation, RequestHistoryEntry,
       ScientistPolicy, model_request, request, SCIENTIST_PROMPT, PROMPT_VERSION,
       GENERIC_SCIENTIST_PROMPT, GENERIC_PROMPT_VERSION
export AbstractModelClient, ModelRequest, ModelResponse, ModelMetadata,
       RequestLimits, RequestMeasurement, RequestObservation, RequestHistoryEntry,
       ScientistPolicy, model_request, request, SCIENTIST_PROMPT, PROMPT_VERSION,
       GENERIC_SCIENTIST_PROMPT, GENERIC_PROMPT_VERSION
import .ScientistPolicyAPI: next_decision
policy_identity(::ScientistPolicy) = PolicyIdentity("scientist", version=PROMPT_VERSION)
policy_identity(::ScientistPolicy, world::AbstractEnvironment) = PolicyIdentity("scientist",
    version=policy_contract_profile(world))
_scientist_policy_configuration() = (; prompt_version=PROMPT_VERSION,
    generic_prompt_version=GENERIC_PROMPT_VERSION,
    prompt_selection="v0.1 compatibility schema uses frozen prompt; other schemas use generic prompt",
    prompt_sha256=bytes2hex(SHA.sha256(SCIENTIST_PROMPT)),
    generic_prompt_sha256=bytes2hex(SHA.sha256(GENERIC_SCIENTIST_PROMPT)),
    provider_calls="injected_client")
policy_configuration(::ScientistPolicy) = _scientist_policy_configuration()

include("protocol/RunController.jl")
using .RunController: RunConfig, RunOutcome, RunAttempt, run_experiment, run_attempt,
    validate_run_events, APPARATUS_FAILURE_CODE, PROVIDER_INFRASTRUCTURE_CODES, classify_run
export RunConfig, RunOutcome, RunAttempt, run_experiment, run_attempt,
    validate_run_events, APPARATUS_FAILURE_CODE, PROVIDER_INFRASTRUCTURE_CODES, classify_run

include("evaluation/SystemIdentification.jl")
include("evaluation/Metrics.jl")
using .Metrics: RunMetrics, MetricConfig, HELDOUT_PROBES, score_run
export RunMetrics, MetricConfig, HELDOUT_PROBES, score_run

include("providers/OpenRouterClient.jl")
using .OpenRouterIntegration: OpenRouterClient, OpenRouterConfig, openrouter_payload, load_openrouter_config
export OpenRouterClient, OpenRouterConfig, openrouter_payload, load_openrouter_config
policy_configuration(policy::ScientistPolicy{<:OpenRouterClient}) = merge(
    _scientist_policy_configuration(),
    OpenRouterIntegration.policy_configuration(policy.client))
end
