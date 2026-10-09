module ScientistPolicyAPI

using ..Falsify: AbstractPolicy, AbstractExperimentAction, AbstractPolicyObservation, PublicState, ActionLimits, PolicyDecision, PolicyFailure, OperationalMetadata, legacy_action_schema, legacy_parse_action
import ..Falsify: next_action, next_decision, decision_with_parser

export AbstractModelClient, ModelRequest, ModelResponse, ModelMetadata,
       RequestLimits, RequestMeasurement, RequestObservation, RequestHistoryEntry,
        ScientistPolicy, model_request, request, SCIENTIST_PROMPT, PROMPT_VERSION

abstract type AbstractModelClient end

"""Optional provider-neutral operational metadata; absent values are `nothing`."""
Base.@kwdef struct ModelMetadata
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
struct RequestObservation <: AbstractPolicyObservation
    measurements::Tuple{Vararg{RequestMeasurement}}
    noise_model::Union{Nothing,String}
    noise_scale_m::Union{Nothing,Float64}
end
struct RequestHistoryEntry
    requested_action::Union{Nothing,AbstractExperimentAction}
    validation_code::Union{Nothing,String}
    consumed_intervention::Bool
    observation::Union{Nothing,AbstractPolicyObservation}
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
    limits::Union{RequestLimits,NamedTuple}
    action_schema::AbstractDict
    remaining_intervention_budget::Int
    remaining_decision_opportunities::Int
    history::Tuple{Vararg{RequestHistoryEntry}}
end

const PROMPT_VERSION = "scientist-v0-1"
const GENERIC_PROMPT_VERSION = "scientist-v0-2-schema-driven-v1"
const GENERIC_SCIENTIST_PROMPT = """
You are an experimental scientist. Choose the next experiment for the described physical system.
Use only the supplied task, action schema, limits, and observed history. Respect the finite remaining intervention budget.
Return exactly one JSON object conforming to the supplied strict action schema. Do not include any other fields.
Do not claim access to information that was not supplied.
"""
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
    limits = l isa ActionLimits ? RequestLimits(l.displacement_m, l.velocity_m_per_s,
        l.drive_acceleration_m_per_s2, l.drive_frequency_hz, l.duration_s,
        l.cadence_s, l.max_samples) : l
    history = Tuple(RequestHistoryEntry(entry.requested_action,
        entry.validation_code === nothing ? nothing : String(entry.validation_code),
        entry.consumed_intervention,
        entry.observation === nothing ? nothing : (hasproperty(entry.observation, :measurements) &&
            !isempty(entry.observation.measurements) && hasproperty(first(entry.observation.measurements), :displacement_m) ? RequestObservation(
            Tuple(RequestMeasurement(m.time_s, m.displacement_m, m.uncertainty_m) for m in entry.observation.measurements),
            entry.observation.noise_model, entry.observation.noise_scale_m) : entry.observation),
        entry.failure_code === nothing ? nothing : String(entry.failure_code), entry.remaining_budget) for entry in state.history)
    legacy_prompt = state.policy_contract_profile == PROMPT_VERSION
    prompt_version = legacy_prompt ? PROMPT_VERSION : GENERIC_PROMPT_VERSION
    prompt = legacy_prompt ? SCIENTIST_PROMPT : GENERIC_SCIENTIST_PROMPT
    ModelRequest(prompt_version, prompt, state.task.model_description,
        limits, state.action_schema === nothing ? legacy_action_schema() : state.action_schema,
        state.remaining_budget, state.remaining_decision_opportunities, history)
end

struct ScientistPolicy{C<:AbstractModelClient} <: AbstractPolicy
    client::C
end

next_decision(policy::ScientistPolicy, state::PublicState) =
    _next_decision(policy, state, legacy_parse_action)
decision_with_parser(policy::ScientistPolicy, state::PublicState, parser::Function) =
    _next_decision(policy, state, parser)

function _next_decision(policy::ScientistPolicy, state::PublicState, parser::Function)
    model_response = try
        request(policy.client, model_request(state))
    catch failure
        failure isa PolicyFailure && rethrow()
        throw(PolicyFailure(:client_failure))
    end
    model_response isa ModelResponse || throw(PolicyFailure(:client_failure))
    metadata = OperationalMetadata(gateway=model_response.metadata.gateway, provider=model_response.metadata.provider,
        model=model_response.metadata.model, request_id=model_response.metadata.request_id,
        input_tokens=model_response.metadata.input_tokens, output_tokens=model_response.metadata.output_tokens,
        latency_s=model_response.metadata.latency_s, cost=model_response.metadata.cost,
        finish_reason=model_response.metadata.finish_reason,
        request_sha256=model_response.metadata.request_sha256, http_status=model_response.metadata.http_status)
    try
        action = parser(model_response.content)
        PolicyDecision(action, metadata)
    catch failure
        failure isa PolicyFailure || rethrow()
        throw(PolicyFailure(failure.code, metadata))
    end
end
next_action(policy::ScientistPolicy, state::PublicState) = next_decision(policy, state).action

end
