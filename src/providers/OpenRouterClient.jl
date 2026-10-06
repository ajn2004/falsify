module OpenRouterIntegration

using HTTP
using JSON3
using TOML
using SHA
using ..Falsify: AbstractModelClient, ModelRequest, ModelResponse, ModelMetadata, OperationalMetadata, PolicyFailure
import ..Falsify: request, policy_configuration

export OpenRouterClient, OpenRouterConfig, openrouter_payload, load_openrouter_config

Base.@kwdef struct OpenRouterConfig
    model::String
    provider_order::Vector{String}
    allow_fallbacks::Bool = false
    max_completion_tokens::Int = 512
    reasoning_effort::String = "medium"
    seed::Union{Nothing,Int} = nothing
    prompt_version::String = "scientist-v0-1"
    schema_version::String = "experiment-action-v1"
end

function load_openrouter_config(path::AbstractString)
    d = TOML.parsefile(path)
    OpenRouterConfig(model=d["model"], provider_order=String.(d["provider_order"]),
        allow_fallbacks=d["allow_fallbacks"], max_completion_tokens=d["max_completion_tokens"],
        reasoning_effort=d["reasoning_effort"], seed=get(d,"seed",nothing),
        prompt_version=d["prompt_version"], schema_version=d["schema_version"])
end

struct OpenRouterClient <: AbstractModelClient
    config::OpenRouterConfig
    transport::Function
    key_getter::Function
end
OpenRouterClient(config::OpenRouterConfig; transport=_http_transport,
    key_getter=() -> get(ENV, "OPENROUTER_API_KEY", "")) = OpenRouterClient(config, transport, key_getter)

function _http_transport(url, headers, body)
    HTTP.post(url, headers, body; status_exception=false, readtimeout=120)
end

const ACTION_SCHEMA = Dict("type"=>"object", "properties"=>Dict(
    "initial_displacement_m"=>Dict("type"=>"number"),
    "initial_velocity_m_per_s"=>Dict("type"=>"number"),
    "drive_acceleration_m_per_s2"=>Dict("type"=>"number"),
    "drive_frequency_hz"=>Dict("type"=>"number")),
    "required"=>["initial_displacement_m", "initial_velocity_m_per_s",
        "drive_acceleration_m_per_s2", "drive_frequency_hz"], "additionalProperties"=>false)

function openrouter_payload(config::OpenRouterConfig, req::ModelRequest)
    config.prompt_version == req.prompt_version || throw(PolicyFailure(:configuration_failure))
    user_payload = (task_description=req.task_description,
        action_limits=req.limits,
        remaining_intervention_budget=req.remaining_intervention_budget,
        remaining_decision_opportunities=req.remaining_decision_opportunities,
        public_decision_history=req.history)
    payload = Dict{String,Any}(
        "model"=>config.model,
        "messages"=>[(role="system", content=req.system_instruction),
            (role="user", content=JSON3.write(user_payload))],
        "provider"=>Dict("order"=>config.provider_order, "only"=>config.provider_order,
            "allow_fallbacks"=>config.allow_fallbacks, "require_parameters"=>true),
        "max_completion_tokens"=>config.max_completion_tokens, "reasoning"=>Dict("effort"=>config.reasoning_effort),
        "usage"=>Dict("include"=>true), "stream"=>false,
        "response_format"=>Dict("type"=>"json_schema", "json_schema"=>Dict(
            "name"=>"experiment_action", "strict"=>true, "schema"=>ACTION_SCHEMA)))
    config.seed === nothing || (payload["seed"] = config.seed)
    payload
end

function _number(x)
    x isa Real && !(x isa Bool) ? Int(x) : nothing
end
_str(x) = x isa AbstractString ? String(x) : nothing
_operational(m::ModelMetadata) = OperationalMetadata(gateway=m.gateway, provider=m.provider, model=m.model,
    request_id=m.request_id, input_tokens=m.input_tokens, output_tokens=m.output_tokens, latency_s=m.latency_s,
    cost=m.cost, finish_reason=m.finish_reason, request_sha256=m.request_sha256, http_status=m.http_status)
function request(client::OpenRouterClient, req::ModelRequest)::ModelResponse
    key = try String(client.key_getter()) catch; "" end
    isempty(strip(key)) && throw(PolicyFailure(:configuration_failure))
    body = JSON3.write(openrouter_payload(client.config, req))
    request_hash = bytes2hex(sha256(body))
    headers = ["Authorization"=>"Bearer $key", "Content-Type"=>"application/json", "X-OpenRouter-Metadata"=>"enabled"]
    started = time()
    response = try
        client.transport("https://openrouter.ai/api/v1/chat/completions", headers, body)
    catch
        throw(PolicyFailure(:provider_unavailable, _operational(ModelMetadata(gateway="openrouter", latency_s=time()-started, request_sha256=request_hash))))
    end
    latency = time() - started
    status = response.status
    if status != 200
        code = status == 401 || status == 403 ? :authentication_failure :
            status == 429 ? :rate_limited : (status in (408, 500, 502, 503, 524, 529) ? :provider_unavailable : :provider_rejection)
        throw(PolicyFailure(code, _operational(ModelMetadata(gateway="openrouter", provider="OpenAI", latency_s=latency,
            request_sha256=request_hash, http_status=status))))
    end
    parsed = try JSON3.read(response.body) catch; throw(PolicyFailure(:malformed_api_response,
        _operational(ModelMetadata(gateway="openrouter", latency_s=latency, request_sha256=request_hash, http_status=status)))) end
    try
        choice = parsed.choices[1]
        content = choice.message.content
        content isa AbstractString || throw(ArgumentError("invalid content"))
        usage = haskey(parsed, :usage) ? parsed.usage : nothing
        metadata = ModelMetadata(gateway="openrouter", provider="OpenAI", model=_str(get(parsed, :model, nothing)),
            request_id=_str(get(parsed, :id, nothing)),
            input_tokens=usage === nothing ? nothing : _number(get(usage, :prompt_tokens, nothing)),
            output_tokens=usage === nothing ? nothing : _number(get(usage, :completion_tokens, nothing)),
            latency_s=latency,
            cost=usage === nothing ? nothing : (get(usage, :cost, nothing) isa Real ? Float64(usage.cost) : nothing),
            finish_reason=_str(get(choice, :finish_reason, nothing)), request_sha256=request_hash, http_status=status)
        ModelResponse(content; metadata)
    catch failure
        failure isa PolicyFailure && rethrow()
        throw(PolicyFailure(:malformed_api_response, _operational(ModelMetadata(gateway="openrouter", provider="OpenAI",
            latency_s=latency, request_sha256=request_hash, http_status=status))))
    end
end

policy_configuration(client::OpenRouterClient) = (gateway="openrouter", provider="OpenAI", requested_model=client.config.model,
    provider_order=copy(client.config.provider_order), allow_fallbacks=client.config.allow_fallbacks,
    max_completion_tokens=client.config.max_completion_tokens, reasoning_effort=client.config.reasoning_effort,
    seed=client.config.seed, prompt_version=client.config.prompt_version,
    schema_version=client.config.schema_version)

end
