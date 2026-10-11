module V02Evaluation

using ..Falsify: ExperimentAction, CoupledOscillatorAction, CoupledTruth, CoupledMetadata,
    CoupledOscillatorWorld, execute_experiment, DuffingTruth, DuffingMetadata, DuffingWorld,
    OscillatorConfig, linear, duffing, ODEProblem, solve, Tsit5, classify_run
using SHA, JSON3

export V02EvaluatorConfig, V02RunMetrics, score_v0_2_run, config_hash

Base.@kwdef struct V02EvaluatorConfig
    version::String = "v0.2-evaluator-1"
    coupled_k::Tuple{Float64,Float64} = (1.5,4.0)
    coupled_kc::Tuple{Float64,Float64} = (0.3,2.0)
    coupled_c::Tuple{Float64,Float64} = (0.15,0.8)
    coupled_forced_probe::Union{Nothing,NTuple{6,Float64}} = nothing
    coupled_prediction_scale_m::Float64 = 1.0
    structural_zeta::Tuple{Float64,Float64} = (0.08,0.30)
    structural_omega::Tuple{Float64,Float64} = (0.9,1.8)
    structural_beta::Tuple{Float64,Float64} = (0.15,0.8)
    structural_probes::Tuple = ((0.2,0.0,0.0,0.0),(0.0,0.0,0.2,0.8),(1.5,0.0,0.0,0.0),(0.0,0.0,0.8,1.1))
    structural_prediction_scale_m::Float64 = 1.0
    failure_penalty::Float64 = 1.0
    grid_points::Int = 5
    max_iterations::Int = 120
    tolerance::Float64 = 1e-7
end

config_hash(c::V02EvaluatorConfig=V02EvaluatorConfig()) = bytes2hex(sha256(JSON3.write(c)))

struct V02RunMetrics
    score_version::String
    run_id::String
    environment_id::String
    run_class::String
    fit_status::String
    parameters::Dict{String,Any}
    parameter_errors::Dict{String,Any}
    parameter_error::Union{Missing,Float64}
    heldout_rmse_m::Union{Missing,Float64}
    heldout_normalized_error::Union{Missing,Float64}
    true_class::Union{Nothing,String}
    selected_class::Union{Nothing,String}
    class_correct::Union{Missing,Bool}
    linear_fit_status::Union{Nothing,String}
    duffing_fit_status::Union{Nothing,String}
    linear_rss::Union{Missing,Float64}
    duffing_rss::Union{Missing,Float64}
    linear_score::Union{Missing,Float64}
    duffing_score::Union{Missing,Float64}
    delta_per_sample::Union{Missing,Float64}
    selected_prediction_rmse_m::Union{Missing,Float64}
    true_model_prediction_rmse_m::Union{Missing,Float64}
end

_get(x,k)=x isa AbstractDict ? x[string(k)] : getproperty(x,k)
function _fit_data(p, env)
    rows=Any[]
    for e in p.events
        e.consumed_intervention && e.requested_action !== nothing && e.observation !== nothing || continue
        a=e.requested_action; o=e.observation
        if env=="coupled_damped_oscillator_v0_2"
            push!(rows,(Float64[a.x1_initial_m,a.x2_initial_m,a.v1_initial_m_per_s,a.v2_initial_m_per_s,a.drive_force_n,a.drive_frequency_hz],
                Float64.(o.time_s),Float64.(o.x1_m),Float64.(o.x2_m)))
        else
            push!(rows,(Float64[a.initial_displacement_m,a.initial_velocity_m_per_s,a.drive_acceleration_m_per_s2,a.drive_frequency_hz],
                Float64[m.time_s for m in o.measurements],Float64[m.displacement_m for m in o.measurements],Float64[]))
        end
    end
    rows
end

