
module Falsify

using OrdinaryDiffEqTsit5: Tsit5
using Random: MersenneTwister, rand
using SciMLBase: ODEProblem, solve
using JSON3
using SHA

export OscillatorConfig, OscillatorExperiment, CleanOscillatorObservation,
       OscillatorTaskDescription, OscillatorMetadata, OscillatorWorld,
       generate_world, observe, public_task, evaluator_truth, metadata

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
struct OscillatorWorld
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
Base.@kwdef struct ExperimentAction
    initial_displacement_m::Float64 = 1.0
    initial_velocity_m_per_s::Float64 = 0.0
    drive_acceleration_m_per_s2::Float64 = 0.0
    drive_frequency_hz::Float64 = 0.0
end
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
struct Observation
    measurements::Tuple{Vararg{Measurement}}
    noise_model::Union{Nothing,String}
    noise_scale_m::Union{Nothing,Float64}
end
struct TaskDescription
    model_description::String
end
policy_task(task::OscillatorTaskDescription) = TaskDescription(task.model_description)
"""One policy-visible decision, including rejected attempts and safe failures."""
struct DecisionHistoryEntry
    requested_action::Union{Nothing,ExperimentAction}
    validation_valid::Union{Nothing,Bool}
    validation_code::Union{Nothing,Symbol}
    consumed_intervention::Bool
    observation::Union{Nothing,Observation}
    failure_code::Union{Nothing,Symbol}
    remaining_budget::Int
end

struct PublicState
    task::TaskDescription
    limits::ActionLimits
    history::Tuple{Vararg{DecisionHistoryEntry}}
    remaining_budget::Int
    remaining_decision_opportunities::Int
end
PublicState(task, limits, history, remaining_budget) = PublicState(task, limits, history, remaining_budget, typemax(Int))
limits_for(task::OscillatorTaskDescription) = ActionLimits(
    displacement_m=task.displacement_bounds, velocity_m_per_s=task.velocity_bounds,
    drive_acceleration_m_per_s2=task.drive_acceleration_bounds_m_per_s2,
    drive_frequency_hz=task.drive_frequency_bounds_hz, duration_s=task.final_time,
    cadence_s=task.final_time / (task.sample_count - 1), max_samples=task.sample_count)
policy_observation(clean::CleanOscillatorObservation) = Observation(
    Tuple(Measurement(t, x, nothing) for (t, x) in zip(clean.times, clean.displacement)),
    nothing, nothing)
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
struct PolicyDecision
    action::ExperimentAction
    operational_metadata::Union{Nothing,OperationalMetadata}
end
next_decision(policy::AbstractPolicy, state::PublicState) = PolicyDecision(next_action(policy, state), nothing)
struct PolicyFailure <: Exception
    code::Symbol
    operational_metadata::Union{Nothing,OperationalMetadata}
end
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

include("agents/ScientistPolicy.jl")
using .ScientistPolicyAPI: AbstractModelClient, ModelRequest, ModelResponse, ModelMetadata,
     RequestLimits, RequestMeasurement, RequestObservation, RequestHistoryEntry,
      ScientistPolicy, model_request, request, SCIENTIST_PROMPT, PROMPT_VERSION
export AbstractModelClient, ModelRequest, ModelResponse, ModelMetadata,
       RequestLimits, RequestMeasurement, RequestObservation, RequestHistoryEntry,
       ScientistPolicy, model_request, request, SCIENTIST_PROMPT, PROMPT_VERSION
import .ScientistPolicyAPI: next_decision
policy_identity(::ScientistPolicy) = PolicyIdentity("scientist", version=PROMPT_VERSION)
policy_configuration(::ScientistPolicy) = (; prompt_version=PROMPT_VERSION, provider_calls="injected_client")

include("protocol/RunController.jl")
using .RunController: RunConfig, RunOutcome, run_experiment, validate_run_events
export RunConfig, RunOutcome, run_experiment, validate_run_events

include("providers/OpenRouterClient.jl")
using .OpenRouterIntegration: OpenRouterClient, OpenRouterConfig, openrouter_payload, load_openrouter_config
export OpenRouterClient, OpenRouterConfig, openrouter_payload, load_openrouter_config
policy_configuration(policy::ScientistPolicy{<:OpenRouterClient}) = merge(
    (prompt_version=PROMPT_VERSION, prompt_sha256=bytes2hex(SHA.sha256(SCIENTIST_PROMPT)),),
    OpenRouterIntegration.policy_configuration(policy.client))
end
