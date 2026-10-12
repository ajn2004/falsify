using Falsify, TOML, JSON3, SHA
include(joinpath(@__DIR__,"V02EvaluatorConfig.jl"))
include(joinpath(@__DIR__,"V02PilotProtocol.jl"))

function make_policy(name, seed, client)
    name=="random" && return RandomPolicy(seed)
    name=="fixed" && return FixedDesignPolicy()
    name=="adaptive_llm" && return ScientistPolicy(client)
    name=="open_loop_llm" && return OpenLoopScientistPolicy(client)
    error("unknown pilot policy $name")
end
noise_for(label)=label=="clean" ? CleanObservation() : startswith(label,"gaussian_") ?
    GaussianObservationNoise(parse(Float64,split(label,"_";limit=2)[2])) : error("unsupported noise condition $label")

function main(config_path)
    root=normpath(joinpath(@__DIR__,"..")); cfg=TOML.parsefile(config_path)
    occursin("pilot",String(cfg["pilot_protocol_id"])) || error("pilot protocol ID must be explicitly exploratory")
    out=normpath(joinpath(root,String(cfg["artifact_root"]))); allowed=joinpath(root,"results","pilot-v0.2"); relative=relpath(out,allowed)
    (relative==".."||startswith(relative,"../")||startswith(relative,"..\\")) && error("pilot artifacts must remain in results/pilot-v0.2")
    ENVIRONMENT=String.(cfg["environments"]); policies=String.(cfg["policies"])
    structural_version=String(get(cfg,"structural_environment_version","2"))
    structural_version in ("2","3") || error("unsupported structural environment version $structural_version")
    all(p->p in ("random","fixed","adaptive_llm","open_loop_llm"),policies) || error("unsupported pilot policy")
    Set(String.(cfg["retry_codes"]))==Set(Falsify.PROVIDER_INFRASTRUCTURE_CODES) || error("retry codes must exactly match the frozen infrastructure classes")
    Int(cfg["infrastructure_retries"])==1 || error("pilot retry allowance is frozen at one infrastructure retry")
    any(p->p in ("adaptive_llm","open_loop_llm"),policies) && isempty(strip(get(ENV,"OPENROUTER_API_KEY",""))) && error("OPENROUTER_API_KEY required for live LLM pilot")
    pc=Falsify.OpenRouterIntegration.load_openrouter_config(joinpath(root,"configs",String(cfg["provider_config"])))
    ec=V02EvaluatorConfigFile.load_config(joinpath(root,"configs",String(cfg["evaluator_config"])))
    planpath=joinpath(out,"execution-plan.json"); ispath(planpath)&&error("pilot root already contains an execution plan; select a new versioned pilot root")
    raw=joinpath(out,"raw"); mkpath(raw); ledger=joinpath(out,"run-ledger.jsonl")
    slots=Any[]; results=Any[]; state_slots=Any[]; journal=joinpath(out,"attempt-journal.jsonl")
    seeds_for(env)=haskey(cfg,"world_seeds_by_environment") ? Int.(cfg["world_seeds_by_environment"][env]) : Int.(cfg["world_seeds"])
    budgets=Int.(get(cfg,"budget_candidates",[Int(cfg["intervention_budget"])]))
    for env in ENVIRONMENT, seed in seeds_for(env), noise in String.(cfg["noise_conditions"]), budget in budgets, policy_name in policies
        noise_for(noise)
        block="$(env)|seed=$(seed)|noise=$(noise)|budget=$(budget)"; slot="$(block)|policy=$(policy_name)"; rep="pilot-1"
        noise_seed=noise=="clean" ? Int(cfg["clean_noise_seed"]) : seed+Int(cfg["noise_seed_offset"])
        policy_seed=policy_name=="random" ? seed+Int(cfg["policy_seed_offset"])+findfirst(==(policy_name),policies) : nothing
        world=env=="coupled_damped_oscillator_v0_2" ? generate_coupled_world(seed) : env=="linear_vs_duffing_v0_2" ? generate_duffing_world(seed;version=structural_version) : error("unsupported environment $env")
        n=noise_for(noise)
        report_policy=policy_name=="adaptive_llm" ? "scientist_adaptive" : policy_name=="open_loop_llm" ? "scientist_open_loop" : policy_name=="fixed" ? "fixed_design" : "random"
        env_version=env=="linear_vs_duffing_v0_2" ? structural_version : "v0.2-coupled-1"
        push!(slots,(slot_id=slot,policy=report_policy,treatment=policy_name,condition_id="$(env)|v$(env_version)|$(noise)|budget=$(budget)",environment=env,environment_version=env_version,noise_condition=noise,intervention_budget=budget,world_seed=seed,noise_seed,policy_seed,repetition_id=rep,block_id=block))
    end
    open(planpath,"w") do io; write(io,JSON3.write((protocol_id=cfg["pilot_protocol_id"],slots)));write(io,'\n');end
    for s in slots
        world=s.environment=="coupled_damped_oscillator_v0_2" ? generate_coupled_world(s.world_seed) : generate_duffing_world(s.world_seed;version=structural_version)
        noise=noise_for(s.noise_condition)
        runconfig=RunConfig(s.intervention_budget;max_decision_opportunities=Int(cfg["decision_opportunity_cap"]),observation_noise=noise,noise_seed=s.noise_seed)
        classification="pending"; attempts=0; attempt=nothing; attempt_ids=String[]; attempt_classes=String[]
        while attempts <= Int(cfg["infrastructure_retries"])
            attempts+=1; client=Falsify.OpenRouterIntegration.OpenRouterClient(pc)
            p=make_policy(s.treatment,s.policy_seed,client)
            attempt=run_attempt(world,p,runconfig;root,artifacts_root=raw,ledger_path=ledger,
                repetition_id="$(s.repetition_id)$(attempts==1 ? "" : "-retry$(attempts-1)")",
                condition_id=s.condition_id,protocol_id=String(cfg["pilot_protocol_id"]))
            classification=attempt.classification
            push!(attempt_ids,attempt.run_id);push!(attempt_classes,classification)
            open(journal,"a") do io
                write(io,JSON3.write((event="attempt_started",run_id=attempt.run_id,slot_id=s.slot_id,policy=s.policy,
                    condition_id=s.condition_id,repetition_id="$(s.repetition_id)$(attempts==1 ? "" : "-retry$(attempts-1)")",
                    protocol_id=cfg["pilot_protocol_id"],environment=s.environment,environment_version=s.environment_version,noise_condition=s.noise_condition,world_seed=s.world_seed,noise_seed=s.noise_seed)));write(io,'\n')
                write(io,JSON3.write((event="attempt_finished",run_id=attempt.run_id,slot_id=s.slot_id,classification,policy=s.policy,protocol_id=cfg["pilot_protocol_id"])));write(io,'\n')
            end
            used=attempt.outcome===nothing ? 0 : attempt.outcome.public.terminal.interventions_used
            V02PilotProtocol.retry_infrastructure_attempt(classification,attempts,Int(cfg["infrastructure_retries"]),used) && continue
            break
        end
        attempts<=Int(cfg["infrastructure_retries"])+1 || error("retry loop invariant failed")
        push!(results,(slot_id=s.slot_id,attempts,attempt_ids,attempt_classes,classification,run_id=attempt.run_id,artifact_dir=attempt.artifact_dir))
        push!(state_slots,(slot_id=s.slot_id,run_ids=attempt_ids,status=classification))
        println("$(s.slot_id) => $classification (attempt $attempts)")
    end
    open(joinpath(out,"slot-results.json"),"w") do io; write(io,JSON3.write((pilot_protocol_id=cfg["pilot_protocol_id"],results)));write(io,'\n');end
    open(joinpath(out,"execution-state.json"),"w") do io; write(io,JSON3.write((slots=state_slots,)));write(io,'\n');end
    open(joinpath(out,"pilot-provenance.json"),"w") do io
        write(io,JSON3.write((pilot_protocol_id=cfg["pilot_protocol_id"],pilot_version=cfg["pilot_protocol_id"],
            config_sha256=bytes2hex(sha256(read(config_path))),evaluator_config_sha256=bytes2hex(sha256(read(joinpath(root,"configs",String(cfg["evaluator_config"]))))),
            provider_config_sha256=bytes2hex(sha256(read(joinpath(root,"configs",String(cfg["provider_config"]))))),
            provider_model=pc.model,provider_order=pc.provider_order,allow_fallbacks=pc.allow_fallbacks,
            max_completion_tokens=pc.max_completion_tokens,reasoning_effort=pc.reasoning_effort,provider_seed=pc.seed,
            adaptive_prompt_version=GENERIC_PROMPT_VERSION,adaptive_prompt_sha256=bytes2hex(sha256(GENERIC_SCIENTIST_PROMPT)),
            open_loop_prompt_version=OPEN_LOOP_PROMPT_VERSION,open_loop_prompt_sha256=bytes2hex(sha256(OPEN_LOOP_PROMPT)),
            policy_identities=Dict("random"=>"random/v0","fixed"=>"fixed_design/v0","adaptive_llm"=>"scientist_adaptive/scientist-v0-2-schema-driven-v1","open_loop_llm"=>"scientist_open_loop/scientist-v0-2-open-loop-v1"),
            slot_count=length(slots),result_count=length(results))));write(io,'\n')
    end
    scores=map(results) do r
        r.artifact_dir===nothing && return (;slot_id=r.slot_id,classification=r.classification)
        m=score_v0_2_run(load_run(r.artifact_dir),ec)
        (;slot_id=r.slot_id,classification=r.classification,run_class=m.run_class,fit_status=m.fit_status,
            parameter_error=m.parameter_error,parameter_errors=m.parameter_errors,heldout_rmse_m=m.heldout_rmse_m,
            heldout_normalized_error=m.heldout_normalized_error,true_class=m.true_class,selected_class=m.selected_class,
            class_correct=m.class_correct,delta_per_sample=m.delta_per_sample,selected_prediction_rmse_m=m.selected_prediction_rmse_m,
            selected_normalized_error=m.heldout_normalized_error,true_model_prediction_rmse_m=m.true_model_prediction_rmse_m)
    end
    open(joinpath(out,"scores.jsonl"),"w") do io; foreach(x->(write(io,JSON3.write(x));write(io,'\n')),scores);end
    println("EXPLORATORY PILOT ONLY: ",length(results)," logical slots at ",out)
end

length(ARGS)==1 || error("usage: julia --project=. scripts/run_v0_2_pilot.jl CONFIG.toml")
main(abspath(ARGS[1]))