function _simulate_coupled(a,times,p)
    f(t)=a[5]*sin(2pi*a[6]*t)
    function rhs!(du,u,_,t)
        x1,x2,v1,v2=u; du[1]=v1;du[2]=v2
        du[3]=(f(t)-p[3]*v1-p[1]*x1-p[2]*(x1-x2))
        du[4]=(-p[3]*v2-p[1]*x2-p[2]*(x2-x1))/1.5
    end
    sol=solve(ODEProblem(rhs!,[a[1],a[2],a[3],a[4]],(first(times),last(times))),Tsit5();saveat=times,reltol=1e-9,abstol=1e-11,dense=false)
    (Float64[u[1] for u in sol.u],Float64[u[2] for u in sol.u])
end
function _simulate_struct(a,times,p,beta)
    f(t)=a[3]*sin(2pi*a[4]*t)
    function rhs!(du,u,_,t)
        du[1]=u[2]; du[2]=f(t)-2p[1]*p[2]*u[2]-p[2]^2*u[1]-beta*u[1]^3
    end
    sol=solve(ODEProblem(rhs!,[a[1],a[2]],(first(times),last(times))),Tsit5();saveat=times,reltol=1e-9,abstol=1e-11,dense=false)
    Float64[u[1] for u in sol.u]
end

function _optimize(objective,bounds,cfg)
    all(r->all(isfinite,r)&&r[1]<r[2],bounds) || return (:invalid_configuration,nothing,Inf)
    best=Inf; point=[(r[1]+r[2])/2 for r in bounds]
    for idx in Iterators.product((1:cfg.grid_points for _ in bounds)...)
        x=[range(bounds[j]...;length=cfg.grid_points)[idx[j]] for j in eachindex(bounds)]
        y=objective(x); if isfinite(y)&&y<best; best=y;point=x;end
    end
    isfinite(best)||return (:optimizer_failed,nothing,Inf)
    steps=[(r[2]-r[1])/(cfg.grid_points-1) for r in bounds]
    for _=1:cfg.max_iterations
        previous=best
        changed=false
        for j in eachindex(point), sign in (-1.0,1.0)
            x=copy(point);x[j]=clamp(x[j]+sign*steps[j],bounds[j]...); y=objective(x)
            if isfinite(y)&&y<best;point=x;best=y;changed=true;end
        end
        if !changed
            steps .*= 0.5
            maximum(steps)<cfg.tolerance && return (:success,point,best)
        elseif previous-best <= cfg.tolerance*max(1.0,abs(previous))
            return (:success,point,best)
        end
    end
    (:iteration_limit,point,best)
end
function _objective(rows,model,p)
    rss=0.0;n=0
    try
        for (a,t,y1,y2) in rows
            pred=model(a,t,p)
            if length(pred)==2
                rss+=sum(abs2,pred[1].-y1)+sum(abs2,pred[2].-y2);n+=length(y1)+length(y2)
            else
                rss+=sum(abs2,pred.-y1);n+=length(y1)
            end
        end
    catch
        return Inf
    end
    n>0&&isfinite(rss) ? rss/n : Inf
