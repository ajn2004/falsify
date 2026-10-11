using Falsify, JSON3, SHA, Dates

length(ARGS)==2 || error("usage: julia --project=. scripts/materialize_v0_2_scores.jl <run-root> <output-dir>")
root,out=ARGS; isdir(root)||error("run root does not exist: $root"); mkpath(out)
cfg=V02EvaluatorConfig(); paths=sort(filter(d->isfile(joinpath(d,"public.json"))&&isfile(joinpath(d,"evaluator.json")),
    [joinpath(root,n) for n in readdir(root) if isdir(joinpath(root,n))]))
inputs=String[]; results=Any[]
for path in paths
    loaded=load_run(path)
    p=loaded.public
    p.environment_id in ("coupled_damped_oscillator_v0_2","linear_vs_duffing_v0_2")||continue
    push!(inputs,bytes2hex(sha256(read(joinpath(path,"public.json"))))*":"*bytes2hex(sha256(read(joinpath(path,"evaluator.json")))))
    push!(results,score_v0_2_run(loaded,cfg))
end
open(joinpath(out,"scores-v0.2.jsonl"),"w") do io
    foreach(x->(write(io,JSON3.write(x));write(io,'\n')),results)
end
manifest=joinpath(dirname(@__DIR__),"Manifest.toml")
provenance=(score_schema="v0.2-score-1",evaluator_config_hash=config_hash(cfg),
    evaluator_config=cfg,code_commit=try strip(read(`git -C $(dirname(@__DIR__)) rev-parse HEAD`,String)) catch;nothing end,
    manifest_hash=isfile(manifest) ? bytes2hex(sha256(read(manifest))) : nothing,
    input_artifact_hashes=inputs,timestamp_utc=string(now(UTC)),run_count=length(results))
open(joinpath(out,"provenance.json"),"w") do io; write(io,JSON3.write(provenance));write(io,'\n');end
