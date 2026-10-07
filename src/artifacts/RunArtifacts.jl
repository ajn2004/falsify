module RunArtifacts

using Dates
using JSON3
using SHA
using UUIDs
import ..Falsify: ActionLimits, ExperimentAction, Observation, OscillatorWorld, OperationalMetadata, evaluator_truth, metadata

export PublicRunArtifact, ProvenanceArtifact, EvaluatorArtifact, RunEvent,
       PublicFailure, EvaluatorFailure, TerminalResult, ArtifactActionLimits, ProtocolSettings,
       PolicyIdentity, artifact_limits, new_run_id, capture_provenance, evaluator_artifact, write_run, load_run

const SCHEMA_VERSION = 1
const STATUSES = ("running", "completed", "failed", "aborted")

"""One sanitized failure; never store exception objects or stack traces here."""
struct PublicFailure
    code::String
    public_message::Union{Nothing,String}
    stage_index::Union{Nothing,Int}
    function PublicFailure(code; public_message=nothing, stage_index=nothing)
        occursin(r"^[a-z][a-z0-9_]*$", code) || throw(ArgumentError("failure code must be stable snake_case"))
        new(String(code), public_message, stage_index)
    end
end

struct EvaluatorFailure
    code::String
    diagnostic::Union{Nothing,String}
    stage_index::Union{Nothing,Int}
    function EvaluatorFailure(code; diagnostic=nothing, stage_index=nothing)
        occursin(r"^[a-z][a-z0-9_]*$", code) || throw(ArgumentError("failure code must be stable snake_case"))
        new(String(code), diagnostic, stage_index)
    end
end

"""A deliberately small tagged decision record, extensible for later provider events."""
struct RunEvent
    sequence::Int
    requested_action::Union{Nothing,ExperimentAction}
    validation_valid::Union{Nothing,Bool}
    validation_code::Union{Nothing,String}
    consumed_intervention::Bool
    observation::Union{Nothing,Observation}
    remaining_budget::Int
    status::String
    elapsed_seconds::Union{Nothing,Float64}
    failure::Union{Nothing,PublicFailure}
    operational_metadata::Union{Nothing,OperationalMetadata}
end
RunEvent(sequence, requested_action, validation_valid, validation_code, consumed_intervention,
    observation, remaining_budget, status, elapsed_seconds, failure) = RunEvent(sequence,
    requested_action, validation_valid, validation_code, consumed_intervention, observation,
    remaining_budget, status, elapsed_seconds, failure, nothing)

struct TerminalResult
    status::String
    final_output::Nothing
    failure::Union{Nothing,PublicFailure}
    interventions_used::Int
    decision_opportunities_used::Int
    invalid_action_count::Int
end

struct ArtifactActionLimits
    displacement_m::Tuple{Float64,Float64}
    velocity_m_per_s::Tuple{Float64,Float64}
    drive_acceleration_m_per_s2::Tuple{Float64,Float64}
    drive_frequency_hz::Tuple{Float64,Float64}
    duration_s::Float64
    cadence_s::Float64
    max_samples::Int
end
artifact_limits(l::ActionLimits) = ArtifactActionLimits(l.displacement_m, l.velocity_m_per_s,
    l.drive_acceleration_m_per_s2, l.drive_frequency_hz, l.duration_s, l.cadence_s, l.max_samples)

struct ProtocolSettings
    observation_noise_disclosed::Bool
end
struct PolicyIdentity
    name::String
    version::Union{Nothing,String}
    PolicyIdentity(name; version=nothing) = new(String(name), version === nothing ? nothing : String(version))
end

"""Public allowlist. No environment/world/provenance object is accepted here."""
struct PublicRunArtifact
    run_id::String
    experiment_version::String
    created_at::String
    finalized_at::Union{Nothing,String}
    status::String
    task_description::String
    action_limits::ArtifactActionLimits
    intervention_budget::Int
    protocol_settings::ProtocolSettings
    policy_identity::PolicyIdentity
    events::Tuple{Vararg{RunEvent}}
    terminal::Union{Nothing,TerminalResult}
    function PublicRunArtifact(; run_id=new_run_id(), experiment_version="v0",
            created_at=string(now(UTC)), finalized_at=nothing, status="running",
            task_description, action_limits, intervention_budget, protocol_settings,
            policy_identity, events=(), terminal=nothing)
        _validate_run_id(run_id); status in STATUSES || throw(ArgumentError("unsupported run status"))
        intervention_budget >= 0 || throw(ArgumentError("budget must be nonnegative"))
        new(String(run_id), String(experiment_version), String(created_at), finalized_at,
            String(status), String(task_description), action_limits, Int(intervention_budget),
            protocol_settings, policy_identity, Tuple(events), terminal)
    end
