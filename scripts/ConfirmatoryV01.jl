module ConfirmatoryV01

using Falsify
using JSON3
using SHA
using TOML
using Dates

const PROTOCOL = "falsify-v0.1-prereg-4"
const BUDGET = 8
const OPPORTUNITIES = 16
const CONDITIONS = (("gaussian_0.10", :gaussian), ("clean", :clean))

export build_matrix, main, slot_key, retry_decision
export nominal_provider_requests, analysis_conditions

nominal_provider_requests(slots) = 8 * count(s -> s["policy"] == "scientist", slots)
analysis_conditions() = ("gaussian_0.10",)

function build_matrix(seed_path)
    manifest = TOML.parsefile(seed_path)
    manifest["protocol_id"] == PROTOCOL || error("unexpected protocol identity")
    manifest["scientist_repetition_ids"] == [1] || error("unexpected scientist repetition IDs")
    worlds = manifest["worlds"]
    length(worlds) == 30 || error("expected exactly 30 frozen worlds")
    length(unique(w["world_seed"] for w in worlds)) == 30 || error("duplicate world seed")
    slots = Dict{String,Any}[]
    for (condition_id, condition_worlds) in (("gaussian_0.10", worlds), ("clean", worlds[1:10])), world in condition_worlds
        for (policy, repetitions) in (("random", ["random"]), ("fixed_design", ["fixed"]),
                ("scientist", ["scientist-1"]))
            for repetition in repetitions
                push!(slots, Dict{String,Any}(
                    "slot_id"=>"$(world["world_seed"])/$condition_id/$repetition",
                    "protocol_id"=>PROTOCOL, "world_seed"=>world["world_seed"],
                    "condition_id"=>condition_id, "policy"=>policy,
                    "repetition_id"=>repetition,
                    "scientist_repetition_id"=>startswith(repetition, "scientist-") ? parse(Int, split(repetition, "-")[2]) : nothing,
                    "noise_seed"=>world["noise_seed"],
                    "policy_seed"=>policy == "random" ? world["random_policy_seed"] : nothing,
                    "intervention_budget"=>BUDGET, "max_decision_opportunities"=>OPPORTUNITIES,
                    "status"=>"pending", "run_ids"=>String[], "retry_status"=>"not_applicable"))
            end
        end
    end
    length(slots) == 120 || error("matrix cardinality is not 120")
    slots
end

slot_key(slot) = String(slot["slot_id"])
const MUTABLE_SLOT_FIELDS = Set(("status", "run_ids", "retry_status"))
_immutable_slot(slot) = Dict{String,Any}(String(k)=>v for (k,v) in pairs(slot) if !(String(k) in MUTABLE_SLOT_FIELDS))

function _validate_saved_slots(saved_slots, matrix)
    length(saved_slots) == length(matrix) || error("execution state matrix cardinality mismatch")
    for (saved, expected) in zip(saved_slots, matrix)
        _immutable_slot(saved) == _immutable_slot(expected) || error("execution state altered frozen slot")
    end
    true
end

function _restore_mutable_slots(matrix, saved_slots)
    _validate_saved_slots(saved_slots, matrix)
    [merge(copy(expected), Dict{String,Any}(key=>saved[key] for key in MUTABLE_SLOT_FIELDS))
        for (expected, saved) in zip(matrix, saved_slots)]
end

function retry_decision(classifications)
    isempty(classifications) && return :pending
    last = classifications[end]
    last == "completed" && return :completed
    last == "behavioral_failure" && return :behavioral_failure
    last == "infrastructure" && return length(classifications) == 1 ? :retry : :terminal_infrastructure
    error("unrecognized run classification: $last")
end

function _repo(root, mode)
    git = mode == :commit ? `git -C $root rev-parse HEAD` : `git -C $root status --porcelain --untracked-files=all`
    try
        raw = read(pipeline(git; stderr=devnull), String)
        return mode == :dirty ? chomp(raw) : strip(raw)
    catch
        jj = mode == :commit ? `jj -R $root log --no-graph -r @ -T commit_id` : `jj -R $root status`
        text = strip(read(pipeline(jj; stderr=devnull), String))
        mode == :dirty && return occursin("working copy has no changes", text) ? "" : text
        text
    end
end

const RUNTIME_OUTPUT_PREFIXES = Falsify.RUNTIME_OUTPUT_PREFIXES

