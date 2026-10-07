module ConfirmatoryV01Analysis

using JSON3, SHA, Random, Dates

const PROTOCOL = "falsify-v0.1-prereg-4"
const EXEC = "results/confirmatory-v0.1-prereg-4"
const SCORES = "results/derived/v0.1-evaluator"
const OUT = "results/derived/v0.1-confirmatory"
const BOOTSTRAPS = 10_000
const BOOTSTRAP_SEED = 9_123_999
const PRIMARY_POLICIES = ("random", "fixed_design", "scientist")
const OP_EXPECTED = (requests=344, input_tokens=2_773_398, output_tokens=74_739,
    cost=0.7709560399999997, latency=1688.6768774986267)

export analyze, resolve_attempts, paired_bootstrap

readj(path) = JSON3.read(read(path, String))
readlines_json(path) = [JSON3.read(line) for line in eachline(path) if !isempty(strip(line))]
filehash(path) = bytes2hex(sha256(read(path)))

function csvval(v)
    v === nothing && return ""
    s = string(v)
    occursin(r"[\",\r\n]", s) ? "\"" * replace(s, "\""=>"\"\"") * "\"" : s
end
function csv_matches(value, cell)
    value isa Bool && return lowercase(cell)==string(value)
    if value isa Number
        parsed=tryparse(Float64,cell)
        return parsed!==nothing && Float64(value)==parsed
    end
    csvval(value)==cell
end
function csvwrite(path, rows, fields)
    open(path, "w") do io
        println(io, join(fields, ','))
        for row in rows
            println(io, join((csvval(getproperty(row, Symbol(f))) for f in fields), ','))
        end
    end
end
function jsonwrite(path, x)
    open(path, "w") do io
        println(io, JSON3.write(x))
    end
end
function jsonlwrite(path, rows)
    open(path, "w") do io
        foreach(row -> println(io, JSON3.write(row)), rows)
    end
end

function validate_provenance(root, planpath, ledgerpath)
    ep = readj(joinpath(root, SCORES, "evaluation-provenance.json"))
    ep.protocol_id == PROTOCOL || error("evaluator score protocol mismatch")
    ep.execution_commit == readj(planpath).commit || error("evaluator/execution commit mismatch")
    ep.julia_version == "1.12.7" || error("evaluator Julia version mismatch")
    ep.manifest_sha256 == filehash(joinpath(root, "Manifest.toml")) || error("Manifest hash mismatch")
    ep.execution_plan_sha256 == filehash(planpath) || error("execution plan hash mismatch")
    ep.run_ledger_sha256 == filehash(ledgerpath) || error("run ledger hash mismatch")
    ep.run_scores_jsonl_sha256 == filehash(joinpath(root,SCORES,"run_scores.jsonl")) || error("run_scores.jsonl hash mismatch")
    ep.run_scores_csv_sha256 == filehash(joinpath(root,SCORES,"run_scores.csv")) || error("run_scores.csv hash mismatch")
    ep.score_run_source_sha256 == filehash(joinpath(root,"src","evaluation","Metrics.jl")) || error("frozen scorer source hash mismatch")
    ep.attempts_considered == 140 && ep.scientifically_scored == 109 &&
        ep.behavioral_failure_scored == 4 && ep.infrastructure_unscored == 31 ||
        error("unexpected evaluator materialization accounting")
    ep
end

hypothesis_supported(results, hypothesis) = begin
    endpoints=filter(r->r.hypothesis==hypothesis,results)
    length(endpoints)==2 && all(r->r.ci_high<0,endpoints)
end

