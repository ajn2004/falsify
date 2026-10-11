module V02ProtocolLock
using JSON3, SHA, Falsify
include(joinpath(@__DIR__,"V02SeedAudit.jl"))
export validate_lock
hashfile(p)=bytes2hex(sha256(read(p)))
function validate_lock(path; root=normpath(joinpath(@__DIR__,"..")), expected_protocol="falsify-v0.2-prereg-1")
    isfile(path) || error("lock missing: $path")
    lock=JSON3.read(read(path,String))
    lock.schema_version==1 || error("unsupported lock schema_version")
    lock.protocol_id==expected_protocol || error("protocol ID mismatch: expected $expected_protocol, found $(lock.protocol_id)")
    files=String[]
    for entry in lock.files
        rel=String(entry.path); occursin(r"(^/|(^|/)\.\.(/|$))",rel) && error("unsafe lock path: $rel")
        file=joinpath(root,rel); isfile(file) || error("locked file missing: $rel")
        got=hashfile(file); got==entry.sha256 || error("SHA-256 mismatch for $rel: expected $(entry.sha256), found $got")
        push!(files,rel)
    end
    length(unique(files))==length(files) || error("duplicate locked file entry")
    source_files=("src/Falsify.jl","src/environments/CoupledOscillator.jl",
        "src/environments/DuffingEnvironment.jl","src/agents/ScientistPolicy.jl",
        "src/baselines/RandomPolicy.jl","src/baselines/FixedDesignPolicy.jl",
        "src/protocol/RunController.jl","src/providers/OpenRouterClient.jl",
        "src/evaluation/V02Evaluation.jl","scripts/run_confirmatory_v0_2.jl","scripts/V02Lock.jl")
    all(in(files),source_files)||error("lock omits a required scientific source file")
    required_roles=("preregistration","seed_manifest","execution_config","evaluator_config",
        "analysis_config","provider_config","adaptive_prompt","open_loop_prompt","manifest")
    for role in required_roles
        hasproperty(lock.roles,Symbol(role)) || error("lock missing required role: $role")
        String(getproperty(lock.roles,Symbol(role))) in files || error("lock role $role is not SHA-256 protected")
    end
    cpath=String(lock.execution_config)
    cpath in files || error("execution config is not included in file hashes")
    cfg=JSON3.read(read(joinpath(root,cpath),String))
    for (config_key,role) in (("seed_manifest","seed_manifest"),("evaluator_config","evaluator_config"),
            ("provider_config","provider_config"),("analysis_config","analysis_config"))
        hasproperty(cfg,Symbol(config_key))||error("execution config missing $config_key path")
        String(getproperty(cfg,Symbol(config_key)))==String(getproperty(lock.roles,Symbol(role)))||error("execution/lock role mismatch for $role")
    end
    for prompt in ("adaptive_prompt","open_loop_prompt")
        path=String(getproperty(lock.roles,Symbol(prompt)))
        expected=String(getproperty(lock.prompt_hashes,Symbol(prompt)))
        hashfile(joinpath(root,path))==expected || error("prompt identity/hash mismatch for $prompt")
        source=prompt=="adaptive_prompt" ? GENERIC_SCIENTIST_PROMPT : OPEN_LOOP_PROMPT
        expected_version=prompt=="adaptive_prompt" ? GENERIC_PROMPT_VERSION : OPEN_LOOP_PROMPT_VERSION
        expected==bytes2hex(sha256(source)) || error("locked prompt differs from the prompt used by policy code: $prompt")
        item=getproperty(cfg.prompts,Symbol(prompt))
        String(item.version)==expected_version&&String(item.sha256)==expected || error("confirmatory config prompt identity/hash mismatch for $prompt")
    end
    cfg.protocol_id==lock.protocol_id || error("execution config protocol ID mismatch")
    prereg=read(joinpath(root,String(lock.roles.preregistration)),String)
    occursin(String(lock.protocol_id),prereg)||error("preregistration protocol identity mismatch")
    occursin(r"(?i)\bTBD\b",prereg)&&error("preregistration contains unresolved TBD fields")
    startswith(String(cfg.artifact_namespace),"results/confirmatory-v0.2-") || error("artifact namespace is not a versioned V0.2 confirmatory namespace")
    any(e->e.id=="coupled_damped_oscillator_v0_2"&&e.version=="v0.2-coupled-1",cfg.environments) || error("wrong coupled environment version")
    any(e->e.id=="linear_vs_duffing_v0_2"&&e.version=="2",cfg.environments) || error("wrong structural environment version")
    Set(String(p.name)*"/"*String(p.version) for p in cfg.policies)==Set(("random/v0","fixed_design/v0","scientist_adaptive/scientist-v0-2-schema-driven-v1","scientist_open_loop/scientist-v0-2-open-loop-v1")) || error("wrong policy version")
    Int(cfg.intervention_budget)>0 || error("intervention budget must be positive")
    noise=Dict(String(n.condition)=>Float64(n.sigma_m) for n in cfg.noise_conditions)
    !isempty(noise)&&all(isfinite(v)&&v>=0 for v in values(noise)) || error("invalid execution noise conditions")
    seed_path=String(lock.roles.seed_manifest)
    seed_audit=V02SeedAudit.audit_manifest(joinpath(root,seed_path);repo_root=root)
    return (protocol_id=String(lock.protocol_id),checked_files=length(files),execution_config=cpath,seed_audit)
end
end
