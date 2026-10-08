module RunController

using Dates
using ..Falsify: JSON3
import ..Falsify: AbstractEnvironment, ObservationNoise, CleanObservation, GaussianObservationNoise, NOISE_IMPLEMENTATION_VERSION,
    apply_measurement_process, public_task, policy_task, limits_for, PublicState,
    DecisionHistoryEntry, PolicyDecision, ValidationResult, decision_with_parser,
    execute_experiment, apply_environment_noise, action_schema, public_action, public_observation,
    validate_environment_action, policy_identity, policy_configuration, policy_contract_profile, metadata,
    environment_id, environment_version, action_schema_version, observation_schema_version,
    parse_action, validate_schedule,
    PublicRunArtifact, ProvenanceArtifact, EvaluatorArtifact, RunEvent,
    PublicFailure, EvaluatorFailure, PolicyFailure, TerminalResult, ProtocolSettings, artifact_limits, new_run_id, policy_seed,
    PolicyIdentity, capture_provenance, evaluator_artifact, write_run

export RunConfig, RunOutcome, run_experiment, validate_run_events,
    run_attempt, RunAttempt, APPARATUS_FAILURE_CODE, PROVIDER_INFRASTRUCTURE_CODES,
    APPARATUS_FAILURE_CLASS, classify_run

"""Explicit bounded V0 lifecycle. Retries are new decisions, never hidden calls."""
struct RunConfig
    intervention_budget::Int
    max_decision_opportunities::Int
    observation_noise::Union{CleanObservation,GaussianObservationNoise}
    noise_seed::Int
    function RunConfig(intervention_budget::Integer; retry_allowance::Integer=intervention_budget,
            max_decision_opportunities::Union{Nothing,Integer}=nothing,
            observation_noise::Union{CleanObservation,GaussianObservationNoise}=CleanObservation(), noise_seed::Integer=0)
        intervention_budget >= 0 || throw(ArgumentError("intervention budget must be nonnegative"))
        retry_allowance >= 0 || throw(ArgumentError("retry allowance must be nonnegative"))
        maximum = max_decision_opportunities === nothing ? intervention_budget + retry_allowance : Int(max_decision_opportunities)
        maximum >= 0 || throw(ArgumentError("decision-opportunity limit must be nonnegative"))
        0 <= noise_seed <= typemax(Int) || throw(ArgumentError("noise seed must fit a nonnegative Int"))
        new(Int(intervention_budget), maximum, observation_noise, Int(noise_seed))
    end
end

struct RunOutcome
    public::PublicRunArtifact
    provenance::ProvenanceArtifact
    evaluator::EvaluatorArtifact
end

function validate_run_events(events, budget, terminal)
    remaining = budget
    executed = decisions = invalid = 0
    for (i,e) in enumerate(events)
        e.sequence == i || throw(ArgumentError("event sequence is not contiguous"))
        e.remaining_budget >= 0 || throw(ArgumentError("negative remaining budget"))
        decisions += 1
        if e.consumed_intervention
            e.requested_action !== nothing && e.validation_valid === true && e.validation_code == "accepted" && e.observation !== nothing ||
                throw(ArgumentError("executed event is inconsistent"))
            remaining -= 1; executed += 1
            e.remaining_budget == remaining || throw(ArgumentError("event budget does not match executed intervention"))
        else
            e.observation === nothing || throw(ArgumentError("non-executed event has observation"))
            e.validation_valid === false && (invalid += e.requested_action === nothing ? 0 : 1)
            remaining == e.remaining_budget || throw(ArgumentError("rejected decision changed intervention budget"))
        end
    end
    terminal.interventions_used == executed || throw(ArgumentError("terminal intervention count mismatch"))
    terminal.decision_opportunities_used == decisions || throw(ArgumentError("terminal decision count mismatch"))
    terminal.invalid_action_count == invalid || throw(ArgumentError("terminal invalid-action count mismatch"))
    true
end

"""Stable public code for unexpected (non-PolicyFailure) apparatus exceptions."""
const APPARATUS_FAILURE_CODE = "apparatus_exception"
const APPARATUS_FAILURE_CLASS = "apparatus_failure"