function resolve_attempts(root)
    ex = joinpath(root, EXEC)
    planpath, statepath, ledgerpath, journalpath = (joinpath(ex, n) for n in
        ("execution-plan.json", "execution-state.json", "run-ledger.jsonl", "attempt-journal.jsonl"))
    plan, state = readj(planpath), readj(statepath)
    plan.protocol_id == PROTOCOL || error("execution plan protocol mismatch")
    plan.commit == state.commit || error("execution plan/state commit mismatch")
    length(plan.slots) == length(state.slots) == 120 || error("unexpected logical slot count")
    expected_slots = Dict{String,Any}()
    state_by_slot = Dict{String,Any}()
    for (ps, ss) in zip(plan.slots, state.slots)
        ps.slot_id == ss.slot_id && ps.protocol_id == PROTOCOL || error("plan/state slot mismatch")
        for key in (:world_seed, :condition_id, :policy, :repetition_id, :noise_seed, :policy_seed)
            getproperty(ps, key) == getproperty(ss, key) || error("frozen identity changed for $(ps.slot_id): $key")
        end
        slotid = String(ps.slot_id)
        haskey(expected_slots, slotid) && error("duplicate logical slot")
        expected_slots[slotid] = ps
        state_by_slot[slotid] = ss
    end
    # Prereg-4 explicitly has one scientist repetition in every planned world.
    all(s -> s.policy != "scientist" || s.repetition_id == "scientist-1", plan.slots) || error("unexpected scientist repetition")

    starts = Dict{String,Any}()
    for j in readlines_json(journalpath)
        j.event == "attempt_started" || continue
        id = String(j.run_id)
        haskey(starts, id) && error("duplicate journal start: $id")
        slotid = String(j.slot_id)
        haskey(expected_slots, slotid) || error("journal points to unregistered slot $slotid")
        j.protocol_id == PROTOCOL || error("journal protocol mismatch")
        slot = expected_slots[slotid]
        String(j.policy) == String(slot.policy) || error("journal policy mismatch")
        for k in (:condition_id, :world_seed, :noise_seed)
            getproperty(j, k) == getproperty(slot, k) || error("journal identity mismatch: $id / $k")
        end
        rep = String(j.repetition_id)
        (rep == String(slot.repetition_id) || rep == String(slot.repetition_id) * "-retry1") || error("unregistered retry: $rep")
        starts[id] = (slot=slot, journal=j)
    end
    finished = Set(String(j.run_id) for j in readlines_json(journalpath) if j.event == "attempt_finished")
    finished == Set(keys(starts)) || error("attempt journal start/finish identity mismatch")

    ledger = readlines_json(ledgerpath)
    score_rows = readlines_json(joinpath(root, SCORES, "run_scores.jsonl"))
    length(ledger) == 140 && length(score_rows) == 140 || error("attempt-level accounting differs from 140")
    csvpath=joinpath(root,SCORES,"run_scores.csv")
    csvlines=readlines(csvpath)
    length(csvlines)==length(score_rows)+1 || error("CSV/JSONL score row cardinality mismatch")
    headers=split(first(csvlines),',')
    for (line,row) in zip(csvlines[2:end],score_rows)
        cells=split(line,',';keepempty=true)
        length(cells)==length(headers) || error("malformed score CSV")
        for (header,value) in zip(headers,cells)
            expected=getproperty(row,Symbol(header))
            csv_matches(expected,value) || error("CSV and JSONL score outputs disagree for $(row.run_id): $header")
        end
    end
    led = Dict{String,Any}()
    for l in ledger
        id = String(l.run_id)
        haskey(led, id) && error("duplicate ledger ID")
        haskey(starts, id) || error("ledger ID missing from prereg-4 journal")
        slot = starts[id].slot
        for (f, expected) in ((:condition_id,slot.condition_id), (:world_seed,slot.world_seed),
                (:noise_seed,slot.noise_seed), (:repetition_id,starts[id].journal.repetition_id))
            getproperty(l, f) == expected || error("ledger identity mismatch $id / $f")
        end
        l.policy_name === nothing || l.policy_name == slot.policy || error("ledger policy mismatch")
        led[id] = l
    end
    Set(keys(led)) == Set(keys(starts)) || error("ledger/journal set mismatch")
    scores = Dict{String,Any}()
    for r in score_rows
        id = String(r.run_id)
        haskey(scores, id) && error("duplicate score run ID")
        haskey(led, id) || error("score not present in prereg-4 ledger")
        l, slot = led[id], starts[id].slot
        r.protocol_id == PROTOCOL && r.condition_id == slot.condition_id && r.world_seed == slot.world_seed &&
            r.policy_name == slot.policy && r.repetition_id == l.repetition_id || error("score identity mismatch $id")
        r.classification == l.classification || error("score classification mismatch $id")
        if l.classification == "infrastructure"
            r.score_status == "unscored_infrastructure" && r.parameter_error === nothing && r.prediction_error === nothing ||
                error("infrastructure score was fabricated")
        else
            r.score_status in ("scored", "scored_behavioral_failure") || error("valid attempt missing persisted score")
            r.parameter_error !== nothing && r.prediction_error !== nothing || error("persisted endpoint missing")
            l.classification == "behavioral_failure" &&
                (r.parameter_error == 1.0 && r.prediction_error == 1.0) || l.classification != "behavioral_failure" ||
                error("behavioral failure score differs from frozen contract")
        end
        scores[id] = r
    end
    Set(keys(scores)) == Set(keys(led)) || error("score/ledger attempt set mismatch")

    attempts = NamedTuple[]
    for id in sort!(collect(keys(led)))
        slot, j, l, r = starts[id].slot, starts[id].journal, led[id], scores[id]
        push!(attempts, (slot_id=String(j.slot_id), run_id=id, protocol_id=PROTOCOL,
            condition_id=String(slot.condition_id), world_seed=Int(slot.world_seed),
            policy=String(slot.policy), repetition_id=String(l.repetition_id),
            attempt_kind=l.repetition_id == slot.repetition_id ? "original" : "retry1",
            status=String(l.status), classification=String(l.classification),
            score_status=String(r.score_status), parameter_error=r.parameter_error,
            prediction_error=r.prediction_error, parameter_success=r.parameter_success,
            artifact_dir=joinpath("results","raw",id), interventions_used=Int(l.interventions_used),
            decision_opportunities_used=Int(l.decision_opportunities_used),
            invalid_action_count=Int(l.invalid_action_count), terminal_failure_code=l.terminal_failure_code))
    end

    grouped = Dict{String,Vector{Int}}()
    for (i,a) in enumerate(attempts)
        push!(get!(grouped, a.slot_id, Int[]), i)
    end
    slots_out = NamedTuple[]
    for pslot in plan.slots
        slotid = String(pslot.slot_id)
        inds = get(grouped, slotid, Int[])
        length(inds) in (1,2) || error("logical slot $(slotid) has $(length(inds)) attempts")
        original = filter(i -> attempts[i].attempt_kind == "original", inds)
        retries = filter(i -> attempts[i].attempt_kind == "retry1", inds)
        length(original) == 1 && length(retries) <= 1 || error("ambiguous slot attempt candidates: $slotid")
        a = attempts[only(original)]
        if !isempty(retries)
            a.classification == "infrastructure" || error("retry exists without infrastructure original: $slotid")
        end
        if a.classification != "infrastructure"
            isempty(retries) || error("registered retry after terminal original: $slotid")
            selected = a
        elseif isempty(retries)
            error("infrastructure original missing registered retry1: $slotid")
        else
            b = attempts[only(retries)]
            selected = b
        end
        terminal = selected.classification == "infrastructure"
        push!(slots_out, (slot_id=slotid, protocol_id=PROTOCOL,
            condition_id=String(pslot.condition_id), world_seed=Int(pslot.world_seed),
            policy=String(pslot.policy), repetition_id=String(pslot.repetition_id),
            original_run_id=a.run_id, retry1_run_id=isempty(retries) ? nothing : attempts[only(retries)].run_id,
            selected_run_id=selected.run_id, selected_attempt=selected.attempt_kind,
            resolution=terminal ? "terminal_infrastructure" : selected.classification,
            terminal_infrastructure=terminal, parameter_error=terminal ? nothing : selected.parameter_error,
            prediction_error=terminal ? nothing : selected.prediction_error,
            parameter_success=terminal ? nothing : selected.parameter_success,
            interventions_used=terminal ? nothing : selected.interventions_used,
            decision_opportunities_used=terminal ? nothing : selected.decision_opportunities_used,
            invalid_action_count=terminal ? nothing : selected.invalid_action_count,
            terminal_failure_code=selected.terminal_failure_code))
    end
    length(slots_out) == 120 || error("logical resolution not complete")
    for rs in slots_out
        ss=state_by_slot[rs.slot_id]
        expected_status=rs.resolution=="terminal_infrastructure" ? "terminal_infrastructure" : rs.resolution
        ss.status==expected_status || error("execution state/ledger resolution disagreement for $(rs.slot_id)")
        Set(String.(ss.run_ids))==Set(a.run_id for a in attempts if a.slot_id==rs.slot_id) ||
            error("execution state attempt ID mismatch for $(rs.slot_id)")
    end
    (attempts=attempts, slots=slots_out, plan=plan, ledger=ledger, scores=scores,
        planpath=planpath, statepath=statepath, ledgerpath=ledgerpath, journalpath=journalpath)
end

function paired_bootstrap(differences; resamples=BOOTSTRAPS, seed=BOOTSTRAP_SEED)
    resamples == 10_000 || error("locked bootstrap resample count changed")
    seed == 9_123_999 || error("locked bootstrap seed changed")
    n = length(differences)
    n > 0 || error("cannot bootstrap empty matched population")
    point = sum(differences) / n
    rng = MersenneTwister(seed)
    estimates = Vector{Float64}(undef, resamples)
    for b in 1:resamples
        ix = rand(rng, 1:n, n)
        estimates[b] = sum(@view differences[ix]) / n
    end
    sort!(estimates)
    q(v) = begin
        h = (resamples - 1) * v + 1
        lo, hi = floor(Int, h), ceil(Int, h)
        estimates[lo] + (h-lo) * (estimates[hi]-estimates[lo])
    end
    (mean_difference=point, ci_low=q(0.025), ci_high=q(0.975),
        resamples=resamples, seed=seed, n_worlds=n)