end

struct ProvenanceArtifact
    schema_version::Int
    run_id::String
    git_commit::Union{Nothing,String}
    dirty_working_tree::Union{Nothing,Bool}
    julia_version::String
    package_version::String
    manifest_sha256::Union{Nothing,String}
    platform::String
    world_seed::Union{Nothing,Int}
    noise_seed::Union{Nothing,Int}
    policy_seed::Union{Nothing,Int}
    repetition_id::Union{Nothing,String}
    configuration::NamedTuple
end

"""Evaluator-only DTO explicitly constructed from the hidden world."""
struct EvaluatorArtifact
    schema_version::Int
    run_id::String
    damping_ratio::Float64
    natural_frequency_rad_s::Float64
    condition_id::Union{Nothing,String}
    evaluator_metadata::NamedTuple
    failures::Tuple{Vararg{EvaluatorFailure}}
end

new_run_id() = string(uuid4())
function _validate_run_id(id)
    try UUID(id) catch; throw(ArgumentError("run_id must be an opaque UUID")) end
    nothing
end

function _git_value(root, args...)
    try
        cmd = Cmd(["git", "-C", String(root), String.(args)...])
        strip(read(pipeline(cmd; stderr=devnull), String))
    catch
        nothing
    end
end

function _repository_value(root, git_args...)
    value = _git_value(root, git_args...)
    value === nothing || return value
    # The project is maintained in Jujutsu workspaces which may not have a
    # colocated .git directory. Keep provenance useful there without guessing.
    args = git_args == ("rev-parse", "HEAD") ? ["log", "--no-graph", "-r", "@", "-T", "commit_id"] :
        git_args == ("status", "--porcelain") ? ["status"] : String[]
    isempty(args) && return nothing
    try
        text = strip(read(pipeline(Cmd(["jj", "-R", String(root), args...]); stderr=devnull), String))
        git_args == ("status", "--porcelain") && return occursin("working copy has no changes", text) ? "" : text
        isempty(text) ? nothing : text
    catch
        nothing
    end
end

function _source_dirty_text(text)
    prefixes = ("results/raw/", "results/confirmatory-v0.1/")
    filter(line -> begin
        length(line) >= 4 || return true
        path = replace(line[4:end], r"^\"|\"$" => "")
        !any(prefix -> startswith(path, prefix), prefixes)
    end, split(text, '\n'; keepempty=false)) |> lines -> join(lines, "\n")
end

"""Capture best-effort host/repository provenance. Unknown Git state remains `nothing`."""
function capture_provenance(run_id::String; root=pwd(), world=nothing, world_seed=nothing, noise_seed=nothing,
        policy_seed=nothing, repetition_id=nothing, configuration=(;))
    _validate_run_id(run_id)
    if world !== nothing
        world isa OscillatorWorld || throw(ArgumentError("world must be an OscillatorWorld"))
        actual_seed = metadata(world).world_seed
        world_seed !== nothing && world_seed != actual_seed &&
            throw(ArgumentError("world_seed conflicts with world provenance"))
        world_seed = actual_seed
        config = world.config
        environment = (solver=metadata(world).solver, reltol=config.reltol, abstol=config.abstol,
            final_time_s=config.final_time, sample_count=config.sample_count)
        configuration = merge(configuration, environment)
    end
    commit = _repository_value(root, "rev-parse", "HEAD")
    dirty_text = _repository_value(root, "status", "--porcelain")
    dirty_text === nothing || (dirty_text = _source_dirty_text(dirty_text))
    manifest = joinpath(root, "Manifest.toml")
    manifest_hash = isfile(manifest) ? bytes2hex(sha256(read(manifest))) : nothing
    ProvenanceArtifact(SCHEMA_VERSION, run_id, commit, dirty_text === nothing ? nothing : !isempty(dirty_text),
        string(VERSION), string(Base.pkgversion(parentmodule(@__MODULE__))), manifest_hash,
        string(Sys.KERNEL, "-", Sys.ARCH), world_seed, noise_seed, policy_seed,
        repetition_id, configuration)