function _abort_run!(events, sequence, action, validation, remaining, elapsed, metadata)
    terminal_failure = PublicFailure(APPARATUS_FAILURE_CODE; stage_index=sequence)
    push!(events, RunEvent(sequence, action,
        validation === nothing ? nothing : validation.valid,
        validation === nothing ? nothing : String(validation.code), false, nothing,
        remaining, "aborted", elapsed, terminal_failure, metadata))
    terminal_failure
end

"""Supervised one-attempt result: every attempt resolves to a durable classification."""
struct RunAttempt
    run_id::String
    classification::String
    outcome::Union{Nothing,RunOutcome}
    artifact_dir::Union{Nothing,String}
    record::NamedTuple
end

function run_experiment(world::AbstractEnvironment, policy, config::RunConfig;
        root=pwd(), run_id=new_run_id(), repetition_id=nothing, condition_id=nothing, protocol_id=nothing)
    task = public_task(world); limits = limits_for(task)
    events = RunEvent[]; history = DecisionHistoryEntry[]
    remaining = config.intervention_budget
    status = "completed"; terminal_failure = nothing
    opportunities = 0
    abort_exception = nothing; abort_stage = nothing
    while remaining > 0 && opportunities < config.max_decision_opportunities
        state = PublicState(policy_task(task), limits, Tuple(history), remaining,
            config.max_decision_opportunities - opportunities; action_schema=action_schema(world),
            policy_contract_profile=policy_contract_profile(world))
        opportunities += 1
        started = time()
        decision = try
            decision_with_parser(policy, state, content -> parse_action(typeof(world), content))
        catch failure
            if failure isa PolicyFailure
                code = String(failure.code)
                public_failure = PublicFailure(code; stage_index=opportunities)
                push!(events, RunEvent(opportunities, nothing, nothing, nothing, false, nothing,
                    remaining, "failed", time()-started, public_failure, failure.operational_metadata))
                push!(history, DecisionHistoryEntry(nothing, nothing, nothing, false, nothing, failure.code, remaining))
                status = "failed"; terminal_failure = public_failure
            else
                terminal_failure = _abort_run!(events, opportunities, nothing, nothing,
                    remaining, time()-started, nothing)
                status = "aborted"; abort_exception = failure; abort_stage = "decision"
            end
            break
        end
        action = decision.action
        visible_action = nothing
        validation = nothing; observation = nothing
        apparatus_failure = try
            visible_action = public_action(world, action)
            validation = remaining <= 0 ? ValidationResult(false, :budget_exhausted) :
                validate_environment_action(world, action)
            validation.valid && (validation = validate_schedule(limits))
            if validation.valid
                clean = execute_experiment(world, action)
                observation = apply_environment_noise(world, clean, config.observation_noise,
                    config.noise_seed, config.intervention_budget - remaining + 1)
                observation = public_observation(world, observation)
            end
            false
        catch failure
            terminal_failure = _abort_run!(events, opportunities, visible_action, validation,
                remaining, time()-started, decision.operational_metadata)
            status = "aborted"; abort_exception = failure; abort_stage = "apparatus"
            true
        end
        apparatus_failure && break
        if validation.valid
            remaining -= 1
            push!(events, RunEvent(opportunities, visible_action, true, "accepted", true, observation,
                remaining, "running", time()-started, nothing, decision.operational_metadata))
            push!(history, DecisionHistoryEntry(visible_action, true, :accepted, true, observation, nothing, remaining))
        else
            code = validation.code
            push!(events, RunEvent(opportunities, visible_action, false, String(code), false, nothing,
                remaining, "running", time()-started, PublicFailure(String(code); stage_index=opportunities), decision.operational_metadata))
            push!(history, DecisionHistoryEntry(visible_action, false, code, false, nothing, code, remaining))
        end
    end
    if status == "completed" && remaining > 0
        status = "failed"
        terminal_failure = PublicFailure("decision_opportunities_exhausted")
    end
    invalid_count = count(e -> e.validation_valid === false && e.requested_action !== nothing, events)
    terminal = TerminalResult(status, nothing, terminal_failure, config.intervention_budget-remaining,
        opportunities, invalid_count)
    if !isempty(events)
        last_event = events[end]
        events[end] = RunEvent(last_event.sequence, last_event.requested_action, last_event.validation_valid,
            last_event.validation_code, last_event.consumed_intervention, last_event.observation,
            last_event.remaining_budget, status, last_event.elapsed_seconds, last_event.failure,
            last_event.operational_metadata)
    end
    validate_run_events(events, config.intervention_budget, terminal)
    ident = policy_identity(policy, world)
    public = PublicRunArtifact(; run_id, status, finalized_at=string(now(UTC)),
        environment_id=environment_id(world), environment_version=environment_version(world),
        action_schema_version=action_schema_version(world), observation_schema_version=observation_schema_version(world),
        task_description=task.model_description, action_limits=artifact_limits(limits),
        intervention_budget=config.intervention_budget, protocol_settings=ProtocolSettings(true),
        policy_identity=ident, events=Tuple(events), terminal)
    provenance = capture_provenance(run_id; root, world, noise_seed=config.noise_seed,
        policy_seed=policy_seed(policy), repetition_id,
        configuration=(protocol_id, environment_id=environment_id(world), environment_version=environment_version(world),
            action_schema_version=action_schema_version(world), observation_schema_version=observation_schema_version(world),
            policy=policy_configuration(policy), max_decision_opportunities=config.max_decision_opportunities,
            retry_allowance=config.max_decision_opportunities-config.intervention_budget,
            noise_condition=config.observation_noise isa CleanObservation ? "clean" : "gaussian",
            sigma_m=config.observation_noise isa CleanObservation ? 0.0 : config.observation_noise.sigma_m,
            noise_implementation=NOISE_IMPLEMENTATION_VERSION))
    evaluator_failures = status == "aborted" ?
        EvaluatorFailure[EvaluatorFailure(APPARATUS_FAILURE_CODE;
            diagnostic=_exception_name(abort_exception), stage_index=opportunities)] :
        EvaluatorFailure[]
    evaluator = evaluator_artifact(world, run_id; condition_id,
        evaluator_metadata=status == "aborted" ? (abort_stage=abort_stage,) : (;),
        failures=evaluator_failures)
    RunOutcome(public, provenance, evaluator)