end

mean0(xs) = isempty(xs) ? missing : sum(xs)/length(xs)
function describe(xs)
    ys=sort(Float64.(xs)); isempty(ys) && return (n=0, mean=missing, median=missing, q25=missing, q75=missing, min=missing, max=missing)
    quant(p) = begin h=(length(ys)-1)*p+1; lo=floor(Int,h); hi=ceil(Int,h); ys[lo]+(h-lo)*(ys[hi]-ys[lo]) end
    (n=length(ys), mean=mean0(ys), median=quant(.5), q25=quant(.25), q75=quant(.75), min=first(ys), max=last(ys))
end

function paired(kept, baseline, endpoint, hypothesis)
    diffs = Float64[]; svals=Float64[]; bvals=Float64[]; worlds=Int[]
    for w in kept
        s=only(filter(x->x.policy=="scientist", w.rows))
        b=only(filter(x->x.policy==baseline,w.rows))
        sv=Float64(getproperty(s, endpoint)); bv=Float64(getproperty(b, endpoint))
        push!(svals,sv); push!(bvals,bv); push!(diffs,sv-bv); push!(worlds,w.world_seed)
    end
    ci=paired_bootstrap(diffs)
    (hypothesis=hypothesis, baseline=baseline, endpoint=String(endpoint), n_worlds=length(worlds),
        scientist_mean=mean0(svals), baseline_mean=mean0(bvals), mean_paired_difference=ci.mean_difference,
        ci_low=ci.ci_low, ci_high=ci.ci_high, superiority=ci.ci_high < 0,
        bootstrap_resamples=ci.resamples, bootstrap_seed=ci.seed)
end

function xml(s) replace(string(s), "&"=>"&amp;", "<"=>"&lt;", ">"=>"&gt;", "\""=>"&quot;") end
function svgwrite(path, title, body; width=900, height=560)
    open(path,"w") do io
        println(io,"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$width\" height=\"$height\" viewBox=\"0 0 $width $height\">")
        println(io,"<rect width=\"100%\" height=\"100%\" fill=\"white\"/><style>text{font-family:Arial,sans-serif;fill:#222}.title{font-size:22px;font-weight:bold}.axis{stroke:#444;stroke-width:1}.grid{stroke:#ddd;stroke-width:1}.label{font-size:13px}.small{font-size:11px}</style>")
        println(io,"<text x=\"$(width/2)\" y=\"30\" text-anchor=\"middle\" class=\"title\">$(xml(title))</text>")
        println(io,body,"</svg>")
    end
end

function point_svg(path, title, rows, endpoint; condition="gaussian_0.10")
    policies=("random","fixed_design","scientist"); colors=("#4575b4","#d73027","#1a9850")
    eligible(r) = (!hasproperty(r,:resolution) || r.resolution != "terminal_infrastructure") &&
        (condition != "gaussian_0.10" || !hasproperty(r,:paired_population) || r.paired_population)
    value(r) = getproperty(r,endpoint)
    vals=[Float64(value(r)) for r in rows if r.condition_id==condition && eligible(r) && value(r)!==nothing]
    lo=min(0.0,minimum(vals)); hi=maximum(vals)*1.08; hi<=lo && (hi=lo+1)
    x0,y0,w,h=90,70,740,390
    body=IOBuffer(); println(body,"<line class=\"axis\" x1=\"$x0\" y1=\"$(y0+h)\" x2=\"$(x0+w)\" y2=\"$(y0+h)\"/><line class=\"axis\" x1=\"$x0\" y1=\"$y0\" x2=\"$x0\" y2=\"$(y0+h)\"/>")
    for i in 0:4
        y=y0+h-i*h/4; v=lo+i*(hi-lo)/4
        println(body,"<line class=\"grid\" x1=\"$x0\" y1=\"$y\" x2=\"$(x0+w)\" y2=\"$y\"/><text class=\"small\" x=\"$(x0-10)\" y=\"$(y+4)\" text-anchor=\"end\">$(round(v,digits=3))</text>")
    end
    for (i,p) in enumerate(policies)
        x=x0+(i-.5)*w/3; set=Float64[value(r) for r in rows if r.condition_id==condition && r.policy==p && eligible(r) && value(r)!==nothing]
        sort!(set); d=describe(set); q1=d.q25; q3=d.q75; med=d.median
        sy(v)=y0+h-(v-lo)/(hi-lo)*h
        println(body,"<line stroke=\"$(colors[i])\" stroke-width=\"3\" x1=\"$x\" y1=\"$(sy(q1))\" x2=\"$x\" y2=\"$(sy(q3))\"/><line stroke=\"$(colors[i])\" stroke-width=\"7\" x1=\"$(x-18)\" y1=\"$(sy(med))\" x2=\"$(x+18)\" y2=\"$(sy(med))\"/>")
        for (j,v) in enumerate(set)
            xx=x+(((j*37)%17)-8)*1.5
            println(body,"<circle cx=\"$xx\" cy=\"$(sy(v))\" r=\"3\" fill=\"$(colors[i])\" fill-opacity=\".5\"/>")
        end
        println(body,"<text class=\"label\" x=\"$x\" y=\"$(y0+h+24)\" text-anchor=\"middle\">$(p) (n=$(length(set)))</text>")
    end
    println(body,"<text class=\"label\" transform=\"translate(22 $(y0+h/2)) rotate(-90)\" text-anchor=\"middle\">$(endpoint)</text>")
    svgwrite(path,title,String(take!(body)))
end

function effects_svg(path, results)
    body=IOBuffer(); x0,y0,w,h=300,85,510,400
    effects=results
    xmin=minimum(r.ci_low for r in effects); xmax=maximum(r.ci_high for r in effects); span=max(xmax-xmin,1e-6); xmin-=span*.08; xmax+=span*.08
    xx(v)=x0+(v-xmin)/(xmax-xmin)*w
    println(body,"<line class=\"axis\" x1=\"$(xx(0))\" y1=\"$y0\" x2=\"$(xx(0))\" y2=\"$(y0+h)\"/>")
    for i in eachindex(effects)
        r=effects[i]; y=y0+(i-.5)*h/length(effects)
        println(body,"<text class=\"label\" x=\"$(x0-15)\" y=\"$(y+4)\" text-anchor=\"end\">$(r.hypothesis) $(r.endpoint)</text>")
        println(body,"<line stroke=\"#34495e\" stroke-width=\"3\" x1=\"$(xx(r.ci_low))\" y1=\"$y\" x2=\"$(xx(r.ci_high))\" y2=\"$y\"/><circle cx=\"$(xx(r.mean_paired_difference))\" cy=\"$y\" r=\"6\" fill=\"#e67e22\"/><text class=\"small\" x=\"$(x0+w+10)\" y=\"$(y+4)\">N=$(r.n_worlds)</text>")
    end
    println(body,"<text class=\"label\" x=\"$(x0+w/2)\" y=\"$(y0+h+35)\" text-anchor=\"middle\">Scientist − baseline (negative favors Scientist)</text>")
    svgwrite(path,"Paired endpoint differences with 95% world-bootstrap intervals",String(take!(body)))