function _source_dirty(root)
    lines = filter(!isempty, split(_repo(root, :dirty), '\n'))
    # Git porcelain v1 has two status columns followed by a space and path.
    # Only the two designated append-only runtime output roots are exempt.
    filter(lines) do line
        length(line) >= 4 || return true
        path = replace(line[4:end], r"^\"|\"$" => "")
        !any(prefix -> startswith(path, prefix), RUNTIME_OUTPUT_PREFIXES)
    end
end

function _assert_identity(root, commit)
    _repo(root, :commit) == commit || error("repository commit changed during confirmatory sweep")
    isempty(_source_dirty(root)) || error("source/config checkout became dirty during confirmatory sweep")
    VERSION == v"1.12.7" || error("Julia 1.12.7 required; found $VERSION")
end

function _write_json(path, obj)
    mkpath(dirname(path))
    tmp = path * ".tmp"
    open(tmp, "w") do io
        write(io, JSON3.write(obj)); write(io, '\n'); flush(io)
    end
    mv(tmp, path; force=true)
end

function _read_ledger(path)
    isfile(path) || return Any[]
    [JSON3.read(line) for line in eachline(path) if !isempty(strip(line))]
end

function _append_journal(path, row)
    mkpath(dirname(path))
    open(path, "a") do io
        write(io, JSON3.write(row)); write(io, '\n'); flush(io)
        ccall(:fsync, Cint, (Cint,), Base.fd(io)) == 0 || error("attempt journal fsync failed")
    end
    nothing
end

function _append_ledger_record(path, row)
    mkpath(dirname(path))
    open(path, "a") do io
        write(io, JSON3.write(row)); write(io, '\n'); flush(io)
        ccall(:fsync, Cint, (Cint,), Base.fd(io)) == 0 || error("run ledger fsync failed")
    end
end

function _read_journal(path)
    isfile(path) || return Any[]
    [JSON3.read(line) for line in eachline(path) if !isempty(strip(line))]
end

function _reconcile_journal!(journal_path, ledger_path, raw, slots)
    journal = _read_journal(journal_path)
    ledger = _read_ledger(ledger_path)
    ledger_ids = Set(String(r.run_id) for r in ledger)
    started = Dict{String,Any}()
    finished = Set{String}()
    for row in journal
        id = String(row.run_id)
        row.event == "attempt_started" && (started[id] = row)
        row.event == "attempt_finished" && push!(finished, id)
    end
    for (id, start) in started
        if id in ledger_ids
            id in finished || _append_journal(journal_path, (event="attempt_finished", run_id=id, outcome="ledger_present"))
            continue
        end
        artifact_dir = joinpath(raw, id)
        if isdir(artifact_dir)
            records = try load_run(artifact_dir) catch; nothing end
            if records !== nothing && records.public.run_id == id && records.provenance.run_id == id && records.evaluator.run_id == id
                pub = records.public
                code = pub.terminal.failure === nothing ? nothing : pub.terminal.failure.code
                classification = classify_run(pub.status, code)
                row = (schema_version=1, recorded_at=string(Dates.now(Dates.UTC)), run_id=id,
                    status=pub.status, classification, condition_id=start.condition_id,
                    repetition_id=start.repetition_id, policy_name=pub.policy_identity.name,
                    world_seed=start.world_seed, noise_seed=start.noise_seed, policy_seed=start.policy_seed,
                    intervention_budget=pub.intervention_budget,
                    max_decision_opportunities=start.max_decision_opportunities,
                    interventions_used=pub.terminal.interventions_used,
                    decision_opportunities_used=pub.terminal.decision_opportunities_used,
                    invalid_action_count=pub.terminal.invalid_action_count, terminal_failure_code=code,
                    abort_diagnostic=nothing, artifact_dir=artifact_dir)
                _append_ledger_record(ledger_path, row); push!(ledger, JSON3.read(JSON3.write(row))); push!(ledger_ids, id)
                _append_journal(journal_path, (event="attempt_finished", run_id=id, outcome="adopted"))
                continue
            end
        end
        row = (schema_version=1, recorded_at=string(Dates.now(Dates.UTC)), run_id=id,
            status="interrupted", classification="infrastructure", condition_id=start.condition_id,
            repetition_id=start.repetition_id, policy_name=start.policy, world_seed=start.world_seed,
            noise_seed=start.noise_seed, policy_seed=start.policy_seed,
            intervention_budget=start.intervention_budget,
            max_decision_opportunities=start.max_decision_opportunities, interventions_used=0,
            decision_opportunities_used=0, invalid_action_count=0,
            terminal_failure_code="interrupted_attempt", abort_diagnostic="process_interrupted", artifact_dir=nothing)
        _append_ledger_record(ledger_path, row); push!(ledger, JSON3.read(JSON3.write(row))); push!(ledger_ids, id)
        _append_journal(journal_path, (event="attempt_finished", run_id=id, outcome="interrupted"))
    end
    ledger