end

"""Sanitized exception identity for evaluator-side diagnostics; never the message."""
_exception_name(failure) = failure === nothing ? nothing : string(nameof(typeof(failure)))

function _aborted_outcome(world::AbstractEnvironment, policy, config::RunConfig, run_id;
        root, repetition_id, condition_id, protocol_id, failure)
    task = public_task(world); limits = limits_for(task)
    ident = try policy_identity(policy, world) catch; PolicyIdentity("unidentified") end
    terminal = TerminalResult("aborted", nothing,
        PublicFailure(APPARATUS_FAILURE_CODE), 0, 0, 0)
    public = PublicRunArtifact(; run_id, status="aborted", finalized_at=string(now(UTC)),
        environment_id=environment_id(world), environment_version=environment_version(world),
        action_schema_version=action_schema_version(world), observation_schema_version=observation_schema_version(world),
        task_description=task.model_description, action_limits=artifact_limits(limits),
        intervention_budget=config.intervention_budget,
        protocol_settings=ProtocolSettings(true), policy_identity=ident,
        events=(), terminal)
    provenance = capture_provenance(run_id; root, world, noise_seed=config.noise_seed,
        policy_seed=try policy_seed(policy) catch; nothing end, repetition_id,
        configuration=(protocol_id, environment_id=environment_id(world), environment_version=environment_version(world),
            action_schema_version=action_schema_version(world), observation_schema_version=observation_schema_version(world),
            aborted_before_finalization=true,
            condition_id=condition_id,
            noise_condition=config.observation_noise isa CleanObservation ? "clean" : "gaussian",
            sigma_m=config.observation_noise isa CleanObservation ? 0.0 : config.observation_noise.sigma_m,
            max_decision_opportunities=config.max_decision_opportunities))
    evaluator = evaluator_artifact(world, run_id; condition_id,
        evaluator_metadata=(unfinalized_events=true,),
        failures=[EvaluatorFailure(APPARATUS_FAILURE_CODE; diagnostic=_exception_name(failure))])
    RunOutcome(public, provenance, evaluator)
end