end

function bars_svg(path,title,labels,values; colors=nothing)
    colors===nothing && (colors=fill("#4575b4",length(values)))
    maxv=max(maximum(Float64.(values);init=1),1e-12); x0,y0,w,h=150,75,690,390
    body=IOBuffer(); println(body,"<line class=\"axis\" x1=\"$x0\" y1=\"$(y0+h)\" x2=\"$(x0+w)\" y2=\"$(y0+h)\"/>")
    step=h/length(values)
    for i in eachindex(values)
        yy=y0+(i-1)*step+step*.2; bw=w*Float64(values[i])/maxv
        println(body,"<text class=\"label\" x=\"$(x0-10)\" y=\"$(yy+step*.45)\" text-anchor=\"end\">$(xml(labels[i]))</text><rect x=\"$x0\" y=\"$yy\" width=\"$bw\" height=\"$(step*.55)\" fill=\"$(colors[i])\"/><text class=\"small\" x=\"$(x0+bw+6)\" y=\"$(yy+step*.45)\">$(round(values[i],digits=3))</text>")
    end
    svgwrite(path,title,String(take!(body)))
end

function clean_noise_svg(path, rows, endpoint="parameter_error")
    body=IOBuffer(); x0,y0,w,h=145,75,680,380
    policies=("random","fixed_design","scientist"); colors=("#4575b4","#d73027","#1a9850")
    vals=Float64[r.mean for r in rows if r.endpoint==endpoint && r.mean!==missing]
    maxv=max(maximum(vals;init=0.01)*1.15,0.01)
    println(body,"<line class=\"axis\" x1=\"$x0\" y1=\"$(y0+h)\" x2=\"$(x0+w)\" y2=\"$(y0+h)\"/><line class=\"axis\" x1=\"$x0\" y1=\"$y0\" x2=\"$x0\" y2=\"$(y0+h)\"/>")
    for i in 0:4
        y=y0+h-i*h/4; v=maxv*i/4
        println(body,"<line class=\"grid\" x1=\"$x0\" y1=\"$y\" x2=\"$(x0+w)\" y2=\"$y\"/><text class=\"small\" x=\"$(x0-8)\" y=\"$(y+4)\" text-anchor=\"end\">$(round(v,digits=3))</text>")
    end
    for (i,p) in enumerate(policies)
        for (j,c) in enumerate(("clean","gaussian_0.10"))
            row=only(filter(r->r.policy==p&&r.condition_id==c&&r.endpoint==endpoint,rows))
            x=x0+(i-1)*w/3+w/6+(j==1 ? -14 : 14)
            if p=="scientist" && c=="clean"
                println(body,"<text class=\"small\" x=\"$x\" y=\"$(y0+h-12)\" text-anchor=\"middle\">n=3; no usable sample</text>")
                continue
            end
            barh=Float64(row.mean)/maxv*h
            println(body,"<rect x=\"$(x-9)\" y=\"$(y0+h-barh)\" width=\"18\" height=\"$barh\" fill=\"$(colors[i])\" fill-opacity=\"$(j==1 ? ".5" : ".95")\"/><text class=\"small\" x=\"$x\" y=\"$(y0+h-barh-5)\" text-anchor=\"middle\">$(round(row.mean,digits=3))</text>")
        end
        x=x0+(i-.5)*w/3
        println(body,"<text class=\"label\" x=\"$x\" y=\"$(y0+h+24)\" text-anchor=\"middle\">$(p)</text>")
    end
    println(body,"<text class=\"small\" x=\"$(x0+w-5)\" y=\"50\" text-anchor=\"end\">pale = clean; solid = gaussian_0.10</text><text class=\"label\" transform=\"translate(25 $(y0+h/2)) rotate(-90)\" text-anchor=\"middle\">Mean $(endpoint)</text>")
    svgwrite(path,"Clean vs Gaussian descriptive $(endpoint)",String(take!(body)))
end

function efficiency_svg(path, rows)
    body=IOBuffer(); policies=("random","fixed_design","scientist"); colors=("#4575b4","#d73027","#1a9850")
    xleft=80; ytop=75; panelw=350; panelh=350; gap=90
    eligible=filter(r->r.condition_id=="gaussian_0.10"&&r.parameter_error!==nothing,rows)
    ymin=0.0; ymax=max(maximum(Float64(r.parameter_error) for r in eligible)*1.08,.01)
    for (panel,field,title) in ((1,:interventions_used,"Valid interventions consumed"),(2,:decision_opportunities_used,"Decision opportunities consumed"))
        x0=xleft+(panel-1)*(panelw+gap); maxx=max(maximum(Int(getproperty(r,field)) for r in eligible),1)
        println(body,"<line class=\"axis\" x1=\"$x0\" y1=\"$(ytop+panelh)\" x2=\"$(x0+panelw)\" y2=\"$(ytop+panelh)\"/><line class=\"axis\" x1=\"$x0\" y1=\"$ytop\" x2=\"$x0\" y2=\"$(ytop+panelh)\"/><text class=\"label\" x=\"$(x0+panelw/2)\" y=\"50\" text-anchor=\"middle\">$(title)</text>")
        for i in 0:4
            y=ytop+panelh-i*panelh/4; v=ymax*i/4
            println(body,"<line class=\"grid\" x1=\"$x0\" y1=\"$y\" x2=\"$(x0+panelw)\" y2=\"$y\"/><text class=\"small\" x=\"$(x0-6)\" y=\"$(y+4)\" text-anchor=\"end\">$(round(v,digits=2))</text>")
        end
        for (i,p) in enumerate(policies),r in eligible
            r.policy==p || continue
            xx=x0+Int(getproperty(r,field))/maxx*panelw
            yy=ytop+panelh-Float64(r.parameter_error)/ymax*panelh
            radius=2.5+min(Int(r.invalid_action_count),4)
            fillcolor=r.policy_failure_count>0 ? "#000000" : colors[i]
            println(body,"<circle cx=\"$xx\" cy=\"$yy\" r=\"$radius\" fill=\"$(fillcolor)\" fill-opacity=\".65\"/>")
        end
        println(body,"<text class=\"label\" x=\"$(x0+panelw/2)\" y=\"$(ytop+panelh+28)\" text-anchor=\"middle\">$(title)</text>")
    end
    println(body,"<text class=\"label\" transform=\"translate(22 $(ytop+panelh/2)) rotate(-90)\" text-anchor=\"middle\">Final parameter error (marker size: invalid actions; black: policy failure)</text>")
    svgwrite(path,"Exploratory final error vs consumed budget (gaussian_0.10)",String(take!(body));width=920)