end

function _validate_ledger(ledger)
    seen = Set{String}()
    for row in ledger
        String(row.run_id) in seen && error("duplicate attempt run ID in ledger")
        push!(seen, String(row.run_id))
        row.artifact_dir === nothing && continue # durable infrastructure record without persisted artifact
        records = load_run(String(row.artifact_dir))
        records.public.run_id == row.run_id == records.provenance.run_id == records.evaluator.run_id ||
            error("ledger/artifact run identity mismatch for $(row.run_id)")
        records.evaluator.condition_id == row.condition_id || error("ledger/artifact condition mismatch")
        records.provenance.world_seed == row.world_seed && records.provenance.noise_seed == row.noise_seed ||
            error("ledger/artifact seed mismatch")
        records.provenance.repetition_id == row.repetition_id || error("ledger/artifact repetition mismatch")
        records.public.intervention_budget == row.intervention_budget || error("ledger/artifact budget mismatch")
    end
    true
end

function _attempts_for(ledger, slot)
    filter(r -> r.condition_id == slot["condition_id"] && r.world_seed == slot["world_seed"] &&
        (r.policy_name === nothing || r.policy_name == slot["policy"]) && r.repetition_id !== nothing &&
        (r.repetition_id == slot["repetition_id"] || r.repetition_id == slot["repetition_id"] * "-retry1"), ledger)
end

function _verify_attempt(attempt, slot, root, commit)
    if attempt.artifact_dir === nothing
        attempt.classification == "infrastructure" || error("non-infrastructure attempt has no persisted artifact")
        r = attempt.record
        r.run_id == attempt.run_id && r.classification == "infrastructure" || error("undurable infrastructure attempt record")
        r.condition_id == slot["condition_id"] && r.world_seed == slot["world_seed"] || error("infrastructure ledger identity mismatch")
        r.repetition_id == slot["repetition_id"] || error("infrastructure repetition mismatch")
        r.intervention_budget == BUDGET || error("infrastructure budget mismatch")
        return true
    end
    records = load_run(attempt.artifact_dir)
    p, pub, ev = records.provenance, records.public, records.evaluator
    p.configuration.protocol_id == PROTOCOL || error("artifact protocol identity mismatch")
    p.git_commit == commit || error("artifact commit provenance mismatch")
    p.dirty_working_tree === false || error("artifact working tree is not verifiably clean")
    p.julia_version == "1.12.7" || error("artifact Julia version mismatch")
    p.manifest_sha256 == bytes2hex(sha256(read(joinpath(root, "Manifest.toml")))) || error("Manifest SHA-256 mismatch")
    p.world_seed == slot["world_seed"] && p.noise_seed == slot["noise_seed"] || error("artifact seed mismatch")
    p.repetition_id == slot["repetition_id"] || error("artifact repetition identity mismatch")
    ev.condition_id == slot["condition_id"] || error("artifact condition mismatch")
    pub.intervention_budget == BUDGET && p.configuration.max_decision_opportunities == OPPORTUNITIES || error("artifact budget mismatch")
    p.configuration.noise_condition == (slot["condition_id"] == "clean" ? "clean" : "gaussian") || error("artifact noise condition mismatch")
    if slot["policy"] == "random"
        p.policy_seed == slot["policy_seed"] || error("random seed mismatch")
    elseif slot["policy"] == "fixed_design"
        p.policy_seed === nothing || error("fixed policy unexpectedly has a seed")
    else
        cfg = p.configuration.policy
        cfg.provider_order == ["openai"] && cfg.provider_only == ["openai"] &&
            cfg.response_format == "strict_json_schema" && cfg.prompt_version == "scientist-v0-1" &&
            cfg.prompt_sha256 == "0b800b3ac2606ac8edd47defd9e185fdd11eb07ba30d57cad65ef02a29c04aba" &&
            cfg.schema_version == "experiment-action-v1" &&
             cfg.requested_model == "openai/gpt-5.6-luna" && cfg.reasoning_effort == "medium" &&
            cfg.max_completion_tokens == 512 && cfg.allow_fallbacks == false && cfg.require_parameters == true ||
            error("scientist treatment provenance mismatch")
        cfg.seed === nothing || error("provider seed must be omitted")
    end
    true
