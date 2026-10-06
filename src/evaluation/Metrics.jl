module Metrics

import ..Falsify: ExperimentAction, OscillatorTruth, OscillatorWorld, OscillatorConfig,
    OscillatorMetadata, OscillatorExperiment, observe
import ..Falsify.SystemIdentification: FitResult, fit_oscillator, predict_trace
import ..Falsify: PROVIDER_INFRASTRUCTURE_CODES

export RunMetrics, MetricConfig, HELDOUT_PROBES, score_run

const HELDOUT_PROBES = (
    ExperimentAction(initial_displacement_m=1.0, initial_velocity_m_per_s=0.0),
    ExperimentAction(initial_displacement_m=0.0, initial_velocity_m_per_s=1.0),
    ExperimentAction(initial_displacement_m=0.0, initial_velocity_m_per_s=0.0,
        drive_acceleration_m_per_s2=0.5, drive_frequency_hz=0.75),
    ExperimentAction(initial_displacement_m=-0.5, initial_velocity_m_per_s=0.25,
        drive_acceleration_m_per_s2=-0.5, drive_frequency_hz=2.25),
)

Base.@kwdef struct MetricConfig
    failure_parameter_score::Float64 = 1.0
    failure_prediction_score::Float64 = 1.0
    success_parameter_threshold::Float64 = 0.10
    prediction_scale_m::Float64 = 2.0
end

struct RunMetrics
    run_id::String
    policy_name::String
    fit_status::Symbol
    fit_objective_m2::Union{Nothing,Float64}
    fit_evaluations::Int
    estimated_zeta::Union{Nothing,Float64}
    estimated_omega0::Union{Nothing,Float64}
    zeta_error::Union{Nothing,Float64}
    omega0_error::Union{Nothing,Float64}
    parameter_error::Float64
    raw_heldout_rmse_m::Union{Nothing,Float64}
    heldout_prediction_error::Float64
    success::Bool
    interventions_used::Int
    decision_opportunities_used::Int
    budget_utilization::Float64
    invalid_action_count::Int
    policy_failure_count::Int
    invalid_action_rate::Float64
    policy_failure_rate::Float64
    completion_status::String
    run_class::String
    recovered_after_rejection::Union{Nothing,Bool}
    error_improvement_per_intervention::Union{Nothing,Float64}
    model_calls::Union{Nothing,Int}
    input_tokens::Union{Nothing,Int}
    output_tokens::Union{Nothing,Int}
    latency_s::Union{Nothing,Float64}
    elapsed_wall_s::Union{Nothing,Float64}
    estimated_cost::Union{Nothing,Float64}
    provider::Union{Nothing,String}
    model::Union{Nothing,String}
end

function _action(x)
    ExperimentAction(initial_displacement_m=Float64(x.initial_displacement_m),
        initial_velocity_m_per_s=Float64(x.initial_velocity_m_per_s),
        drive_acceleration_m_per_s2=Float64(x.drive_acceleration_m_per_s2),
        drive_frequency_hz=Float64(x.drive_frequency_hz))
end

function _fitpairs(public)
    pairs = Tuple[]
    for e in public.events
        if e.consumed_intervention && e.requested_action !== nothing && e.observation !== nothing
            obs = e.observation
            measurements = Tuple((time_s=Float64(m.time_s), displacement_m=Float64(m.displacement_m)) for m in obs.measurements)
            push!(pairs, (_action(e.requested_action), (measurements=measurements,)))
        end
    end
    pairs
end

function _prediction_score(public, truth, fit, cfg)
    times = collect(range(0.0, Float64(public.action_limits.duration_s); length=Int(public.action_limits.max_samples)))
    config = OscillatorConfig(last(times), length(times))
    world = OscillatorWorld(OscillatorTruth(Float64(truth.damping_ratio), Float64(truth.natural_frequency_rad_s)),
        config, OscillatorMetadata("Tsit5", 1e-9, 1e-11, 0, v"0.1.0"))
    raw_sum = 0.0; count = 0
    for action in HELDOUT_PROBES
        target = observe(world, OscillatorExperiment(initial_displacement=action.initial_displacement_m,
            initial_velocity=action.initial_velocity_m_per_s,
            drive_acceleration_m_per_s2=action.drive_acceleration_m_per_s2,
            drive_frequency_hz=action.drive_frequency_hz)).displacement
        predicted = predict_trace(action, times, fit.zeta, fit.omega0)
        raw_sum += sum(abs2, predicted .- target); count += length(target)
    end
    rmse = sqrt(raw_sum/count)
    rmse, rmse/(cfg.prediction_scale_m + rmse)