end

function operation_totals(root, ledger)
    requests=0; input=0; output=0; cost=0.0; latency=0.0
    missing=Dict("input_tokens"=>0,"output_tokens"=>0,"cost"=>0,"latency_s"=>0)
    bypolicy=Dict{String,Dict{String,Float64}}(); missing_by_policy=Dict{String,Dict{String,Int}}()
    for l in ledger
        l.artifact_dir===nothing && continue
        d=joinpath(root,"results","raw",String(l.run_id))
        pub=readj(joinpath(d,"public.json")); p=String(pub.policy_identity.name)
        a=get!(bypolicy,p,Dict("requests"=>0.0,"input_tokens"=>0.0,"output_tokens"=>0.0,"cost"=>0.0,"latency_s"=>0.0))
        mcount=get!(missing_by_policy,p,Dict("input_tokens"=>0,"output_tokens"=>0,"cost"=>0,"latency_s"=>0))
        for e in pub.events
            e.operational_metadata===nothing && continue
            m=e.operational_metadata; requests+=1; a["requests"]+=1
            for (f,key) in ((:input_tokens,"input_tokens"),(:output_tokens,"output_tokens"),(:cost,"cost"),(:latency_s,"latency_s"))
                v=getproperty(m,f)
                if v===nothing
                    missing[key]+=1
                    mcount[key]+=1
                else
                    f==:input_tokens ? (input+=Int(v)) : f==:output_tokens ? (output+=Int(v)) : f==:cost ? (cost+=Float64(v)) : (latency+=Float64(v))
                    a[key]+=Float64(v)
                end
            end
        end
    end
    actual=(requests=requests,input_tokens=input,output_tokens=output,cost=cost,latency=latency)
    requests==OP_EXPECTED.requests && input==OP_EXPECTED.input_tokens && output==OP_EXPECTED.output_tokens || error("provider request/token totals fail execution cross-check: $actual")
    isapprox(cost,OP_EXPECTED.cost;atol=1e-12,rtol=1e-12) && isapprox(latency,OP_EXPECTED.latency;atol=1e-9,rtol=1e-12) || error("provider cost/latency totals fail execution cross-check: $actual")
    (actual=actual, missing=missing, bypolicy=bypolicy, missing_by_policy=missing_by_policy)
end