end

function _run_slot(slot, root, commit, raw, ledger_path, journal_path, provider_cfg)
    condition, policy_name = slot["condition_id"], slot["policy"]
    world = generate_world(slot["world_seed"])
    noise = condition == "clean" ? CleanObservation() : GaussianObservationNoise(0.10)
    policy = policy_name == "random" ? RandomPolicy(slot["policy_seed"]) :
        policy_name == "fixed_design" ? FixedDesignPolicy() : ScientistPolicy(OpenRouterClient(provider_cfg))
    config = RunConfig(BUDGET; max_decision_opportunities=OPPORTUNITIES,
        observation_noise=noise, noise_seed=slot["noise_seed"])
    _assert_identity(root, commit)
    run_id = new_run_id()
    _append_journal(journal_path, (event="attempt_started", slot_id=slot["slot_id"], run_id,
        repetition_id=slot["repetition_id"], policy=policy_name, world_seed=slot["world_seed"],
        noise_seed=slot["noise_seed"], policy_seed=slot["policy_seed"],
        intervention_budget=BUDGET, max_decision_opportunities=OPPORTUNITIES,
        protocol_id=PROTOCOL, condition_id=condition))
    attempt = run_attempt(world, policy, config; root, artifacts_root=raw, ledger_path,
        repetition_id=slot["repetition_id"], condition_id=condition, protocol_id=PROTOCOL, run_id)
    _verify_attempt(attempt, slot, root, commit)
    _append_journal(journal_path, (event="attempt_finished", run_id, outcome=attempt.classification))
    attempt
end

function _operational_summary(slots, ledger)
    costs = Float64[]; tokens_in = 0; tokens_out = 0; requests = 0; latencies = Float64[]
    providers = Set{String}()
    for row in ledger
        dir = row.artifact_dir
        dir === nothing && continue
        path = String(dir)
        isfile(joinpath(path, "public.json")) || continue
        public = JSON3.read(read(joinpath(path, "public.json"), String))
        for event in public.events
            m = event.operational_metadata
            m === nothing && continue
            requests += 1
            m.provider === nothing || push!(providers, String(m.provider))
            m.cost === nothing || push!(costs, Float64(m.cost))
            m.input_tokens === nothing || (tokens_in += Int(m.input_tokens))
            m.output_tokens === nothing || (tokens_out += Int(m.output_tokens))
            m.latency_s === nothing || push!(latencies, Float64(m.latency_s))
        end
    end
    println("logical slots: ", count(s -> s["status"] in ("completed", "behavioral_failure", "terminal_infrastructure"), slots), "/", length(slots))
    println("behavioral failures: ", count(s -> s["status"] == "behavioral_failure", slots))
    println("terminal infrastructure slots: ", count(s -> s["status"] == "terminal_infrastructure", slots))
    println("infrastructure retries used: ", count(s -> s["retry_status"] != "not_applicable" && s["retry_status"] != "not_used", slots))
    println("provider requests recorded: $requests; input tokens: $tokens_in; output tokens: $tokens_out")
    println("recorded cost USD: ", sum(costs; init=0.0), "; provider variants: ", join(sort!(collect(providers)), ", "))
    println("latency seconds recorded: ", sum(latencies; init=0.0))
    nothing
end