end

"""Score a loaded artifact triple or persisted run directory; never accepts live controller/world state."""
function score_run(run, cfg::MetricConfig=MetricConfig())
    loaded = run isa AbstractString ? parentmodule(@__MODULE__).load_run(run) : run
    p, ev = loaded.public, loaded.evaluator
    fit = fit_oscillator(_fitpairs(p))
    good = fit.status == :success
    # `failed` is behavioral and scores 1.0 unless its terminal code shows a
    # provider/infrastructure fault with no usable model response. `aborted`
    # and provider-fault runs are infrastructure records excluded from
    # contrasts, so their endpoints are NaN, not a score.
    behaviorally_failed = p.status == "failed"
    aborted = p.status == "aborted"
    terminal_code = p.terminal === nothing || p.terminal.failure === nothing ?
        nothing : String(p.terminal.failure.code)
    infrastructure = aborted || (behaviorally_failed &&
        terminal_code in PROVIDER_INFRASTRUCTURE_CODES)
    truth = ev.truth
    ze = good ? abs(fit.zeta-Float64(truth.damping_ratio))/(0.40-0.05) : nothing
    we = good ? abs(fit.omega0-Float64(truth.natural_frequency_rad_s))/(2.0-0.8) : nothing
    raw_parameter = good ? sqrt((ze^2+we^2)/2) : nothing
    pe_fit = good ? raw_parameter/(1+raw_parameter) : cfg.failure_parameter_score
    rawpred, pred_fit = good ? _prediction_score(p, truth, fit, cfg) : (nothing, cfg.failure_prediction_score)
    pe = infrastructure ? NaN : behaviorally_failed ? cfg.failure_parameter_score : pe_fit
    pred = infrastructure ? NaN : behaviorally_failed ? cfg.failure_prediction_score : pred_fit
    pred = min(pred, cfg.failure_prediction_score)
    events = collect(p.events); decisions = Int(p.terminal.decision_opportunities_used)
    interventions = Int(p.terminal.interventions_used); invalid = Int(p.terminal.invalid_action_count)
    failures = count(e -> e.failure !== nothing && e.requested_action === nothing, events)
    recovery = any(i -> events[i].validation_valid === false && any(e -> e.sequence > events[i].sequence && e.consumed_intervention, events), eachindex(events))
    elapsed = Float64[e.elapsed_seconds for e in events if e.elapsed_seconds !== nothing]
    ops = [e.operational_metadata for e in events if e.operational_metadata !== nothing]
    sumfield(field) = isempty(ops) || all(o -> getproperty(o, field) === nothing, ops) ? nothing : sum(Int(getproperty(o,field) === nothing ? 0 : getproperty(o,field)) for o in ops)
    sumfloat(field) = isempty(ops) || all(o -> getproperty(o, field) === nothing, ops) ? nothing : sum(Float64(getproperty(o,field) === nothing ? 0 : getproperty(o,field)) for o in ops)
    first_nonmissing(field) = begin vals = [getproperty(o,field) for o in ops if getproperty(o,field) !== nothing]; isempty(vals) ? nothing : first(vals) end
    calls = length(ops)
    prior_raw = sqrt((((0.225-Float64(ev.truth.damping_ratio))/0.35)^2 +
        ((1.4-Float64(ev.truth.natural_frequency_rad_s))/1.2)^2)/2)
    improvement = good && !behaviorally_failed && !infrastructure && interventions > 0 ?
        (prior_raw/(1+prior_raw)-pe_fit)/interventions : nothing
    status = String(p.status)
    run_class = infrastructure ? "infrastructure" :
        behaviorally_failed ? "behavioral_failure" : status == "completed" ? "completed" : "unclassified"
    RunMetrics(String(p.run_id), String(p.policy_identity.name), fit.status, fit.objective,
        fit.evaluations, fit.zeta, fit.omega0,
        ze, we, pe, rawpred, pred, !infrastructure && good && pe <= cfg.success_parameter_threshold,
        interventions, decisions, p.intervention_budget == 0 ? 0.0 : interventions/p.intervention_budget,
        invalid, failures, decisions == 0 ? 0.0 : invalid/decisions,
        decisions == 0 ? 0.0 : failures/decisions, status, run_class, isempty(events) ? nothing : recovery,
        improvement, calls, sumfield(:input_tokens), sumfield(:output_tokens),
        sumfloat(:latency_s), isempty(elapsed) ? nothing : sum(elapsed), sumfloat(:cost),
        first_nonmissing(:provider), first_nonmissing(:model))
end

end
