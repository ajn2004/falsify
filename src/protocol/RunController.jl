module RunController

using Dates
import ..Falsify: OscillatorWorld, ObservationNoise, CleanObservation, GaussianObservationNoise, NOISE_IMPLEMENTATION_VERSION,
    apply_measurement_process, public_task, policy_task, limits_for, PublicState,
    DecisionHistoryEntry, ExperimentAction, PolicyDecision, next_decision, validate_action,
    to_environment_action, observe, policy_observation, policy_identity, policy_configuration,
    PublicRunArtifact, ProvenanceArtifact, EvaluatorArtifact, RunEvent,
    PublicFailure, PolicyFailure, TerminalResult, ProtocolSettings, artifact_limits, new_run_id, policy_seed,
    capture_provenance, evaluator_artifact, write_run

export RunConfig, RunOutcome, run_experiment, validate_run_events

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

function run_experiment(world::OscillatorWorld, policy, config::RunConfig;
        root=pwd(), run_id=new_run_id(), repetition_id=nothing)
    task = public_task(world); limits = limits_for(task)
    events = RunEvent[]; history = DecisionHistoryEntry[]
    remaining = config.intervention_budget
    status = "completed"; terminal_failure = nothing
    opportunities = 0
    while remaining > 0 && opportunities < config.max_decision_opportunities
        state = PublicState(policy_task(task), limits, Tuple(history), remaining)
        opportunities += 1
        started = time()
        decision = try
            next_decision(policy, state)
        catch failure
            failure isa PolicyFailure || rethrow()
            code = String(failure.code)
            public_failure = PublicFailure(code; stage_index=opportunities)
            push!(events, RunEvent(opportunities, nothing, nothing, nothing, false, nothing,
                remaining, "failed", time()-started, public_failure, failure.operational_metadata))
            push!(history, DecisionHistoryEntry(nothing, nothing, nothing, false, nothing, failure.code, remaining))
            status = "failed"; terminal_failure = public_failure
            break
        end
        action = decision.action
        validation = validate_action(action, state)
        if validation.valid
            clean = observe(world, to_environment_action(action))
            observation = apply_measurement_process(clean, config.observation_noise,
                config.noise_seed, config.intervention_budget - remaining + 1)
            remaining -= 1
            push!(events, RunEvent(opportunities, action, true, "accepted", true, observation,
                remaining, "running", time()-started, nothing, decision.operational_metadata))
            push!(history, DecisionHistoryEntry(action, true, :accepted, true, observation, nothing, remaining))
        else
            code = validation.code
            push!(events, RunEvent(opportunities, action, false, String(code), false, nothing,
                remaining, "running", time()-started, PublicFailure(String(code); stage_index=opportunities), decision.operational_metadata))
            push!(history, DecisionHistoryEntry(action, false, code, false, nothing, code, remaining))
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
    ident = policy_identity(policy)
    public = PublicRunArtifact(; run_id, status, finalized_at=string(now(UTC)),
        task_description=task.model_description, action_limits=artifact_limits(limits),
        intervention_budget=config.intervention_budget, protocol_settings=ProtocolSettings(true),
        policy_identity=ident, events=Tuple(events), terminal)
    provenance = capture_provenance(run_id; root, world, noise_seed=config.noise_seed,
        policy_seed=policy_seed(policy), repetition_id,
        configuration=(policy=policy_configuration(policy), max_decision_opportunities=config.max_decision_opportunities,
            retry_allowance=config.max_decision_opportunities-config.intervention_budget,
            noise_condition=config.observation_noise isa CleanObservation ? "clean" : "gaussian",
            sigma_m=config.observation_noise isa CleanObservation ? 0.0 : config.observation_noise.sigma_m,
            noise_implementation=NOISE_IMPLEMENTATION_VERSION))
    evaluator = evaluator_artifact(world, run_id)
    RunOutcome(public, provenance, evaluator)
end

end