function main(args=ARGS)
    root = normpath(joinpath(@__DIR__, ".."))
    dry = "--dry-run" in args || "--plan" in args
    state_root = joinpath(root, "results", "confirmatory-v0.1-prereg-4")
    plan_path = joinpath(state_root, "execution-plan.json")
    state_path = joinpath(state_root, "execution-state.json")
    ledger_path = joinpath(state_root, "run-ledger.jsonl")
    journal_path = joinpath(state_root, "attempt-journal.jsonl")
    raw = joinpath(root, "results", "raw")
    slots = build_matrix(joinpath(root, "research", "confirmatory-seeds-v0.1-prereg-4.toml"))
    println("120 logical slots; 40 scientist slots; 80 baseline slots; 320 nominal provider requests")
    println("30 matched worlds in gaussian_0.10 primary; 10 matched worlds in clean descriptive condition")
    if dry
        println("planned_matrix_json: ", JSON3.write((protocol_id=PROTOCOL, slots)))
        return slots
    end
    VERSION == v"1.12.7" || error("Julia 1.12.7 required; found $VERSION")
    commit = _repo(root, :commit)
    isempty(commit) && error("repository commit provenance unavailable")
    isempty(_source_dirty(root)) || error("confirmatory checkout must be clean before execution")
    manifest = TOML.parsefile(joinpath(root, "research", "confirmatory-seeds-v0.1-prereg-4.toml"))
    pilot_seeds = Set([7122123, 7122124, 7122125, 7122126])
    isempty(intersect(pilot_seeds, Set(w["world_seed"] for w in manifest["worlds"]))) || error("pilot seed overlap")
    if isfile(plan_path)
        saved = JSON3.read(read(plan_path, String))
        saved.protocol_id == PROTOCOL && saved.commit == commit || error("existing execution plan does not match current frozen identity")
        _validate_saved_slots(saved.slots, slots) || error("execution plan matrix mismatch")
    else
        mkpath(state_root)
        _write_json(plan_path, (schema_version=1, protocol_id=PROTOCOL, commit, julia_version=string(VERSION), created_at=string(Dates.now(Dates.UTC)), slots))
    end
    if isfile(state_path)
        saved = JSON3.read(read(state_path, String))
        saved.commit == commit || error("execution state commit mismatch")
        slots = _restore_mutable_slots(slots, saved.slots)
    else
        _write_json(state_path, (schema_version=1, commit, slots))
    end
    ledger = _reconcile_journal!(journal_path, ledger_path, raw, slots)
    _validate_ledger(ledger)
    if any(s -> s["policy"] == "scientist" && retry_decision(String.(getproperty.(_attempts_for(ledger, s), :classification))) in (:pending, :retry), slots)
        isempty(strip(get(ENV, "OPENROUTER_API_KEY", ""))) &&
            error("OPENROUTER_API_KEY required before any confirmatory execution; plan/state preserved")
    end
    for slot in slots
        attempts = _attempts_for(ledger, slot)
        slot["run_ids"] = unique(vcat(String.(slot["run_ids"]), String[String(a.run_id) for a in attempts]))
        decision = retry_decision(String.(getproperty.(attempts, :classification)))
        if decision in (:completed, :behavioral_failure, :terminal_infrastructure)
            slot["status"] = String(decision)
            continue
        end
        retry = decision == :retry
        repetition = retry ? slot["repetition_id"] * "-retry1" : slot["repetition_id"]
        slot["retry_status"] = retry ? "retry_pending" : slot["retry_status"]
        slot["status"] = retry ? "retry_pending" : "running"
        provider_cfg = slot["policy"] == "scientist" ? load_openrouter_config(joinpath(root, "configs", "v0.1-frontier.toml")) : nothing
        attempt_slot = copy(slot)
        attempt_slot["repetition_id"] = repetition
        attempt = _run_slot(attempt_slot, root, commit, raw, ledger_path, journal_path, provider_cfg)
        push!(slot["run_ids"], attempt.run_id)
        push!(ledger, attempt.record)
        _write_json(state_path, (schema_version=1, commit, slots))
        _assert_identity(root, commit)
        if attempt.classification == "infrastructure" && !retry
            slot["status"] = "infrastructure_pending_retry"
            slot["retry_status"] = "retry_pending"
            _write_json(state_path, (schema_version=1, commit, slots))
            retry_slot = copy(slot)
            retry_slot["repetition_id"] = slot["repetition_id"] * "-retry1"
            retry_attempt = _run_slot(retry_slot, root, commit, raw, ledger_path, journal_path, provider_cfg)
            push!(slot["run_ids"], retry_attempt.run_id)
            push!(ledger, retry_attempt.record)
            slot["retry_status"] = "used"
            slot["status"] = retry_attempt.classification == "infrastructure" ? "terminal_infrastructure" : retry_attempt.classification
        else
            slot["status"] = attempt.classification
            slot["retry_status"] = retry ? "used" : "not_used"
        end
        _write_json(state_path, (schema_version=1, commit, slots))
    end
    _write_json(state_path, (schema_version=1, commit, slots))
    _operational_summary(slots, ledger)
    println("plan: $plan_path\nstate: $state_path\nledger: $ledger_path\nraw artifacts: $raw")
    slots
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    using Dates
    ConfirmatoryV01.main()
end