function analyze(root=normpath(joinpath(@__DIR__,"..")))
    VERSION==v"1.12.7" || error("Julia 1.12.7 required")
    resolution=resolve_attempts(root)
    ep=validate_provenance(root,resolution.planpath,resolution.ledgerpath)
    ops=operation_totals(root,resolution.ledger)

    terminal=filter(s->s.terminal_infrastructure,resolution.slots)
    worlds=sort(unique(s.world_seed for s in resolution.slots if s.condition_id=="gaussian_0.10"))
    primary=NamedTuple[]; excluded=NamedTuple[]
    for world in worlds
        block=filter(s->s.condition_id=="gaussian_0.10"&&s.world_seed==world,resolution.slots)
        length(block)==3 && Set(s.policy for s in block)==Set(PRIMARY_POLICIES) || error("primary matched block malformed: $world")
        bad=filter(s->s.terminal_infrastructure,block)
        if isempty(bad)
            push!(primary,(world_seed=world,retained=true,exclusion_reason="",excluded_policy="",rows=block))
        else
            for b in bad
                push!(excluded,(world_seed=world,excluded_policy=b.policy,reason="terminal_infrastructure_after_retry",selected_run_id=b.selected_run_id))
            end
        end
    end
    excluded_worlds=Set(x.world_seed for x in excluded)
    kept=filter(w->w.retained,primary)
    length(kept)+length(excluded_worlds)==30 || error("primary world accounting failed")
    # Rebuild kept block records with endpoint scores in common row shape.
    kept_blocks=[(world_seed=w.world_seed, rows=[(policy=s.policy,parameter_error=s.parameter_error,
        prediction_error=s.prediction_error,parameter_success=s.parameter_success) for s in w.rows]) for w in kept]

    effects=[paired(kept_blocks,b,e,h) for (b,e,h) in (
        ("random",:parameter_error,"H1"),("random",:prediction_error,"H1"),
        ("fixed_design",:parameter_error,"H2"),("fixed_design",:prediction_error,"H2"))]
    h1=hypothesis_supported(effects,"H1")
    h2=hypothesis_supported(effects,"H2")

    # All resolved non-infrastructure logical runs are descriptive policy distributions.
    runmetrics=[(condition_id=s.condition_id,world_seed=s.world_seed,policy=s.policy,
        run_id=s.selected_run_id,parameter_error=s.parameter_error,prediction_error=s.prediction_error,
        parameter_success=s.parameter_success,interventions_used=s.interventions_used,
        decision_opportunities_used=s.decision_opportunities_used,invalid_action_count=s.invalid_action_count,
        policy_failure_count=s.terminal_failure_code===nothing ? 0 : 1,
        resolution=s.resolution,paired_population=s.condition_id=="gaussian_0.10" && !(s.world_seed in excluded_worlds))
        for s in resolution.slots if !s.terminal_infrastructure]

    primary_rows=NamedTuple[]
    for c in ("gaussian_0.10","clean"), p in PRIMARY_POLICIES
        vals=filter(r->r.condition_id==c && r.policy==p,runmetrics)
        for (endpoint,field) in (("parameter_error",:parameter_error),("prediction_error",:prediction_error))
            d=describe([getproperty(r,field) for r in vals])
            push!(primary_rows,(condition_id=c,policy=p,endpoint=endpoint,n=d.n,mean=d.mean,median=d.median,
                q25=d.q25,q75=d.q75,min=d.min,max=d.max,paired_primary_population=c=="gaussian_0.10" ? count(r->r.paired_population,vals) : missing))
        end
    end
    paired_rows=NamedTuple[]
    for w in kept_blocks
        for base in ("random","fixed_design")
            s=only(filter(x->x.policy=="scientist",w.rows)); b=only(filter(x->x.policy==base,w.rows))
            push!(paired_rows,(world_seed=w.world_seed,baseline=base,scientist_run_id=only(filter(x->x.condition_id=="gaussian_0.10"&&x.world_seed==w.world_seed&&x.policy=="scientist",resolution.slots)).selected_run_id,
                parameter_difference=s.parameter_error-b.parameter_error,prediction_difference=s.prediction_error-b.prediction_error))
        end
    end
    worldrows=[(world_seed=w.world_seed,retained=true,exclusion_reason="",excluded_policies="") for w in kept]
    for world in sort(collect(excluded_worlds))
        bad=filter(x->x.world_seed==world,excluded)
        push!(worldrows,(world_seed=world,retained=false,exclusion_reason="terminal_infrastructure_after_retry",
            excluded_policies=join(sort(unique(x.excluded_policy for x in bad)),"|")))
    end
    sort!(worldrows,by=x->x.world_seed)

    failure_rows=NamedTuple[]
    for c in ("gaussian_0.10","clean"), p in PRIMARY_POLICIES
        slotset=filter(s->s.condition_id==c && s.policy==p,resolution.slots)
        ats=filter(a->a.condition_id==c && a.policy==p,resolution.attempts)
        selected=[s for s in slotset if !s.terminal_infrastructure]
        push!(failure_rows,(condition_id=c,policy=p,logical_slots=length(slotset),completed_runs=count(s->s.resolution=="completed",slotset),
            behavioral_failures=count(s->s.resolution=="behavioral_failure",slotset),infrastructure_first_attempts=count(a->a.attempt_kind=="original"&&a.classification=="infrastructure",ats),
            recovered_infrastructure_retries=count(a->a.attempt_kind=="retry1"&&a.classification!="infrastructure",ats),
            terminal_infrastructure_slots=count(s->s.terminal_infrastructure,slotset),invalid_action_count=sum(s.invalid_action_count for s in selected),
            decision_opportunities=sum(s.decision_opportunities_used for s in selected),valid_interventions=sum(s.interventions_used for s in selected),
            all_attempt_decision_opportunities=sum(a.decision_opportunities_used for a in ats),
            all_attempt_invalid_actions=sum(a.invalid_action_count for a in ats)))
    end
    # Global failure counts include attempts regardless of their final retry role.
    operational_rows=NamedTuple[]
    for p in PRIMARY_POLICIES
        a=get(ops.bypolicy,p,Dict{String,Float64}())
        policyrows=filter(r->r.policy==p,runmetrics)
        logical_scientists=count(s->s.policy=="scientist",resolution.slots)
        push!(operational_rows,(policy=p,requests=get(a,"requests",0.0),input_tokens=get(a,"input_tokens",0.0),
            output_tokens=get(a,"output_tokens",0.0),cost_usd=get(a,"cost",0.0),latency_seconds=get(a,"latency_s",0.0),
            requests_per_run=count(x->x.policy==p,resolution.attempts)==0 ? missing : get(a,"requests",0.0)/count(x->x.policy==p,resolution.attempts),
            cost_per_scientist_logical_run=p=="scientist" ? get(a,"cost",0.0)/logical_scientists : missing,
            latency_per_scientist_logical_run=p=="scientist" ? get(a,"latency_s",0.0)/logical_scientists : missing,
            attempts=count(a->a.policy==p,resolution.attempts),behavioral_failures=count(a->a.policy==p&&a.classification=="behavioral_failure",resolution.attempts),
            infrastructure_attempts=count(a->a.policy==p&&a.classification=="infrastructure",resolution.attempts)))
    end

    policy_descriptive=NamedTuple[]
    for c in ("gaussian_0.10","clean"),p in PRIMARY_POLICIES, (endpoint,field) in (("parameter_error",:parameter_error),("prediction_error",:prediction_error))
        vals=[Float64(getproperty(r,field)) for r in runmetrics if r.condition_id==c&&r.policy==p&&getproperty(r,field)!==nothing]
        d=describe(vals)
        push!(policy_descriptive,(condition_id=c,policy=p,endpoint=endpoint,n=d.n,mean=d.mean,median=d.median,q25=d.q25,q75=d.q75,min=d.min,max=d.max))
    end
    clean_compare=NamedTuple[]
    for p in PRIMARY_POLICIES, (endpoint,field) in (("parameter_error",:parameter_error),("prediction_error",:prediction_error))
        cleanv=[Float64(getproperty(r,field)) for r in runmetrics if r.condition_id=="clean"&&r.policy==p&&getproperty(r,field)!==nothing]
        noisey=[Float64(getproperty(r,field)) for r in runmetrics if r.condition_id=="gaussian_0.10"&&r.policy==p&&getproperty(r,field)!==nothing]
        dc,dn=describe(cleanv),describe(noisey)
        push!(clean_compare,(policy=p,endpoint=endpoint,clean_n=dc.n,clean_mean=dc.mean,clean_median=dc.median,
            gaussian_n=dn.n,gaussian_mean=dn.mean,gaussian_median=dn.median))
    end
    success_rows=NamedTuple[]
    for c in ("gaussian_0.10","clean"),p in PRIMARY_POLICIES
        rs=[r for r in runmetrics if r.condition_id==c&&r.policy==p]
        nsuccess=count(r->r.parameter_success===true,rs)
        push!(success_rows,(condition_id=c,policy=p,n_scored=length(rs),success_threshold=0.10,
            successes=nsuccess,success_rate=isempty(rs) ? missing : nsuccess/length(rs)))
    end
    behavioral_worlds=[(condition_id=s.condition_id,world_seed=s.world_seed,policy=s.policy,
        run_id=s.selected_run_id,parameter_error=s.parameter_error,prediction_error=s.prediction_error,
        retained_primary=s.condition_id=="gaussian_0.10"&&!(s.world_seed in excluded_worlds))
        for s in resolution.slots if s.resolution=="behavioral_failure"]

    out=joinpath(root,OUT); mkpath(out); figs=joinpath(out,"figures"); mkpath(figs)
    csvwrite(joinpath(out,"attempts.csv"),resolution.attempts,fieldnames(typeof(first(resolution.attempts)))|>x->String.(x))
    csvwrite(joinpath(out,"logical_slots.csv"),resolution.slots,String.(fieldnames(typeof(first(resolution.slots)))))
    csvwrite(joinpath(out,"terminal_infrastructure.csv"),filter(s->s.terminal_infrastructure,resolution.slots),
        String.(fieldnames(typeof(first(filter(s->s.terminal_infrastructure,resolution.slots))))))
    csvwrite(joinpath(out,"primary_worlds.csv"),worldrows,String.(fieldnames(typeof(first(worldrows)))))
    csvwrite(joinpath(out,"run_metrics.csv"),runmetrics,String.(fieldnames(typeof(first(runmetrics)))))
    csvwrite(joinpath(out,"paired_differences.csv"),paired_rows,String.(fieldnames(typeof(first(paired_rows)))))
    csvwrite(joinpath(out,"bootstrap_summary.csv"),effects,String.(fieldnames(typeof(first(effects)))))
    csvwrite(joinpath(out,"failure_summary.csv"),failure_rows,String.(fieldnames(typeof(first(failure_rows)))))
    csvwrite(joinpath(out,"operational_summary.csv"),operational_rows,String.(fieldnames(typeof(first(operational_rows)))))
    missing_rows=[(policy=p,input_tokens=get(get(ops.missing_by_policy,p,Dict{String,Int}()),"input_tokens",0),
        output_tokens=get(get(ops.missing_by_policy,p,Dict{String,Int}()),"output_tokens",0),
        cost=get(get(ops.missing_by_policy,p,Dict{String,Int}()),"cost",0),
        latency_s=get(get(ops.missing_by_policy,p,Dict{String,Int}()),"latency_s",0)) for p in PRIMARY_POLICIES]
    csvwrite(joinpath(out,"operational_metadata_missing.csv"),missing_rows,String.(fieldnames(typeof(first(missing_rows)))))
    csvwrite(joinpath(out,"policy_descriptive.csv"),policy_descriptive,String.(fieldnames(typeof(first(policy_descriptive)))))
    csvwrite(joinpath(out,"clean_noisy_descriptive.csv"),clean_compare,String.(fieldnames(typeof(first(clean_compare)))))
    csvwrite(joinpath(out,"success_summary.csv"),success_rows,String.(fieldnames(typeof(first(success_rows)))))
    csvwrite(joinpath(out,"behavioral_failure_worlds.csv"),behavioral_worlds,String.(fieldnames(typeof(first(behavioral_worlds)))))
    jsonlwrite(joinpath(out,"attempts.jsonl"),resolution.attempts)
    jsonlwrite(joinpath(out,"logical_slots.jsonl"),resolution.slots)
    jsonwrite(joinpath(out,"primary_results.json"),(protocol_id=PROTOCOL, bootstrap_seed=BOOTSTRAP_SEED,
        bootstrap_resamples=BOOTSTRAPS, primary_worlds_retained=length(kept), primary_worlds_excluded=sort(collect(excluded_worlds)),
        excluded_slot_causes=excluded, results=effects, H1=h1 ? "supported" : "not supported", H2=h2 ? "supported" : "not supported"))

    evaluator_rows=readlines_json(joinpath(root,SCORES,"run_scores.jsonl"))
    point_svg(joinpath(figs,"final-error-distributions.svg"),"Final parameter error by policy — gaussian_0.10 retained paired worlds",runmetrics,:parameter_error)
    # Create a paired distribution plot for prediction endpoint as a separate panel file.
    point_svg(joinpath(figs,"prediction-error-distributions.svg"),"Held-out prediction error — gaussian_0.10 retained paired worlds",runmetrics,:prediction_error)
    effects_svg(joinpath(figs,"primary-paired-endpoints.svg"),effects)
    clean_noise_svg(joinpath(figs,"clean-vs-noisy.svg"),policy_descriptive)
    clean_noise_svg(joinpath(figs,"clean-vs-noisy-prediction.svg"),policy_descriptive,"prediction_error")
    # Compact failure plot including the separated behavioral/infrastructure categories.
    flabels=String[]; fvals=Float64[]; fcolors=String[]
    for r in failure_rows
        append!(flabels,["$(r.condition_id) $(r.policy) behavioral","$(r.condition_id) $(r.policy) recovered infra","$(r.condition_id) $(r.policy) terminal infra"])
        append!(fvals,[r.behavioral_failures,r.recovered_infrastructure_retries,r.terminal_infrastructure_slots])
        append!(fcolors,["#d73027","#91cf60","#542788"])
    end
    bars_svg(joinpath(figs,"failure-retry-summary.svg"),"Behavioral failures vs infrastructure retries",flabels,fvals;colors=fcolors)
    bars_svg(joinpath(figs,"scientist-cost-latency.svg"),"Scientist operational totals (cost USD, latency seconds)",
        ["recorded cost USD","recorded latency seconds / 1000","provider requests / 100"],
        [ops.actual.cost,ops.actual.latency/1000,ops.actual.requests/100];colors=["#1a9850","#4575b4","#d73027"])
    valid_scientist=[r for r in runmetrics if r.policy=="scientist"]
    efficiency_svg(joinpath(figs,"intervention-use.svg"),runmetrics)

    analysis_commit=try
        strip(read(`git -C $root rev-parse HEAD`,String))
    catch
        strip(read(`jj -R $root log -r @ --no-graph -T commit_id`,String))
    end
    metadata=(protocol_id=PROTOCOL, execution_commit=String(resolution.plan.commit),
        analysis_commit=analysis_commit,
        analysis_source_sha256=filehash(joinpath(root,"scripts","analyze_confirmatory_v0_1.jl")),
        julia_version=string(VERSION),
        manifest_sha256=filehash(joinpath(root,"Manifest.toml")), execution_plan_sha256=filehash(resolution.planpath),
        execution_state_sha256=filehash(resolution.statepath),ledger_sha256=filehash(resolution.ledgerpath),
        journal_sha256=filehash(resolution.journalpath),evaluator_materialization_provenance_sha256=filehash(joinpath(root,SCORES,"evaluation-provenance.json")),
        bootstrap_seed=BOOTSTRAP_SEED,bootstrap_resamples=BOOTSTRAPS,analysis_timestamp_utc=string(Dates.now(Dates.UTC)))
    jsonwrite(joinpath(out,"analysis-provenance.json"),metadata)
    write_findings(root, kept, excluded, effects, h1, h2, failure_rows, ops, policy_descriptive,clean_compare,worldrows,success_rows,terminal,behavioral_worlds)
    println("primary matched worlds retained: $(length(kept)); excluded: $(length(excluded_worlds))")
    println("H1: $(h1 ? "supported" : "not supported"); H2: $(h2 ? "supported" : "not supported")")
    println("analysis outputs: $out")
    (out=out,kept=kept,excluded=excluded,effects=effects,H1=h1,H2=h2,operations=ops,failures=failure_rows)