end
_status(p)=String(p.status)
function score_v0_2_run(run,cfg::V02EvaluatorConfig=V02EvaluatorConfig())
    loaded=run isa AbstractString ? parentmodule(@__MODULE__).load_run(run) : run
    p,ev=loaded.public,loaded.evaluator; env=String(p.environment_id); envversion=String(p.environment_version); truth=ev.truth
    env in ("coupled_damped_oscillator_v0_2","linear_vs_duffing_v0_2")||throw(ArgumentError("unsupported V0.2 environment: $env"))
    expected_version=env=="coupled_damped_oscillator_v0_2" ? "v0.2-coupled-1" : "1"
    envversion==expected_version || throw(ArgumentError("unsupported environment version $envversion for $env"))
    status=String(p.status); terminal=p.terminal
    code=terminal===nothing||terminal.failure===nothing ? nothing : String(terminal.failure.code)
    runclass=classify_run(status,code)
    if runclass in ("infrastructure","apparatus_failure","behavioral_failure")
        endpoint=runclass=="behavioral_failure" ? cfg.failure_penalty : Base.missing
        trueclass=env=="linear_vs_duffing_v0_2" ? String(truth.model_class) : nothing
        # A policy failure is an observed class-identification failure, not missing class accuracy.
        selected=runclass=="behavioral_failure" && trueclass!==nothing ? "behavioral_failure" : nothing
        correct=selected===nothing ? Base.missing : false
        return V02RunMetrics("v0.2-score-1",String(p.run_id),env,runclass,"not_scored",Dict{String,Any}(),Dict{String,Any}(),endpoint,Base.missing,endpoint,
            trueclass,selected,correct,nothing,nothing,Base.missing,Base.missing,Base.missing,Base.missing,Base.missing,Base.missing,Base.missing)
    end
    rows=try _fit_data(p,env) catch; Any[] end
    if env=="coupled_damped_oscillator_v0_2"
        obj=x->_objective(rows,_simulate_coupled,x)
        st,x,val=_optimize(obj,[cfg.coupled_k,cfg.coupled_kc,cfg.coupled_c],cfg)
        if st != :success
            return V02RunMetrics("v0.2-score-1",String(p.run_id),env,"apparatus_failure",String(st),Dict{String,Any}(),Dict{String,Any}(),missing,missing,missing,nothing,nothing,missing,nothing,nothing,missing,missing,missing,missing,missing,missing,missing)
        end
        errs=Dict("k"=>abs(x[1]-Float64(truth.stiffness_k_n_per_m))/(cfg.coupled_k[2]-cfg.coupled_k[1]),
            "kc"=>abs(x[2]-Float64(truth.coupling_kc_n_per_m))/(cfg.coupled_kc[2]-cfg.coupled_kc[1]),
            "c"=>abs(x[3]-Float64(truth.damping_c_n_s_per_m))/(cfg.coupled_c[2]-cfg.coupled_c[1]))
        pe=sqrt(sum(v^2 for v in values(errs))/3)
        probes=Any[[1.,0,0,0,0,0],[0,1.,0,0,0,0],[1.,-1.,0,0,0,0],[0,0,.5,-.5,0,0]]
        cfg.coupled_forced_probe===nothing || push!(probes,collect(cfg.coupled_forced_probe))
        times=collect(range(0,10;length=101)); ss=0.0;n=0
        world=CoupledOscillatorWorld(CoupledTruth(Float64(truth.stiffness_k_n_per_m),Float64(truth.coupling_kc_n_per_m),Float64(truth.damping_c_n_s_per_m)),CoupledMetadata("Tsit5",1e-9,1e-11,10.,101,0,"evaluator",1.,1.5))
        for a in probes
            got=_simulate_coupled(a,times,x);target=execute_experiment(world,CoupledOscillatorAction(a...))
            ss+=sum(abs2,got[1].-target.x1_m)+sum(abs2,got[2].-target.x2_m);n+=2length(times)
        end
        rm=sqrt(ss/n)
        return V02RunMetrics("v0.2-score-1",String(p.run_id),env,runclass,String(st),Dict("k"=>x[1],"kc"=>x[2],"c"=>x[3]),errs,pe,rm,rm/(cfg.coupled_prediction_scale_m+rm),nothing,nothing,missing,nothing,nothing,missing,missing,missing,missing,missing,missing,missing)
    end
    # Both nested candidate families use the same observed samples and Gaussian iid residual likelihood.
    obj=(beta,bounds)->begin f=x->_objective(rows,(a,t,z)->_simulate_struct(a,t,z,beta),x);_optimize(f,bounds,cfg) end
    sl,xl,rl=obj(0.0,[cfg.structural_zeta,cfg.structural_omega])
    # Duffing includes beta as an optimized coordinate.
    sd,xd,rd=_optimize(x->_objective(rows,(a,t,z)->_simulate_struct(a,t,z[1:2],z[3]),x),[cfg.structural_zeta,cfg.structural_omega,cfg.structural_beta],cfg)
    nl=sum(length(r[3]) for r in rows); nl>0 || (sl=:insufficient_evidence;sd=:insufficient_evidence)
    if sl != :success || sd != :success
        return V02RunMetrics("v0.2-score-1",String(p.run_id),env,"apparatus_failure","fit_failed",Dict{String,Any}(),Dict{String,Any}(),missing,missing,missing,nothing,nothing,missing,String(sl),String(sd),missing,missing,missing,missing,missing,missing,missing)
    end
    # BIC with known sigma when present; otherwise Gaussian MLE variance RSS/N. BIC=-2 log L + k log N.
    first_observation=p.events[findfirst(e->e.consumed_intervention&&e.observation!==nothing,p.events)].observation
    sigma=first_observation.noise_scale_m
    sigma=sigma===nothing ? 0.0 : Float64(sigma)
    function bic(rss,k)
        r=max(rss*nl,eps(Float64)); s2=sigma>0 ? sigma^2 : r/nl
        (sigma>0 ? r/s2 : nl*log(max(s2,eps(Float64))))+k*log(nl)
    end
    bl,bd=bic(rl,2),bic(rd,3); delta=(bl-bd)/nl
    chosen=bl==bd ? "undetermined" : bl<bd ? "linear" : "duffing"
    trueclass=String(truth.model_class)
    correct=chosen==trueclass
    function pred_rmse(params,beta)
        times=collect(range(0,10;length=101)); total=0.0; n=0
        for (x0,v0,A,freq) in cfg.structural_probes
            action=ExperimentAction(initial_displacement_m=x0,initial_velocity_m_per_s=v0,drive_acceleration_m_per_s2=A,drive_frequency_hz=freq)
            y=_simulate_struct([x0,v0,A,freq],times,params,beta)
            world=DuffingWorld(DuffingTruth(beta==0 ? linear : duffing,Float64(truth.zeta),Float64(truth.omega0),Float64(truth.beta)),OscillatorConfig(),DuffingMetadata("Tsit5",1e-9,1e-11,0,v"0.0.0"))
            target=parentmodule(@__MODULE__).duffing_observe(world,action).displacement
            total+=sum(abs2,y.-target);n+=length(y)
        end
        sqrt(total/n)
    end
    oracle= trueclass=="linear" ? (xl,0.0) : (xd[1:2],xd[3])
    picked=chosen=="linear" ? (xl,0.0) : chosen=="duffing" ? (xd[1:2],xd[3]) : (nothing,0.0)
    selected_rm=picked[1]===nothing ? missing : pred_rmse(picked[1],picked[2])
    selected_norm=ismissing(selected_rm) ? missing : selected_rm/(cfg.structural_prediction_scale_m+selected_rm)
    oracle_rm=pred_rmse(oracle[1],oracle[2])
    perr=Dict{String,Any}()
    if chosen==trueclass
        perr["zeta"]=abs((chosen=="linear" ? xl[1] : xd[1])-Float64(truth.zeta))/(cfg.structural_zeta[2]-cfg.structural_zeta[1])
        perr["omega0"]=abs((chosen=="linear" ? xl[2] : xd[2])-Float64(truth.omega0))/(cfg.structural_omega[2]-cfg.structural_omega[1])
        trueclass=="duffing" && (perr["beta"]=abs(xd[3]-Float64(truth.beta))/(cfg.structural_beta[2]-cfg.structural_beta[1]))
    end
    pe=isempty(perr) ? missing : sqrt(sum(Float64(v)^2 for v in values(perr))/length(perr))
    pars=Dict("linear_zeta"=>xl[1],"linear_omega0"=>xl[2],"duffing_zeta"=>xd[1],"duffing_omega0"=>xd[2],"duffing_beta"=>xd[3])
    V02RunMetrics("v0.2-score-1",String(p.run_id),env,runclass,"success",pars,perr,pe,selected_rm,selected_norm,
        trueclass,chosen,correct,String(sl),String(sd),rl*nl,rd*nl,bl,bd,delta,selected_rm,oracle_rm)
end

end
