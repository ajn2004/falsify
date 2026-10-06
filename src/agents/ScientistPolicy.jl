module ScientistPolicyAPI

using ..Falsify: AbstractPolicy, PublicState, ExperimentAction, PolicyDecision, PolicyFailure, OperationalMetadata
import ..Falsify: next_action, next_decision
using ..Falsify: JSON3

export AbstractModelClient, ModelRequest, ModelResponse, ModelMetadata,
       RequestLimits, RequestMeasurement, RequestObservation, RequestHistoryEntry,
        ScientistPolicy, model_request, request, SCIENTIST_PROMPT, PROMPT_VERSION

abstract type AbstractModelClient end

"""Optional provider-neutral operational metadata; absent values are `nothing`."""
Base.@kwdef struct ModelMetadata
    provider::Union{Nothing,String}=nothing
    model::Union{Nothing,String}=nothing
    request_id::Union{Nothing,String}=nothing
    input_tokens::Union{Nothing,Int}=nothing
    output_tokens::Union{Nothing,Int}=nothing
    latency_s::Union{Nothing,Float64}=nothing
    cost::Union{Nothing,Float64}=nothing
    finish_reason::Union{Nothing,String}=nothing
end

struct ModelResponse
    content::String
    metadata::ModelMetadata
end
ModelResponse(content::AbstractString; metadata::ModelMetadata=ModelMetadata()) =
    ModelResponse(String(content), metadata)

"""Explicit, allowlisted model-visible action limits."""
struct RequestLimits
    initial_displacement_m::Tuple{Float64,Float64}
    initial_velocity_m_per_s::Tuple{Float64,Float64}
    drive_acceleration_m_per_s2::Tuple{Float64,Float64}
    drive_frequency_hz::Tuple{Float64,Float64}
    duration_s::Float64
    cadence_s::Float64
    max_samples::Int
end

struct RequestMeasurement
    time_s::Float64
    displacement_m::Float64
    uncertainty_m::Union{Nothing,Float64}
end
struct RequestObservation
    measurements::Tuple{Vararg{RequestMeasurement}}
    noise_model::Union{Nothing,String}
    noise_scale_m::Union{Nothing,Float64}
end
struct RequestHistoryEntry
    requested_action::Union{Nothing,ExperimentAction}
    validation_code::Union{Nothing,String}
    consumed_intervention::Bool
    observation::Union{Nothing,RequestObservation}
    failure_code::Union{Nothing,String}
    remaining_budget::Int
end
function Base.getproperty(entry::RequestHistoryEntry, name::Symbol)
    name === :action && return getfield(entry, :requested_action)
    name === :observation && return getfield(entry, :observation)
    getfield(entry, name)
end

"""Deliberate model DTO. It contains no evaluator/world/provenance references."""
struct ModelRequest
    prompt_version::String
    system_instruction::String
    task_description::String
    limits::RequestLimits
    remaining_intervention_budget::Int
    history::Tuple{Vararg{RequestHistoryEntry}}
end

const PROMPT_VERSION = "scientist-v0-1"
const SCIENTIST_PROMPT = """
You are an experimental scientist. Choose the next experiment for the described physical system.
Select only the four controls in the provided action schema and respect the stated limits and finite remaining intervention budget.
For an unforced experiment, set both drive_acceleration_m_per_s2 and drive_frequency_hz to 0.
For a driven experiment, drive_acceleration_m_per_s2 must be nonzero and drive_frequency_hz must be strictly positive.
Return exactly one JSON object with numeric fields initial_displacement_m, initial_velocity_m_per_s,
drive_acceleration_m_per_s2, and drive_frequency_hz. Do not include any other fields.
Use only the supplied task and observed history; do not claim access to information that was not supplied.
"""

"""Public-safe stable interaction/schema failure, with no raw diagnostic text."""
function request(::AbstractModelClient, ::ModelRequest)::ModelResponse
    throw(MethodError(request, ()))
end

function model_request(state::PublicState)
    l = state.limits
    limits = RequestLimits(l.displacement_m, l.velocity_m_per_s,
        l.drive_acceleration_m_per_s2, l.drive_frequency_hz, l.duration_s,
        l.cadence_s, l.max_samples)
    history = Tuple(RequestHistoryEntry(entry.requested_action,
        entry.validation_code === nothing ? nothing : String(entry.validation_code),
        entry.consumed_intervention,
        entry.observation === nothing ? nothing : RequestObservation(
            Tuple(RequestMeasurement(m.time_s, m.displacement_m, m.uncertainty_m) for m in entry.observation.measurements),
            entry.observation.noise_model, entry.observation.noise_scale_m),
        entry.failure_code === nothing ? nothing : String(entry.failure_code), entry.remaining_budget) for entry in state.history)
    ModelRequest(PROMPT_VERSION, SCIENTIST_PROMPT, state.task.model_description,
        limits, state.remaining_budget, history)
end

struct ScientistPolicy{C<:AbstractModelClient} <: AbstractPolicy
    client::C
end

const ACTION_FIELDS = ("initial_displacement_m", "initial_velocity_m_per_s",
    "drive_acceleration_m_per_s2", "drive_frequency_hz")

function parse_action(content::String)
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
    keys_seen = Set(String(k) for k in keys(parsed))
    for field in ACTION_FIELDS
        field in keys_seen || throw(PolicyFailure(:missing_required_field))
    end
    keys_seen == Set(ACTION_FIELDS) || throw(PolicyFailure(:malformed_response))
    values = Float64[]
    for field in ACTION_FIELDS
        value = parsed[Symbol(field)]
        (value isa Real && !(value isa Bool)) || throw(PolicyFailure(:invalid_field_type))
        number = Float64(value)
        isfinite(number) || throw(PolicyFailure(:nonfinite_field))
        push!(values, number)
    end
    ExperimentAction(initial_displacement_m=values[1], initial_velocity_m_per_s=values[2],
        drive_acceleration_m_per_s2=values[3], drive_frequency_hz=values[4])
end

function next_decision(policy::ScientistPolicy, state::PublicState)
    model_response = try
        request(policy.client, model_request(state))
    catch failure
        failure isa PolicyFailure && rethrow()
        throw(PolicyFailure(:client_failure))
    end
    model_response isa ModelResponse || throw(PolicyFailure(:client_failure))
    metadata = OperationalMetadata(provider=model_response.metadata.provider,
        model=model_response.metadata.model, request_id=model_response.metadata.request_id,
        input_tokens=model_response.metadata.input_tokens, output_tokens=model_response.metadata.output_tokens,
        latency_s=model_response.metadata.latency_s, cost=model_response.metadata.cost,
        finish_reason=model_response.metadata.finish_reason)
    try
        PolicyDecision(parse_action(model_response.content), metadata)
    catch failure
        failure isa PolicyFailure || rethrow()
        throw(PolicyFailure(failure.code, metadata))
    end
end
next_action(policy::ScientistPolicy, state::PublicState) = next_decision(policy, state).action

end
