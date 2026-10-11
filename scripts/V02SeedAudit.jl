module V02SeedAudit
using JSON3, TOML
export assert_disjoint_world_seeds, audit_manifest, canonical_slots

field(x, name; default=nothing) = x isa AbstractDict ? get(x, name, default) : hasproperty(x, Symbol(name)) ? getproperty(x, Symbol(name)) : default
seedset(slots, name) = Set(Int(v) for s in slots for v in (field(s,name),) if v !== nothing)

function assert_disjoint(confirmatory, pilot, stream)
    overlap=intersect(Set(Int.(confirmatory)),Set(Int.(pilot)))
    isempty(overlap)||error("confirmatory $stream overlap exploratory pilot seeds: $(sort!(collect(overlap)))")
    true
end
assert_disjoint_world_seeds(confirmatory,pilot)=assert_disjoint(confirmatory,pilot,"world")

"""Canonical, outcome-free slot ordering for reproducible manifest generation."""
canonical_slots(slots) = sort(collect(slots), by=s->String(field(s,"slot_id")))

function pilot_records(repo_root)
    root=joinpath(repo_root,"results","pilot-v0.2")
    isdir(root)||return (world=Set{Int}(),noise=Set{Int}(),policy=Set{Int}(),roots=String[])
    world=Set{Int}(); noise=Set{Int}(); policy=Set{Int}(); roots=String[]
    for (dir,_,files) in walkdir(root)
        if "execution-plan.json" in files
            planpath=joinpath(dir,"execution-plan.json"); push!(roots,relpath(dir,repo_root))
            plan=JSON3.read(read(planpath,String))
            for s in plan.slots
                v=field(s,"world_seed"); v===nothing||push!(world,Int(v))
                v=field(s,"noise_seed"); v===nothing||push!(noise,Int(v))
                v=field(s,"policy_seed"); v===nothing||push!(policy,Int(v))
            end
        end
        # Deterministic evaluator-only diagnostics exercise worlds without run plans.
        for name in files
            (name=="diagnostic.json"||name=="probe-diagnostics-v1.json")||continue
            d=JSON3.read(read(joinpath(dir,name),String))
            for key in ("truth_seeds","world_seeds")
                values=field(d,key); values===nothing||foreach(v->push!(world,Int(v)),values)
            end
        end
    end
    (world=world,noise=noise,policy=policy,roots=roots)
end

function audit_manifest(manifest_path;repo_root=normpath(joinpath(@__DIR__,"..")))
    manifest=JSON3.read(read(manifest_path,String)); slots=manifest.slots
    isempty(slots)&&error("confirmatory seed manifest has no logical slots")
    ids=String[String(field(s,"slot_id")) for s in slots]
    all(x->!isempty(x),ids)||error("empty confirmatory slot ID")
    length(unique(ids))==length(ids)||error("duplicate confirmatory logical slot")
    ordered=String.(ids)
    issorted(ordered)||error("confirmatory slots must be sorted by slot_id for deterministic construction")
    for s in slots
        for key in ("world_seed","noise_seed")
            value=field(s,key); value===nothing&&error("confirmatory slot missing $key")
            Int(value)>=0||error("negative confirmatory $key")
        end
        for key in ("block_id","repetition_id","policy")
            isempty(String(field(s,key;default="")))&&error("confirmatory slot missing $key")
        end
    end
    block_replicates=[(String(field(s,"block_id")),String(field(s,"repetition_id")),String(field(s,"policy"))) for s in slots]
    length(unique(block_replicates))==length(slots)||error("duplicate confirmatory block/repetition/policy identity")

    pilots=pilot_records(repo_root)
    assert_disjoint(seedset(slots,"world_seed"),pilots.world,"world")
    assert_disjoint(seedset(slots,"noise_seed"),pilots.noise,"noise")
    assert_disjoint(seedset(slots,"policy_seed"),pilots.policy,"policy")
    v01path=joinpath(repo_root,"research","confirmatory-seeds-v0.1-prereg-4.toml")
    if isfile(v01path)
        v01=TOML.parsefile(v01path); v01seeds=Int[w["world_seed"] for w in v01["worlds"]]
        assert_disjoint(seedset(slots,"world_seed"),v01seeds,"V0.1 world")
    end
    (confirmatory_slots=length(slots),confirmatory_worlds=length(seedset(slots,"world_seed")),
        pilot_worlds=length(pilots.world),pilot_noise_streams=length(pilots.noise),
        pilot_policy_streams=length(pilots.policy),pilot_roots=sort!(pilots.roots),overlap=0)
end
end
