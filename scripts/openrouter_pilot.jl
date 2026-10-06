using Falsify
using JSON3
using SHA

"""Two-intervention, noisy, non-confirmatory live gate through the supervised
runner — the same entry point and payload construction the confirmatory sweep
uses. Never invoked by CI.

The gate exists to prove the sequential confirmatory interaction end-to-end:

    model request #1 -> experiment -> noisy Observation
        -> serialized public history -> model request #2

A single clean call can pass strict-schema validation while never exercising
the history payload every subsequent confirmatory decision depends on. Two
interventions under sigma = 0.10 Gaussian noise exercise exactly the primary
condition's interaction shape without paying for an eight-call pilot.
"""

# Exploratory seeds only; disjoint from every confirmatory and prior pilot seed.
const GATE_WORLD_SEED = 7122126
const GATE_NOISE_SEED = GATE_WORLD_SEED + 1_000_000  # pilot derivation rule
const GATE_SIGMA_M = 0.10
const GATE_BUDGET = 2
const GATE_OPPORTUNITIES = 4
const GATE_REPETITION = "pilot-dal123-gate"
const GATE_CONDITION = "exploratory-gaussian-0.10"

"""Rebuild the DecisionHistoryEntry the controller recorded for an event."""
_history_entry(e) = DecisionHistoryEntry(e.requested_action, e.validation_valid,
    e.validation_code === nothing ? nothing : Symbol(e.validation_code),
    e.consumed_intervention, e.observation,
    e.failure === nothing ? nothing : Symbol(e.failure.code), e.remaining_budget)

"""
Reconstruct the exact ModelRequest the policy built for decision `i` purely
from the public artifact: prior events, remaining budget, and opportunity
count. Comparing SHA-256(JSON payload) against the recorded request_sha256
proves the endpoint received this serialized public state — no more, no less.
"""
function _reconstructed_request(events, i, task, limits, run_config)
    history = Tuple(_history_entry(e) for e in events[1:i-1])
    remaining = i == 1 ? run_config.intervention_budget : events[i-1].remaining_budget
    state = PublicState(task, limits, history, remaining,
        run_config.max_decision_opportunities - (i - 1))
    model_request(state)
end

function _print_checks(checks)
    for (name, ok, detail) in checks
        println(rpad(ok ? "PASS" : "FAIL", 5), " ", name,
            isempty(detail) ? "" : "  — ", detail)
    end
    all(c -> c[2], checks)
end

