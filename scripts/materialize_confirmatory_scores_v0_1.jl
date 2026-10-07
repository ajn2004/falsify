module ConfirmatoryScoreMaterializer

using Falsify
using JSON3
using SHA
using Dates

const PROTOCOL = "falsify-v0.1-prereg-4"
const EXECUTION = "results/confirmatory-v0.1-prereg-4"
const OUTPUT = "results/derived/v0.1-evaluator"

export materialize, attempt_records, score_row

function sha256_file(path)
    bytes2hex(sha256(read(path)))
end

function csv_value(x)
    x === nothing && return ""
    s = x isa Bool ? string(x) : string(x)
    occursin(r"[\",\r\n]", s) ? "\"" * replace(s, "\""=>"\"\"") * "\"" : s
end

function write_csv(path, rows, fields)
    open(path, "w") do io
        println(io, join(fields, ','))
        for row in rows
            println(io, join((csv_value(getproperty(row, Symbol(f))) for f in fields), ','))
        end
    end
end

function jsonl(path, rows)
    open(path, "w") do io
        for row in rows
            println(io, JSON3.write(row))
        end
    end
end

function file_tree_hash(root)
    rows = String[]
    for (dir, _, files) in walkdir(root)
        for file in files
            path = joinpath(dir, file)
            push!(rows, relpath(path, root) * ":" * sha256_file(path))
        end
    end
    bytes2hex(sha256(join(sort(rows), "\n")))
end

function read_jsonl(path)
    [JSON3.read(line) for line in eachline(path) if !isempty(strip(line))]
end

function slot_map(plan)
    plan.protocol_id == PROTOCOL || error("execution plan protocol mismatch")
    result = Dict{String,Any}()
    for slot in plan.slots
        slot.protocol_id == PROTOCOL || error("unregistered protocol in plan")
        expected_rep = slot.policy == "random" ? "random" : slot.policy == "fixed_design" ? "fixed" : "scientist-1"
        slot.repetition_id == expected_rep || error("unexpected repetition identity for $(slot.slot_id)")
        haskey(result, String(slot.slot_id)) && error("duplicate plan slot")
        result[String(slot.slot_id)] = slot
    end
    length(result) == 120 || error("unexpected prereg-4 slot count")
    result
end

function attempt_records(root)
    execution = joinpath(root, EXECUTION)
    plan_path = joinpath(execution, "execution-plan.json")
    ledger_path = joinpath(execution, "run-ledger.jsonl")
    journal_path = joinpath(execution, "attempt-journal.jsonl")
    plan = JSON3.read(read(plan_path, String))
    slots = slot_map(plan)
    ledger = read_jsonl(ledger_path)
    journal = read_jsonl(journal_path)

    starts = Dict{String,Any}()
    for row in journal
        row.event == "attempt_started" || continue
        id = String(row.run_id)
        haskey(starts, id) && error("duplicate journal start for $id")
        slotid = String(row.slot_id)
        haskey(slots, slotid) || error("journal contains unregistered slot $slotid")
        slot = slots[slotid]
        row.protocol_id == PROTOCOL || error("journal protocol mismatch")
        for (field, slotfield) in ((:condition_id,:condition_id), (:world_seed,:world_seed), (:noise_seed,:noise_seed))
            getproperty(row, field) == getproperty(slot, slotfield) || error("journal identity mismatch for $id")
        end
        policy = String(slot.policy)
        expected_policy = policy
        String(row.policy) == expected_policy || error("journal policy mismatch for $id")
        rep = String(row.repetition_id)
        (rep == String(slot.repetition_id) || rep == String(slot.repetition_id) * "-retry1") || error("unregistered repetition for $id")
        starts[id] = (slot=slot, journal=row)
    end

    by_id = Dict{String,Any}()
    for row in ledger
        id = String(row.run_id)
        haskey(by_id, id) && error("duplicate ledger run ID $id")
        haskey(starts, id) || error("ledger attempt absent from journal: $id")
        start = starts[id]
        slot = start.slot
        row.condition_id == slot.condition_id && row.world_seed == slot.world_seed || error("ledger slot identity mismatch for $id")
        row.noise_seed == slot.noise_seed || error("ledger noise seed mismatch for $id")
        row.repetition_id == start.journal.repetition_id || error("ledger repetition mismatch for $id")
        row.policy_name === nothing || row.policy_name == slot.policy || error("ledger policy mismatch for $id")
        rep = String(row.repetition_id)
        rep == slot.repetition_id || rep == String(slot.repetition_id) * "-retry1" || error("unregistered retry for $id")
        by_id[id] = (ledger=row, slot=slot)
    end
    Set(keys(by_id)) == Set(keys(starts)) || error("journal/ledger attempt population mismatch")

    rows = NamedTuple[]
    for id in sort!(collect(keys(by_id)))
        pair = by_id[id]
        l, slot = pair.ledger, pair.slot
        l.classification in ("completed", "behavioral_failure", "infrastructure") || error("unknown classification for $id")
        base = (run_id=id, protocol_id=PROTOCOL, condition_id=String(slot.condition_id),
            world_seed=Int(slot.world_seed), policy_name=String(slot.policy),
            repetition_id=String(l.repetition_id), status=String(l.status), classification=String(l.classification),
            score_status="unscored_infrastructure", parameter_error=nothing,
            prediction_error=nothing, parameter_success=nothing)
        if l.classification != "infrastructure"
            l.artifact_dir === nothing && error("scientifically valid run lacks persisted artifact: $id")
            # Ledger artifact_dir is provenance/audit metadata; run_id is the portable identity.
            artdir = joinpath(root, "results", "raw", id)
            all(isfile(joinpath(artdir, f)) for f in ("public.json", "provenance.json", "evaluator.json")) ||
                error("incomplete artifact directory for $id")
            records = Falsify.load_run(artdir)
            p, pub, ev = records.provenance, records.public, records.evaluator
            pub.run_id == p.run_id == ev.run_id == id || error("artifact/ledger run ID mismatch for $id")
            p.configuration.protocol_id == PROTOCOL || error("artifact protocol mismatch for $id")
            p.world_seed == slot.world_seed && p.noise_seed == slot.noise_seed || error("artifact seed mismatch for $id")
            p.repetition_id == l.repetition_id || error("artifact repetition mismatch for $id")
            ev.condition_id == slot.condition_id || error("artifact condition mismatch for $id")
            pub.policy_identity.name == slot.policy || error("artifact policy mismatch for $id")
            actual_class = Falsify.classify_run(pub.status, pub.terminal.failure === nothing ? nothing : pub.terminal.failure.code)
            actual_class == l.classification || error("classification disagrees with artifact for $id")
            metrics = Falsify.score_run(records)
            score_status = l.classification == "behavioral_failure" ? "scored_behavioral_failure" : "scored"
            push!(rows, merge(base, (score_status=score_status,
                parameter_error=metrics.parameter_error,
                prediction_error=metrics.heldout_prediction_error,
                parameter_success=metrics.success)))
        else
            if l.artifact_dir !== nothing
                artdir = joinpath(root, "results", "raw", id)
                if all(isfile(joinpath(artdir, f)) for f in ("public.json", "provenance.json", "evaluator.json"))
                    records = Falsify.load_run(artdir)
                    records.public.run_id == records.provenance.run_id == records.evaluator.run_id == id || error("artifact/ledger run ID mismatch for $id")
                    records.provenance.configuration.protocol_id == PROTOCOL || error("artifact protocol mismatch for $id")
                    records.public.status == "aborted" || Falsify.classify_run(records.public.status,
                        records.public.terminal.failure === nothing ? nothing : records.public.terminal.failure.code) == "infrastructure" ||
                        error("infrastructure ledger classification disagrees with artifact")
                end
            end
            push!(rows, base)
        end
    end
    rows