end

evaluator_artifact(world::OscillatorWorld, run_id; condition_id=nothing, evaluator_metadata=(;), failures=EvaluatorFailure[]) = begin
    t = evaluator_truth(world)
    EvaluatorArtifact(SCHEMA_VERSION, run_id, t.damping_ratio, t.natural_frequency,
        condition_id, evaluator_metadata, Tuple(failures))
end

_dict(x::NamedTuple) = Dict(string(k) => v for (k,v) in pairs(x))
_dict(x::OperationalMetadata) = Dict(string(k) => getfield(x, k) for k in fieldnames(OperationalMetadata))
_dict(x::ArtifactActionLimits) = Dict(string(k) => getfield(x, k) for k in fieldnames(ArtifactActionLimits))
_dict(x::ProtocolSettings) = Dict(string(k) => getfield(x, k) for k in fieldnames(ProtocolSettings))
_dict(x::PolicyIdentity) = Dict(string(k) => getfield(x, k) for k in fieldnames(PolicyIdentity))
_failure(x) = x === nothing ? nothing : Dict("code"=>x.code, "public_message"=>x.public_message,
    "stage_index"=>x.stage_index)
_evaluator_failure(x) = x === nothing ? nothing : Dict("code"=>x.code,
    "stage_index"=>x.stage_index, "diagnostic"=>x.diagnostic)
_action(x) = x === nothing ? nothing : Dict("initial_displacement_m"=>x.initial_displacement_m,
    "initial_velocity_m_per_s"=>x.initial_velocity_m_per_s,
    "drive_acceleration_m_per_s2"=>x.drive_acceleration_m_per_s2, "drive_frequency_hz"=>x.drive_frequency_hz)
_observation(x) = x === nothing ? nothing : Dict("measurements"=>[Dict("time_s"=>m.time_s,
    "displacement_m"=>m.displacement_m, "uncertainty_m"=>m.uncertainty_m) for m in x.measurements],
    "noise_model"=>x.noise_model, "noise_scale_m"=>x.noise_scale_m)
_event(e) = Dict("sequence"=>e.sequence, "requested_action"=>_action(e.requested_action),
    "validation_valid"=>e.validation_valid, "validation_code"=>e.validation_code,
    "consumed_intervention"=>e.consumed_intervention, "observation"=>_observation(e.observation),
    "remaining_budget"=>e.remaining_budget, "status"=>e.status,
    "elapsed_seconds"=>e.elapsed_seconds, "failure"=>_failure(e.failure),
    "operational_metadata"=>e.operational_metadata === nothing ? nothing : _dict(e.operational_metadata))
_terminal(t) = t === nothing ? nothing : Dict("status"=>t.status, "final_output"=>t.final_output,
    "failure"=>_failure(t.failure), "interventions_used"=>t.interventions_used,
    "decision_opportunities_used"=>t.decision_opportunities_used, "invalid_action_count"=>t.invalid_action_count)

function _public(a)
    Dict("schema_version"=>SCHEMA_VERSION, "run_id"=>a.run_id, "experiment_version"=>a.experiment_version,
        "created_at"=>a.created_at, "finalized_at"=>a.finalized_at, "status"=>a.status,
        "task_description"=>a.task_description, "action_limits"=>_dict(a.action_limits),
        "intervention_budget"=>a.intervention_budget, "protocol_settings"=>_dict(a.protocol_settings),
        "policy_identity"=>_dict(a.policy_identity), "events"=>_event.(a.events), "terminal"=>_terminal(a.terminal))