"""
Verify the live gate run. Returns true only when every check passes; the gate
specifically refuses to pass without at least one verified post-observation
model request. Uses operational metadata only — never the scientific action.
"""
function verify_gate(attempt, world, run_config, provider_config; ledger_path)
    checks = Tuple{String,Bool,String}[]
    check(name, ok, detail="") = push!(checks, (name, ok === true, string(detail)))
    outcome = attempt.outcome
    check("attempt produced a finalized outcome", outcome !== nothing,
        "classification=$(attempt.classification)")
    outcome === nothing && return _print_checks(checks)
    events = collect(outcome.public.events)
    terminal = outcome.public.terminal
    consumed = [e for e in events if e.consumed_intervention]
    noise = run_config.observation_noise
    expected_noise_model = noise isa GaussianObservationNoise ? "gaussian_additive" : "none"
    expected_sigma = noise isa GaussianObservationNoise ? noise.sigma_m : 0.0
    budget = run_config.intervention_budget
    opportunities_cap = run_config.max_decision_opportunities

    check("run status completed", outcome.public.status == "completed",
        outcome.public.status)
    check("attempt classification completed", attempt.classification == "completed",
        attempt.classification)
    check("$(budget) valid model requests (consumed interventions)",
        terminal.interventions_used == budget,
        "interventions_used=$(terminal.interventions_used)")
    check("decision opportunities within cap",
        0 < terminal.decision_opportunities_used <= opportunities_cap &&
            terminal.decision_opportunities_used == length(events),
        "used=$(terminal.decision_opportunities_used) cap=$(opportunities_cap)")
    check("event count consistent", terminal.decision_opportunities_used == length(events),
        "$(length(events)) events")
    check("every model response parsed under strict schema",
        all(e -> e.requested_action !== nothing, events),
        "unparsed=$(count(e -> e.requested_action === nothing, events))")
    check("remaining budget progression",
        all(events[i].remaining_budget == budget - count(e -> e.consumed_intervention, events[1:i])
            for i in eachindex(events)),
        "budgets=$(join((e.remaining_budget for e in events), ","))")
    check("every consumed event carries an observation",
        all(e -> e.observation !== nothing, consumed))
    check("observation noise model $(expected_noise_model)",
        all(e -> e.observation !== nothing &&
            e.observation.noise_model == expected_noise_model, consumed))
    check("observation noise scale $(expected_sigma) m",
        all(e -> e.observation !== nothing &&
            e.observation.noise_scale_m == expected_sigma, consumed),
        join((e.observation === nothing ? "missing" : e.observation.noise_scale_m
            for e in consumed), ","))
    check("measurements carry declared uncertainty",
        all(e -> e.observation !== nothing && !isempty(e.observation.measurements) &&
            all(m -> m.uncertainty_m == expected_sigma, e.observation.measurements), consumed))

    # Every recorded request hash must equal the hash of the payload we
    # reconstruct from the public artifact — proving what the endpoint saw.
    task = policy_task(public_task(world))
    limits = limits_for(public_task(world))
    hashed = false
    hash_mismatches = String[]
    post_observation_verified = false
    for (i, e) in enumerate(events)
        e.operational_metadata === nothing && continue
        e.operational_metadata.request_sha256 === nothing && continue
        hashed = true
        req = _reconstructed_request(events, i, task, limits, run_config)
        digest = bytes2hex(sha256(JSON3.write(openrouter_payload(provider_config, req))))
        if digest != e.operational_metadata.request_sha256
            push!(hash_mismatches, "decision $(e.sequence)")
            continue
        end
        if any(h -> h.observation !== nothing, req.history)
            post_observation_verified = true
        end
    end
    check("request SHA-256 matches reconstructed public payload for every request",
        hashed && isempty(hash_mismatches), join(hash_mismatches, ","))
    check("at least one verified post-observation model request",
        post_observation_verified)

    # Provider-side operational capture on every request that reached transport.
    for (label, f) in (("serving provider captured", m -> m.provider !== nothing),
            ("served model identity captured", m -> m.model !== nothing),
            ("request id captured", m -> m.request_id !== nothing),
            ("token usage captured", m -> m.input_tokens !== nothing && m.output_tokens !== nothing),
            ("latency captured", m -> m.latency_s !== nothing && m.latency_s >= 0),
            ("returned cost captured", m -> m.cost !== nothing),
            ("finish_reason captured", m -> m.finish_reason !== nothing),
            ("http 200 on every request", m -> m.http_status == 200))
        misses = [e.sequence for e in events if e.operational_metadata === nothing ||
            e.operational_metadata.request_sha256 === nothing || !f(e.operational_metadata)]
        check(label, isempty(misses), join(misses, ","))
    end

    # Persistence: artifact reloads independently and carries the condition.
    check("artifact directory written", attempt.artifact_dir !== nothing)
    loaded = attempt.artifact_dir === nothing ? nothing :
        try load_run(attempt.artifact_dir) catch err; err end
    check("artifact reloads", loaded isa NamedTuple,
        loaded isa NamedTuple ? "" : sprint(showerror, loaded))
    if loaded isa NamedTuple
        check("reloaded run identity", loaded.public.run_id == attempt.run_id &&
            length(loaded.public.events) == length(events) &&
            loaded.public.status == outcome.public.status)
        check("reloaded condition id", loaded.evaluator.condition_id == GATE_CONDITION,
            loaded.evaluator.condition_id)
        check("reloaded provenance", loaded.provenance.world_seed == GATE_WORLD_SEED &&
            loaded.provenance.noise_seed == GATE_NOISE_SEED &&
            loaded.provenance.configuration.noise_condition == "gaussian" &&
            loaded.provenance.configuration.sigma_m == GATE_SIGMA_M &&
            loaded.provenance.repetition_id == GATE_REPETITION,
            "world=$(loaded.provenance.world_seed) noise=$(loaded.provenance.noise_seed)")
    end

    # Ledger: the last durable record for this attempt exists and matches.
    ledger_ok = isfile(ledger_path)
    record = ledger_ok ? JSON3.read(strip(read(ledger_path, String))) : nothing
    check("ledger entry exists", ledger_ok)
    if record !== nothing
        check("ledger entry matches run", record.run_id == attempt.run_id &&
            record.condition_id == GATE_CONDITION &&
            record.repetition_id == GATE_REPETITION &&
            record.interventions_used == terminal.interventions_used,
            "classification=$(record.classification)")
    end
    _print_checks(checks)
end

function main()
    isempty(strip(get(ENV, "OPENROUTER_API_KEY", ""))) &&
        error("Set OPENROUTER_API_KEY to run the OpenRouter pilot")
    root = normpath(joinpath(@__DIR__, ".."))
    provider_config = load_openrouter_config(joinpath(root, "configs", "v0.1-frontier.toml"))
    world = generate_world(GATE_WORLD_SEED)
    policy = ScientistPolicy(OpenRouterClient(provider_config))
    run_config = RunConfig(GATE_BUDGET; max_decision_opportunities=GATE_OPPORTUNITIES,
        observation_noise=GaussianObservationNoise(GATE_SIGMA_M), noise_seed=GATE_NOISE_SEED)
    store = joinpath(root, "results", "raw")
    ledger = joinpath(store, "run-ledger-pilot.jsonl")
    attempt = run_attempt(world, policy, run_config; root,
        artifacts_root=store, ledger_path=ledger,
        repetition_id=GATE_REPETITION, condition_id=GATE_CONDITION)
    println("NON-CONFIRMATORY PILOT — exploratory only")
    println("run_id: ", attempt.run_id, "  classification: ", attempt.classification)
    if attempt.outcome !== nothing
        for event in attempt.outcome.public.events
            println("decision ", event.sequence, ": action=", event.requested_action,
                " validation=", event.validation_code,
                " failure=", event.failure === nothing ? nothing : event.failure.code,
                " metadata=", event.operational_metadata)
        end
        println("status: ", attempt.outcome.public.status)
    end
    println("artifact: ", attempt.artifact_dir)
    println("ledger: ", ledger)
    ok = verify_gate(attempt, world, run_config, provider_config; ledger_path=ledger)
    println(ok ? "LIVE GATE: PASS — confirmatory operational prerequisite satisfied" :
        "LIVE GATE: FAIL — confirmatory execution remains blocked")
    ok || exit(1)
end

if abspath(PROGRAM_FILE) == @__FILE__()
    main()
end