end

const FIELDS = ("run_id", "protocol_id", "condition_id", "world_seed", "policy_name", "repetition_id",
    "status", "classification", "score_status", "parameter_error", "prediction_error", "parameter_success")
score_row(row) = NamedTuple{Tuple(Symbol.(FIELDS))}(Tuple(getproperty(row, Symbol(f)) for f in FIELDS))

function materialize(root=normpath(joinpath(@__DIR__, "..")))
    VERSION == v"1.12.7" || error("Julia 1.12.7 required; found $VERSION")
    raw = joinpath(root, "results", "raw")
    execution = joinpath(root, EXECUTION)
    raw_before, execution_before = file_tree_hash(raw), file_tree_hash(execution)
    plan_path = joinpath(execution, "execution-plan.json")
    ledger_path = joinpath(execution, "run-ledger.jsonl")
    rows = attempt_records(root)
    output = joinpath(root, OUTPUT)
    mkpath(output)
    rows_path = map(score_row, rows)
    write_csv(joinpath(output, "run_scores.csv"), rows_path, FIELDS)
    jsonl(joinpath(output, "run_scores.jsonl"), rows_path)
    source_file = joinpath(root, "src", "evaluation", "Metrics.jl")
    materializer_source_file = joinpath(root, "scripts", "materialize_confirmatory_scores_v0_1.jl")
    materialization_commit = try
        strip(read(`git -C $root rev-parse HEAD`, String))
    catch
        strip(read(`jj -R $root log -r @ --no-graph -T commit_id`, String))
    end
    provenance = (schema_version=1, protocol_id=PROTOCOL,
        execution_commit=String(JSON3.read(read(plan_path, String)).commit),
        materialization_commit=materialization_commit,
        materializer_source_sha256=sha256_file(materializer_source_file),
        julia_version=string(VERSION), manifest_sha256=sha256_file(joinpath(root, "Manifest.toml")),
        score_run_source_sha256=sha256_file(source_file),
        execution_plan_sha256=sha256_file(plan_path), run_ledger_sha256=sha256_file(ledger_path),
        run_scores_jsonl_sha256=sha256_file(joinpath(output, "run_scores.jsonl")),
        run_scores_csv_sha256=sha256_file(joinpath(output, "run_scores.csv")),
        attempts_considered=length(rows), scientifically_scored=count(r -> r.score_status in ("scored", "scored_behavioral_failure"), rows),
        behavioral_failure_scored=count(r -> r.score_status == "scored_behavioral_failure", rows),
        infrastructure_unscored=count(r -> r.score_status == "unscored_infrastructure", rows),
        timestamp_utc=string(Dates.now(Dates.UTC)))
    open(joinpath(output, "evaluation-provenance.json"), "w") do io
        println(io, JSON3.write(provenance))
    end
    raw_before == file_tree_hash(raw) || error("raw artifacts changed during materialization")
    execution_before == file_tree_hash(execution) || error("execution inputs changed during materialization")
    println("attempts: $(length(rows)); scored: $(provenance.scientifically_scored); behavioral failures: $(provenance.behavioral_failure_scored); infrastructure unscored: $(provenance.infrastructure_unscored)")
    println("scores: $output/run_scores.csv and $output/run_scores.jsonl")
    rows
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    ConfirmatoryScoreMaterializer.materialize()
end
