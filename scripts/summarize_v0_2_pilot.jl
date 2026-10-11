using JSON3, Statistics
length(ARGS)==1 || error("usage: julia --project=. scripts/summarize_v0_2_pilot.jl PILOT_ROOT")
root=abspath(ARGS[1]); results=JSON3.read(read(joinpath(root,"slot-results.json"),String)).results
ledger=JSON3.read.(filter(!isempty,strip.(readlines(joinpath(root,"run-ledger.jsonl")))))
scores=JSON3.read.(filter(!isempty,strip.(readlines(joinpath(root,"materialized","scores-v0.2.jsonl")))))
byrun=Dict(String(r.run_id)=>r for r in scores); byslot=Dict(String(r.run_id)=>r for r in ledger)
noise_label(l)=split(String(l.condition_id),'|')[2]
groups=Any[]
for env in sort!(unique(String(r.environment_id) for r in scores)), policy in ("random","fixed_design"), noise in sort!(unique(noise_label(l) for l in ledger if l.environment_id==env)),
    budget in sort!(unique(Int(l.intervention_budget) for l in ledger if l.environment_id==env))
    ids=[String(r.run_id) for r in ledger if r.environment_id==env && r.policy_name==policy && r.intervention_budget==budget &&
        noise_label(r)==noise]
    rows=[byrun[id] for id in ids if haskey(byrun,id)]
    isempty(rows)&&continue
    vals(field)=Float64[getproperty(r,field) for r in rows if getproperty(r,field)!==nothing]
    data=(environment=env,policy=policy,noise_condition=noise,intervention_budget=budget,n=length(rows),
        fit_success=count(r->r.fit_status=="success",rows),
        mean_heldout_normalized=isempty(vals(:heldout_normalized_error)) ? nothing : mean(vals(:heldout_normalized_error)),
        median_heldout_normalized=isempty(vals(:heldout_normalized_error)) ? nothing : median(vals(:heldout_normalized_error)),
        sd_heldout_normalized=length(vals(:heldout_normalized_error))<2 ? nothing : std(vals(:heldout_normalized_error)),
        min_heldout_normalized=isempty(vals(:heldout_normalized_error)) ? nothing : minimum(vals(:heldout_normalized_error)),
        max_heldout_normalized=isempty(vals(:heldout_normalized_error)) ? nothing : maximum(vals(:heldout_normalized_error)),
        mean_raw_heldout_rmse=isempty(vals(:heldout_rmse_m)) ? nothing : mean(vals(:heldout_rmse_m)),
        mean_parameter_error=isempty(vals(:parameter_error)) ? nothing : mean(vals(:parameter_error)),
        mean_k_error=isempty(rows)||env!="coupled_damped_oscillator_v0_2" ? nothing : mean(Float64(r.parameter_errors.k) for r in rows),
        mean_kc_error=isempty(rows)||env!="coupled_damped_oscillator_v0_2" ? nothing : mean(Float64(r.parameter_errors.kc) for r in rows),
        mean_c_error=isempty(rows)||env!="coupled_damped_oscillator_v0_2" ? nothing : mean(Float64(r.parameter_errors.c) for r in rows),
        class_correct=count(r->r.class_correct===true,rows),undetermined=count(r->r.selected_class=="undetermined",rows),
        confusion=Dict("$(truth)/$(selected)"=>count(r->r.true_class==truth&&r.selected_class==selected,rows)
            for truth in ("linear","duffing") for selected in ("linear","duffing","undetermined","behavioral_failure")),
        mean_delta=isempty(vals(:delta_per_sample)) ? nothing : mean(vals(:delta_per_sample)),
        min_delta=isempty(vals(:delta_per_sample)) ? nothing : minimum(vals(:delta_per_sample)),
        max_delta=isempty(vals(:delta_per_sample)) ? nothing : maximum(vals(:delta_per_sample)),
        evaluator_failures=count(r->r.run_class=="apparatus_failure",rows))
    push!(groups,data)
end
ops=Any[]
for pol in ("scientist_adaptive","scientist_open_loop")
    req=Any[]
    for l in ledger
        l.policy_name==pol||continue
        pubpath=joinpath(root,"raw",String(l.run_id),"public.json"); isfile(pubpath)||continue
        p=JSON3.read(read(pubpath,String))
        for e in p.events
            e.operational_metadata===nothing||push!(req,e.operational_metadata)
        end
    end
    push!(ops,(policy=pol,provider_requests=length(req),input_tokens=sum((Int(x.input_tokens===nothing ? 0 : x.input_tokens) for x in req);init=0),
        output_tokens=sum((Int(x.output_tokens===nothing ? 0 : x.output_tokens) for x in req);init=0),
        cost=sum((Float64(x.cost===nothing ? 0.0 : x.cost) for x in req);init=0.0),
        latency_median_s=isempty(req) ? nothing : median(Float64[x.latency_s for x in req if x.latency_s!==nothing])))
end
out=(designation="EXPLORATORY — NOT CONFIRMATORY",pilot_protocol_id=String(JSON3.read(read(joinpath(root,"pilot-provenance.json"),String)).pilot_protocol_id),
    logical_slots=length(results),completed=count(r->r.classification=="completed",results),behavioral_failures=count(r->r.classification=="behavioral_failure",results),
    terminal_infrastructure=count(r->r.classification=="infrastructure",results),apparatus_failures=count(r->r.classification=="apparatus_failure",results),
    groups,operations=ops)
write(joinpath(root,"pilot-summary.json"),JSON3.write(out)*"\n")
println(JSON3.write(out))