"""Terminal failure codes that denote transport/provider/infrastructure faults:
the model never produced a usable response, so the run is not behavioral evidence."""
const PROVIDER_INFRASTRUCTURE_CODES = ("configuration_failure", "authentication_failure",
    "provider_unavailable", "rate_limited", "provider_rejection",
    "malformed_api_response", "client_failure")

function classify_run(status::AbstractString, failure_code)
    # Unexpected controller/simulator exceptions are defects in the apparatus,
    # not provider delivery failures and therefore never retry eligible.
    status == "aborted" && return APPARATUS_FAILURE_CLASS
    status == "completed" && return "completed"
    status == "failed" && return failure_code in PROVIDER_INFRASTRUCTURE_CODES ?
        "infrastructure" : "behavioral_failure"
    "unclassified"
end

"""Append one JSON-lines ledger record; the last durable record for any attempt."""
function _append_ledger(path::AbstractString, record::NamedTuple)
    open(path, "a") do io
        write(io, JSON3.write(record)); write(io, '\n'); flush(io)
    end
    path
end

"""
Run one attempt under supervision: typed PolicyFailure is classified by its
failure code, any unexpected exception becomes a durable `aborted` (apparatus)
record, and
every attempt appends a run-ledger line even when artifact persistence fails.
Returns a `RunAttempt`; the ledger is evaluator-side bookkeeping.
"""
function run_attempt(world::AbstractEnvironment, policy, config::RunConfig;
        root=pwd(), artifacts_root=nothing, ledger_path=nothing,
        repetition_id=nothing, condition_id=nothing, protocol_id=nothing, run_id=new_run_id())
    run_id = String(run_id)
    outcome = nothing; failure = nothing
    try
        outcome = run_experiment(world, policy, config; root, run_id, repetition_id, condition_id, protocol_id)
    catch caught
        failure = caught
        outcome = try
            _aborted_outcome(world, policy, config, run_id; root, repetition_id,
                condition_id, protocol_id, failure)
        catch
            nothing
        end
    end
    artifact_dir = nothing
    if artifacts_root !== nothing && outcome !== nothing
        artifact_dir = try
            write_run(artifacts_root, outcome.public, outcome.provenance, outcome.evaluator)
        catch
            nothing
        end
    end
    terminal = outcome === nothing ? nothing : outcome.public.terminal
    status = outcome === nothing ? "aborted" : outcome.public.status
    terminal_code = terminal === nothing || terminal.failure === nothing ?
        nothing : terminal.failure.code
    failure_code = outcome === nothing ? "apparatus_exception" : terminal_code
    classification = outcome === nothing ? APPARATUS_FAILURE_CLASS : classify_run(status, terminal_code)
    if outcome !== nothing && artifact_dir === nothing && artifacts_root !== nothing
        classification = APPARATUS_FAILURE_CLASS
        failure_code = "artifact_persistence_failure"
    end
    record = (schema_version=1, recorded_at=string(now(UTC)), run_id,
        status, classification,
        environment_id=environment_id(world), environment_version=environment_version(world),
        action_schema_version=action_schema_version(world), observation_schema_version=observation_schema_version(world),
        condition_id=condition_id === nothing ? nothing : String(condition_id),
        repetition_id=repetition_id === nothing ? nothing : String(repetition_id),
        policy_name=outcome === nothing ? nothing : outcome.public.policy_identity.name,
        world_seed=metadata(world).world_seed, noise_seed=config.noise_seed,
        policy_seed=try policy_seed(policy) catch; nothing end,
        intervention_budget=config.intervention_budget,
        max_decision_opportunities=config.max_decision_opportunities,
        interventions_used=terminal === nothing ? 0 : terminal.interventions_used,
        decision_opportunities_used=terminal === nothing ? 0 : terminal.decision_opportunities_used,
        invalid_action_count=terminal === nothing ? 0 : terminal.invalid_action_count,
        terminal_failure_code=failure_code,
        abort_diagnostic=outcome === nothing ? _exception_name(failure) : nothing,
        artifact_dir=artifact_dir === nothing ? nothing : String(artifact_dir))
    if ledger_path !== nothing
        _append_ledger(ledger_path, record)
    end
    RunAttempt(run_id, classification, outcome, artifact_dir, record)
end

end
