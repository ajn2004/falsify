using JSON3

"""Deterministic slot-level reliability report from execution plan/state/ledger/journal."""
module ReliabilityReportV02
using JSON3

readj(path) = [JSON3.read(line) for line in eachline(path) if !isempty(strip(line))]

function summarize(execution_dir; threshold=0.95, output=nothing)
    0 < threshold <= 1 || throw(ArgumentError("threshold must be in (0,1]"))
    plan = JSON3.read(read(joinpath(execution_dir, "execution-plan.json"), String))
    state = JSON3.read(read(joinpath(execution_dir, "execution-state.json"), String))
    ledger = readj(joinpath(execution_dir, "run-ledger.jsonl"))
    journal = readj(joinpath(execution_dir, "attempt-journal.jsonl"))
    starts = Dict(String(x.run_id)=>x for x in journal if x.event == "attempt_started")
    length(starts) == length(ledger) || error("journal/ledger attempt count mismatch")
    byslot = Dict{String,Vector{Any}}()
    scientist_attempts = Any[]
    retry_violations = String[]
    apparatus_slots = String[]
    for row in ledger
        id = String(row.run_id); haskey(starts, id) || error("ledger attempt absent from journal: $id")
        j = starts[id]; slot = String(j.slot_id)
        push!(get!(byslot, slot, Any[]), row)
        String(j.policy) == "scientist" && push!(scientist_attempts, row)
    end
    scientist_slots = filter(s -> s.policy == "scientist", plan.slots)
    codes = Dict{String,Int}()
    attempt_numbers = Dict{String,Int}()
    attempt_counts = Dict{String,Int}()
    for row in scientist_attempts
        code = row.terminal_failure_code === nothing ? nothing : String(row.terminal_failure_code)
        code === nothing || (codes[code] = get(codes, code, 0) + 1)
        run_id = String(row.run_id)
        slot_id = String(starts[run_id].slot_id)
        n = get(attempt_counts, slot_id, 0) + 1
        attempt_counts[slot_id] = n
        attempt_numbers[run_id] = n
    end
    slot_records = Any[]
    for slot in scientist_slots
        id = String(slot.slot_id); attempts = get(byslot, id, Any[])
        isempty(attempts) && error("planned scientist slot has no attempt: $id")
        length(attempts) <= 2 || push!(retry_violations, id)
        statuses = String.(getproperty.(attempts, :classification))
        length(unique(String(starts[String(a.run_id)].repetition_id) for a in attempts)) == length(attempts) || error("duplicate attempt identity: $id")
        any(x -> x == "apparatus_failure", statuses) && push!(apparatus_slots, id)
        length(attempts) > 1 && first(statuses) != "infrastructure" && push!(retry_violations, "$id:retry_without_infrastructure")
        terminal_attempt = Base.last(attempts)
        saved_slot = only(filter(s -> s.slot_id == slot.slot_id, state.slots))
        Set(String.(saved_slot.run_ids)) == Set(String.(a.run_id for a in attempts)) || error("resume slot/attempt ledger mismatch: $id")
        push!(slot_records, (slot_id=id, condition_id=String(slot.condition_id), world_seed=Int(slot.world_seed),
            attempt_count=length(attempts), resolution=String(terminal_attempt.classification),
            terminal_infrastructure=terminal_attempt.classification == "infrastructure",
            recovered_infrastructure=length(attempts)==2 && first(attempts).classification=="infrastructure" && terminal_attempt.classification!="infrastructure"))
    end
    attempt_details = Any[]
    for row in ledger
        j = starts[String(row.run_id)]
        String(j.policy) == "scientist" || continue
        rawdir = joinpath(dirname(dirname(execution_dir)), "results", "raw", String(row.run_id))
        pubpath = joinpath(rawdir, "public.json")
        pub = isfile(pubpath) ? JSON3.read(read(pubpath, String)) : nothing
        provpath = joinpath(rawdir, "provenance.json")
        prov = isfile(provpath) ? JSON3.read(read(provpath, String)) : nothing
        events = pub === nothing ? Any[] : pub.events
        last_event = isempty(events) ? nothing : last(events)
        op = last_event === nothing ? nothing : last_event.operational_metadata
        failure_code = row.terminal_failure_code
        push!(attempt_details, (slot_id=String(j.slot_id), run_id=String(row.run_id),
            attempt_number=attempt_numbers[String(row.run_id)],
            condition_id=String(j.condition_id), policy=String(j.policy), repetition_id=String(j.repetition_id),
            provider_model=op === nothing ? nothing : op.model, terminal_classification=String(row.classification),
            provider_configuration=prov === nothing ? nothing : prov.configuration.policy,
            failure_code=failure_code,
            http_response_received=op === nothing ? nothing : op.http_status !== nothing,
            usable_provider_response=op === nothing ? nothing :
                (op.http_status == 200 && String(row.classification) != "infrastructure"),
            structured_parse_succeeded=failure_code == "malformed_response" ? false :
                (failure_code === nothing && last_event !== nothing ? true : nothing),
            action_valid=last_event === nothing || last_event.validation_valid === nothing ? nothing : last_event.validation_valid,
            controller_execution_began=Int(row.decision_opportunities_used)>0,
            retry_occurred=length(get(byslot, String(j.slot_id), Any[])) > 1,
            retry_basis=String(row.classification)=="infrastructure" ? "frozen infrastructure class; one retry maximum" : "not retry eligible"))
    end
    length(unique(x.slot_id for x in slot_records)) == length(scientist_slots) || error("duplicate logical slot")
    completed = count(x -> x.resolution == "completed", slot_records)
    behavioral = count(x -> x.resolution == "behavioral_failure", slot_records)
    terminal_infra = count(x -> x.terminal_infrastructure, slot_records)
    recovered = count(x -> x.recovered_infrastructure, slot_records)
    denom = length(slot_records)
    rate = denom == 0 ? 0.0 : (denom-terminal_infra)/denom
    conditions = Dict{String,Any}()
    for condition in sort!(unique(x.condition_id for x in slot_records))
        xs = filter(x -> x.condition_id == condition, slot_records)
        conditions[condition] = (logical_slots=length(xs), terminal_infrastructure_slots=count(x->x.terminal_infrastructure,xs),
            behavioral_terminal_slots=count(x->x.resolution=="behavioral_failure",xs),
            infrastructure_success_rate=(length(xs)-count(x->x.terminal_infrastructure,xs))/length(xs))
    end
    report = (report_version="falsify-reliability-report-v1", protocol_version=String(plan.protocol_id),
        total_logical_slots=denom, total_raw_attempts=length(scientist_attempts),
        all_policy_raw_attempts=length(ledger), completed_slots=completed,
        behavioral_terminal_slots=behavioral, infrastructure_terminal_slots=terminal_infra,
        recovered_infrastructure_slots=recovered, infrastructure_success_rate=rate,
        failure_counts_by_code=codes, by_condition=conditions, attempts=attempt_details, duplicate_slot_audit="pass",
        apparatus_failure_slots=apparatus_slots, retry_bound_violations=retry_violations, retry_max_attempts=2, threshold=Float64(threshold),
        gate_pass=rate >= threshold && isempty(retry_violations) && isempty(apparatus_slots), gate_denominator="planned ScientistPolicy logical slots",
        recovered_slots_count_as_success=true, behavioral_failures_count_as_infrastructure_failure=false,
        apparatus_defects_count_as_gate_failure=true)
    if output !== nothing
        open(output, "w") do io
            write(io, JSON3.write(report)); write(io, '\n')
        end
    end
    report