end
_provenance(p) = Dict("schema_version"=>p.schema_version, "run_id"=>p.run_id,
    "git_commit"=>p.git_commit, "dirty_working_tree"=>p.dirty_working_tree,
    "julia_version"=>p.julia_version, "package_version"=>p.package_version,
    "manifest_sha256"=>p.manifest_sha256, "platform"=>p.platform,
    "world_seed"=>p.world_seed, "noise_seed"=>p.noise_seed, "policy_seed"=>p.policy_seed,
    "repetition_id"=>p.repetition_id, "configuration"=>_dict(p.configuration))
_evaluator(e) = Dict("schema_version"=>e.schema_version, "run_id"=>e.run_id,
    "truth"=>Dict("damping_ratio"=>e.damping_ratio, "natural_frequency_rad_s"=>e.natural_frequency_rad_s),
    "condition_id"=>e.condition_id, "evaluator_metadata"=>_dict(e.evaluator_metadata),
    "failures"=>_evaluator_failure.(e.failures))

function write_run(root::AbstractString, public::PublicRunArtifact, provenance::ProvenanceArtifact,
        evaluator::EvaluatorArtifact)
    provenance.schema_version == SCHEMA_VERSION || throw(ArgumentError("unsupported provenance schema version"))
    evaluator.schema_version == SCHEMA_VERSION || throw(ArgumentError("unsupported evaluator schema version"))
    public.run_id == provenance.run_id == evaluator.run_id || throw(ArgumentError("run IDs must match"))
    public.status != "running" || throw(ArgumentError("only finalized runs may be written"))
    public.terminal === nothing && throw(ArgumentError("finalized runs require a terminal result"))
    public.finalized_at === nothing && throw(ArgumentError("finalized runs require finalized_at"))
    public.terminal.status == public.status || throw(ArgumentError("terminal and public status must match"))
    counts = (public.terminal.interventions_used, public.terminal.decision_opportunities_used,
        public.terminal.invalid_action_count)
    all(>=(0), counts) || throw(ArgumentError("terminal counts must be nonnegative"))
    for (i, event) in enumerate(public.events)
        event.sequence == i || throw(ArgumentError("event sequences must be contiguous from 1"))
        0 <= event.remaining_budget <= public.intervention_budget || throw(ArgumentError("invalid remaining budget"))
        event.elapsed_seconds === nothing || (isfinite(event.elapsed_seconds) && event.elapsed_seconds >= 0) ||
            throw(ArgumentError("elapsed time must be finite and nonnegative"))
    end
    dir = joinpath(root, public.run_id)
    ispath(dir) && throw(ArgumentError("run artifact already exists: $dir"))
    mkpath(root)
    mkdir(dir) # exclusive creation prevents replacing an existing run directory
    try
        for (name, value) in (("public.json", _public(public)), ("provenance.json", _provenance(provenance)),
                ("evaluator.json", _evaluator(evaluator)))
            open(joinpath(dir, name), "w") do io
                write(io, JSON3.write(value)); write(io, '\n'); flush(io)
            end
        end
    catch
        # Preserve partial evidence; never delete or replace an attempted run.
        rethrow()
    end
    dir
end

function _load(path)
    x = JSON3.read(read(path, String))
    haskey(x, :schema_version) || throw(ArgumentError("artifact missing schema_version"))
    x.schema_version == SCHEMA_VERSION || throw(ArgumentError("unsupported artifact schema version: $(x.schema_version)"))
    required = basename(path) == "public.json" ?
        (:run_id, :status, :task_description, :action_limits, :intervention_budget, :events, :terminal) :
        basename(path) == "provenance.json" ?
        (:run_id, :git_commit, :julia_version, :package_version, :world_seed, :noise_seed, :policy_seed) :
        (:run_id, :truth, :condition_id, :evaluator_metadata)
    missing = filter(key -> !haskey(x, key), required)
    isempty(missing) || throw(ArgumentError("artifact missing required fields: $(join(string.(missing), ", "))"))
    x
end
function load_run(dir::AbstractString)
    records = (; public=_load(joinpath(dir,"public.json")), provenance=_load(joinpath(dir,"provenance.json")),
        evaluator=_load(joinpath(dir,"evaluator.json")))
    ids = (records.public.run_id, records.provenance.run_id, records.evaluator.run_id)
    length(unique(ids)) == 1 || throw(ArgumentError("run artifact identity mismatch"))
    records
end

end # module