end

function write_findings(root,kept,excluded,effects,h1,h2,failures,ops,descriptive,cleancompare,worlds,success,terminal,behavioral_worlds)
    path=joinpath(root,"research","findings-v0.1.md")
    open(path,"w") do io
        println(io,"""# Falsify V0.1 Confirmatory Findings

## Protocol

Executed protocol: `falsify-v0.1-prereg-4`. H1/H2 use gaussian_0.10 only; clean is descriptive apparatus validation. Endpoints are the persisted frozen evaluator scores. Paired-world bootstrap: 10,000 resamples, seed 9123999, percentile two-sided 95% intervals.

## Execution integrity

Attempt-level population reconciles to 140 attempts: 109 scientifically scored, 4 behavioral failures, and 31 infrastructure-unscored attempts. Retries were resolved only after retaining all attempt rows. No experiment/provider was invoked by this analysis.

## Analysis population

Primary preregistered worlds: 30. Retained matched blocks: $(length(kept)). Excluded blocks: $(length(unique(x.world_seed for x in excluded))). Infrastructure-triggering slot(s):
""")
        if isempty(excluded)
            println(io,"None.")
        else
            for w in sort(unique(x.world_seed for x in excluded))
                xs=filter(x->x.world_seed==w,excluded)
                println(io,"- World `$(w)`: `$(join(sort(unique(x.excluded_policy for x in xs)), ", "))` terminal infrastructure after retry.")
            end
        end
        println(io,"\nAll terminal infrastructure slots (including clean descriptive slots):\n")
        for s in sort(terminal,by=x->(x.condition_id,x.world_seed,x.policy))
            println(io,"- `$(s.condition_id)` world `$(s.world_seed)`, `$(s.policy)`: retry1 `$(s.selected_run_id)` remained infrastructure.")
        end
        println(io,"\n## H1: Scientist vs Random\n")
        write_effects(io,filter(x->x.hypothesis=="H1",effects),h1)
        println(io,"\n## H2: Scientist vs Fixed Design\n")
        write_effects(io,filter(x->x.hypothesis=="H2",effects),h2)
        println(io,"\n## gaussian_0.10 policy performance (descriptive)\n\nThese are logical-slot distributions; Scientist is n=$(length(kept)), the paired analysis population. Baseline descriptives include all observed slots; the confirmatory contrasts use only the retained matched blocks.\n\n| Policy | Endpoint | N | Mean | Median | Q25 | Q75 |\n|---|---|---:|---:|---:|---:|---:|")
        for r in filter(x->x.condition_id=="gaussian_0.10",descriptive)
            println(io,"| $(r.policy) | $(r.endpoint) | $(r.n) | $(r.mean) | $(r.median) | $(r.q25) | $(r.q75) |")
        end
        println(io,"\nSuccess threshold is `parameter_error ≤ 0.10`; counts are descriptive in `success_summary.csv`.\n")
        println(io,"\n## Clean descriptive condition\n\nClean results are descriptive only and do not enter H1/H2. ScientistPolicy had zero successful completions: 7/10 slots ended in terminal infrastructure failure, and the remaining 3 were behavioral failures scored 1.0. Thus the reported clean ScientistPolicy mean is three behavioral penalty scores, not a usable clean-observation performance sample; it must not be interpreted as evidence that clean observations worsen performance.\n\n| Policy | Endpoint | N | Mean | Median |\n|---|---|---:|---:|---:|")
        for r in filter(x->x.condition_id=="clean",descriptive)
            println(io,"| $(r.policy) | $(r.endpoint) | $(r.n) | $(r.mean) | $(r.median) |")
        end
        println(io,"\nSuccess at parameter_error ≤ 0.10:\n\n| Condition | Policy | N scored | Successes | Rate |\n|---|---|---:|---:|---:|")
        for r in success
            println(io,"| $(r.condition_id) | $(r.policy) | $(r.n_scored) | $(r.successes) | $(r.success_rate) |")
        end
        println(io,"\nClean-vs-noisy means are also in `clean_noisy_descriptive.csv`. These remain descriptive; clean results do not enter H1/H2.\n")
        println(io,"\n## Behavioral and infrastructure failures\n\n", "| Condition | Policy | Completed | Behavioral | First infra | Recovered retry | Terminal infra | Invalid actions | Decision opportunities |\n|---|---|---:|---:|---:|---:|---:|---:|---:|")
        for r in failures
            println(io,"| $(r.condition_id) | $(r.policy) | $(r.completed_runs) | $(r.behavioral_failures) | $(r.infrastructure_first_attempts) | $(r.recovered_infrastructure_retries) | $(r.terminal_infrastructure_slots) | $(r.invalid_action_count) | $(r.decision_opportunities) |")
        end
        println(io,"\nBehavioral-failure slots are retained with persisted score 1.0. They occurred at:\n")
        for r in behavioral_worlds
            println(io,"- `$(r.condition_id)` world `$(r.world_seed)`, `$(r.policy)`; primary matched block retained: $(r.retained_primary).")
        end
        println(io,"\n## Cost and latency\n\nReconstructed from persisted operational metadata: $(ops.actual.requests) requests, $(ops.actual.input_tokens) input tokens, $(ops.actual.output_tokens) output tokens, \$$(ops.actual.cost) recorded cost, $(ops.actual.latency) s summed recorded latency. These totals exactly match the executor summary. ScientistPolicy requests are included across both conditions and all attempts. Per-policy details and the explicit count of missing per-request metadata are in `operational_summary.csv` and `operational_metadata_missing.csv` respectively. Missing values were not recoded to zero.\n")
        println(io,"\n## Exploratory efficiency observations\n\nRun-level final scores are paired with valid interventions and decision opportunities in `run_metrics.csv`; `intervention-use.svg` is descriptive. The repository has no frozen prefix-scoring mechanism. Full prefix error trajectories require a separately specified evaluator extension; no new estimator was introduced here.\n")
        println(io,"\n## Limitations\n\nThis is one controlled damped-oscillator task, one model treatment, and one scientist repetition per preregistered world. It does not establish general scientific reasoning or adaptive superiority over an LLM open-loop design. Infrastructure exclusions reduce the matched primary population and create policy-specific, potentially informative missingness: all four excluded gaussian worlds (8123003, 8123013, 8123023, 8123028) were excluded because the ScientistPolicy slot failed infrastructure twice. The complete-case contrast therefore does not represent an unconditionally observed policy population.\n")
        println(io,"\n## Exact reproducibility commands\n\n```bash\njulia +1.12.7 --project=. scripts/analyze_confirmatory_v0_1.jl\n```\n")
    end
end
function write_effects(io,rows,supported)
    println(io,"| Endpoint | N worlds | Scientist mean | Baseline mean | Mean paired difference | 95% CI low | 95% CI high | Superiority? |\n|---|---:|---:|---:|---:|---:|---:|---|")
    for r in rows
        println(io,"| $(r.endpoint) | $(r.n_worlds) | $(r.scientist_mean) | $(r.baseline_mean) | $(r.mean_paired_difference) | $(r.ci_low) | $(r.ci_high) | $(r.superiority ? "Yes" : "No") |")
    end
    h=isempty(rows) ? "not supported" : supported ? "supported" : "not supported"
    println(io,"\n**Overall hypothesis: $(h).** Both co-primary endpoint intervals must independently lie below zero.")
end

end
if abspath(PROGRAM_FILE)==@__FILE__
    ConfirmatoryV01Analysis.analyze()
end