end
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) >= 1 || error("usage: julia --project=. scripts/reliability_report_v0_2.jl EXECUTION_DIR [THRESHOLD] [OUTPUT.json]")
    threshold = length(ARGS) >= 2 ? parse(Float64, ARGS[2]) : 0.95
    output = length(ARGS) >= 3 ? ARGS[3] : nothing
    r = ReliabilityReportV02.summarize(ARGS[1]; threshold, output)
    println("protocol=$(r.protocol_version) slots=$(r.total_logical_slots) attempts=$(r.total_raw_attempts) infrastructure_rate=$(r.infrastructure_success_rate) gate=$(r.gate_pass ? "PASS" : "FAIL")")
    println("completed=$(r.completed_slots) behavioral_terminal=$(r.behavioral_terminal_slots) infrastructure_terminal=$(r.infrastructure_terminal_slots) recovered_infrastructure=$(r.recovered_infrastructure_slots) apparatus_defects=$(length(r.apparatus_failure_slots))")
    for condition in sort!(collect(keys(r.by_condition)))
        row = r.by_condition[condition]
        println("condition=$condition slots=$(row.logical_slots) infrastructure_terminal=$(row.terminal_infrastructure_slots) behavioral_terminal=$(row.behavioral_terminal_slots) infrastructure_rate=$(row.infrastructure_success_rate)")
    end
end
