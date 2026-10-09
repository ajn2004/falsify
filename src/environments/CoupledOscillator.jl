"""DAL-151 known-structure, two-mass coupled oscillator environment."""
const COUPLED_ENVIRONMENT_VERSION = "v0.2-coupled-1"
const COUPLED_MASS_1_KG = 1.0
const COUPLED_MASS_2_KG = 1.5
const COUPLED_K_RANGE_N_PER_M = (1.5, 4.0)
const COUPLED_KC_RANGE_N_PER_M = (0.3, 2.0)
const COUPLED_C_RANGE_N_S_PER_M = (0.15, 0.8)
const COUPLED_DURATION_S = 10.0
const COUPLED_SAMPLE_COUNT = 101
const COUPLED_REL_TOL = 1e-9
const COUPLED_ABS_TOL = 1e-11

struct CoupledTruth
    stiffness_k_n_per_m::Float64
    coupling_kc_n_per_m::Float64
    damping_c_n_s_per_m::Float64
end
struct CoupledMetadata
    solver::String
    reltol::Float64
    abstol::Float64
    duration_s::Float64
    sample_count::Int
    world_seed::Int
    generation_version::String
    mass_1_kg::Float64
    mass_2_kg::Float64
end
struct CoupledOscillatorWorld <: AbstractEnvironment
    truth::CoupledTruth
    provenance::CoupledMetadata
end
struct CoupledOscillatorAction <: AbstractExperimentAction
    x1_initial_m::Float64
    x2_initial_m::Float64
    v1_initial_m_per_s::Float64
    v2_initial_m_per_s::Float64
    drive_force_n::Float64
    drive_frequency_hz::Float64
end
# Evaluator-side unforced members of the DAL-149 probe set. The fifth, forced
# probe is intentionally unresolved until its pilot-fixed frequency is frozen.
const COUPLED_EVALUATOR_PROBE_CANDIDATES = (
    CoupledOscillatorAction(1.0,0.0,0.0,0.0,0.0,0.0),
    CoupledOscillatorAction(0.0,1.0,0.0,0.0,0.0,0.0),
    CoupledOscillatorAction(1.0,-1.0,0.0,0.0,0.0,0.0),
    CoupledOscillatorAction(0.0,0.0,0.5,-0.5,0.0,0.0))
struct CoupledCleanObservation <: AbstractPolicyObservation
    time_s::Tuple{Vararg{Float64}}
    x1_m::Tuple{Vararg{Float64}}
    x2_m::Tuple{Vararg{Float64}}
end
struct CoupledObservation <: AbstractPolicyObservation
    time_s::Tuple{Vararg{Float64}}
    x1_m::Tuple{Vararg{Float64}}
    x2_m::Tuple{Vararg{Float64}}
    uncertainty_m::Float64
    noise_model::String
    noise_scale_m::Float64
end
struct CoupledTaskDescription
    model_description::String
    x_initial_bounds_m::Tuple{Float64,Float64}
    v_initial_bounds_m_per_s::Tuple{Float64,Float64}
    drive_force_bounds_n::Tuple{Float64,Float64}
    drive_frequency_bounds_hz::Tuple{Float64,Float64}
    duration_s::Float64
    sample_count::Int
end
const COUPLED_ACTION_SCHEMA = Dict("type"=>"object", "properties"=>Dict(
    "x1_initial_m"=>Dict("type"=>"number"), "x2_initial_m"=>Dict("type"=>"number"),
    "v1_initial_m_per_s"=>Dict("type"=>"number"), "v2_initial_m_per_s"=>Dict("type"=>"number"),
    "drive_force_n"=>Dict("type"=>"number"), "drive_frequency_hz"=>Dict("type"=>"number")),
    "required"=>["x1_initial_m", "x2_initial_m", "v1_initial_m_per_s", "v2_initial_m_per_s", "drive_force_n", "drive_frequency_hz"],
    "additionalProperties"=>false)

function generate_coupled_world(seed::Integer)
    seed >= 0 || throw(ArgumentError("seed must be nonnegative"))
    rng = MersenneTwister(seed)
    # Stable world RNG draw order, all independent uniform draws in physical scale: k, kc, c.
    draw(bounds) = bounds[1] + rand(rng) * (bounds[2] - bounds[1])
    truth = CoupledTruth(draw(COUPLED_K_RANGE_N_PER_M), draw(COUPLED_KC_RANGE_N_PER_M), draw(COUPLED_C_RANGE_N_S_PER_M))
    meta = CoupledMetadata("Tsit5", COUPLED_REL_TOL, COUPLED_ABS_TOL, COUPLED_DURATION_S,
        COUPLED_SAMPLE_COUNT, Int(seed), COUPLED_ENVIRONMENT_VERSION, COUPLED_MASS_1_KG, COUPLED_MASS_2_KG)
    CoupledOscillatorWorld(truth, meta)
end

environment_id(::CoupledOscillatorWorld) = "coupled_damped_oscillator_v0_2"
environment_version(::CoupledOscillatorWorld) = COUPLED_ENVIRONMENT_VERSION
action_schema(::CoupledOscillatorWorld) = COUPLED_ACTION_SCHEMA
metadata(w::CoupledOscillatorWorld) = w.provenance
evaluator_truth(w::CoupledOscillatorWorld) = (stiffness_k_n_per_m=w.truth.stiffness_k_n_per_m,
    coupling_kc_n_per_m=w.truth.coupling_kc_n_per_m, damping_c_n_s_per_m=w.truth.damping_c_n_s_per_m,
    mass_1_kg=COUPLED_MASS_1_KG, mass_2_kg=COUPLED_MASS_2_KG)
environment_provenance(w::CoupledOscillatorWorld) = (solver=w.provenance.solver,
    reltol=w.provenance.reltol, abstol=w.provenance.abstol, duration_s=w.provenance.duration_s,
    sample_count=w.provenance.sample_count, generation_version=w.provenance.generation_version,
    mass_1_kg=w.provenance.mass_1_kg, mass_2_kg=w.provenance.mass_2_kg,
    state_order="(x1,x2,v1,v2)")
public_task(::CoupledOscillatorWorld) = CoupledTaskDescription(
    "Known coupled damped oscillator parameter-identification task. Equations: " *
    "m1*x1'' + c*x1' + k*x1 + kc*(x1-x2) = u(t); " *
    "m2*x2'' + c*x2' + k*x2 + kc*(x2-x1) = 0; u(t)=A*sin(2*pi*f*t). " *
    "Known masses: m1=1.0 kg, m2=1.5 kg. Choose initial displacements x1,x2 in m, " *
    "initial velocities v1,v2 in m/s, force amplitude A in N, and frequency f in Hz. " *
    "Ranges: each initial displacement and velocity [-1,1], A [-1,1], f [0,2]. " *
    "If A=0 set f=0; if A!=0 choose f>0. Both coordinates are observed on the fixed " *
    "10 s schedule with 101 equally spaced samples.", (-1.0,1.0), (-1.0,1.0), (-1.0,1.0), (0.0,2.0), 10.0, 101)
limits_for(t::CoupledTaskDescription) = (x_initial_m=t.x_initial_bounds_m,
    v_initial_m_per_s=t.v_initial_bounds_m_per_s, drive_force_n=t.drive_force_bounds_n,
    drive_frequency_hz=t.drive_frequency_bounds_hz, duration_s=t.duration_s,
    cadence_s=t.duration_s/(t.sample_count-1), max_samples=t.sample_count)

function parse_action(::Type{CoupledOscillatorWorld}, content::AbstractString)
    obj = try JSON3.read(content) catch; throw(PolicyFailure(:malformed_response)) end
    obj isa JSON3.Object || throw(PolicyFailure(:malformed_response))
    names = ("x1_initial_m","x2_initial_m","v1_initial_m_per_s","v2_initial_m_per_s","drive_force_n","drive_frequency_hz")
    keys_seen = Set(String(k) for k in keys(obj))
    any(n -> !(n in keys_seen), names) && throw(PolicyFailure(:missing_required_field))
    keys_seen == Set(names) || throw(PolicyFailure(:malformed_response))
    vals = Float64[]
    for n in names
        v = obj[Symbol(n)]
        v isa Real && !(v isa Bool) || throw(PolicyFailure(:invalid_field_type))
        f = Float64(v); isfinite(f) || throw(PolicyFailure(:nonfinite_field)); push!(vals,f)
    end
    CoupledOscillatorAction(vals...)
end
function validate_environment_action(::CoupledOscillatorWorld, a::CoupledOscillatorAction)
    all(isfinite, (a.x1_initial_m,a.x2_initial_m,a.v1_initial_m_per_s,a.v2_initial_m_per_s,a.drive_force_n,a.drive_frequency_hz)) || return ValidationResult(false,:nonfinite_field)
    all(x -> -1 <= x <= 1, (a.x1_initial_m,a.x2_initial_m,a.v1_initial_m_per_s,a.v2_initial_m_per_s,a.drive_force_n)) || return ValidationResult(false,:out_of_bounds)
    0 <= a.drive_frequency_hz <= 2 || return ValidationResult(false,:out_of_bounds)
    (a.drive_force_n == 0 && a.drive_frequency_hz != 0 || a.drive_force_n != 0 && a.drive_frequency_hz <= 0) && return ValidationResult(false,:invalid_drive)
    ValidationResult(true,:accepted)
end

function execute_experiment(w::CoupledOscillatorWorld, a::CoupledOscillatorAction)
    validate_environment_action(w,a).valid || throw(ArgumentError("invalid experiment action"))
    tspan=(0.0,COUPLED_DURATION_S); times=collect(range(tspan...;length=COUPLED_SAMPLE_COUNT)); p=w.truth
    function rhs!(du,u,_,t)
        x1,x2,v1,v2=u
        forcing=a.drive_force_n*sin(2pi*a.drive_frequency_hz*t)
        du[1]=v1; du[2]=v2
        du[3]=(forcing-p.damping_c_n_s_per_m*v1-p.stiffness_k_n_per_m*x1-p.coupling_kc_n_per_m*(x1-x2))/COUPLED_MASS_1_KG
        du[4]=(-p.damping_c_n_s_per_m*v2-p.stiffness_k_n_per_m*x2-p.coupling_kc_n_per_m*(x2-x1))/COUPLED_MASS_2_KG
    end
    prob=ODEProblem(rhs!,[a.x1_initial_m,a.x2_initial_m,a.v1_initial_m_per_s,a.v2_initial_m_per_s],tspan)
    sol=solve(prob,Tsit5();saveat=times,reltol=COUPLED_REL_TOL,abstol=COUPLED_ABS_TOL,dense=false)
    states=sol.u
    CoupledCleanObservation(Tuple(times),Tuple(Float64(s[1]) for s in states),Tuple(Float64(s[2]) for s in states))
end
public_action(::CoupledOscillatorWorld,a::CoupledOscillatorAction)=a
public_observation(::CoupledOscillatorWorld,o::CoupledObservation)=o
function apply_environment_noise(::CoupledOscillatorWorld, clean::CoupledCleanObservation, ::CleanObservation, seed, index)
    seed >= 0 && index > 0 || throw(ArgumentError("invalid noise stream identity"))
    CoupledObservation(clean.time_s,clean.x1_m,clean.x2_m,0.0,"none",0.0)
end
function apply_environment_noise(::CoupledOscillatorWorld, clean::CoupledCleanObservation, noise::GaussianObservationNoise, seed, index)
    seed >= 0 && index > 0 || throw(ArgumentError("invalid noise stream identity"))
    channel_noise(channel) = begin
        stream=Int(mod(BigInt(seed)+BigInt(index)*0x9e3779b97f4a7c15+BigInt(channel)*0x632be59bd9b4e019,BigInt(typemax(Int))))
        rng=MersenneTwister(stream)
        Tuple(noise.sigma_m*randn(rng) for _ in clean.time_s)
    end
    n1,n2=channel_noise(1),channel_noise(2)
    CoupledObservation(clean.time_s,Tuple(x+n for (x,n) in zip(clean.x1_m,n1)),Tuple(x+n for (x,n) in zip(clean.x2_m,n2)),
        noise.sigma_m,"gaussian_additive",noise.sigma_m)
end

# Minimal baseline compatibility for this environment's native action/limits.
function next_action(p::RandomPolicy,s::PublicState{CoupledTaskDescription,L}) where {L}
    l=s.limits; draw(r)=r[1]+rand(p.rng)*(r[2]-r[1])
    driven=rand(p.rng)<p.driven_probability
    amp,freq=driven ? ((rand(p.rng)<0.5 ? -1.0 : 1.0),draw((0.05,2.0))) : (0.0,0.0)
    CoupledOscillatorAction(draw(l.x_initial_m),draw(l.x_initial_m),draw(l.v_initial_m_per_s),draw(l.v_initial_m_per_s),amp,freq)
end
function next_action(::FixedDesignPolicy,s::PublicState{CoupledTaskDescription,L}) where {L}
    design=(CoupledOscillatorAction(1,0,0,0,0,0),CoupledOscillatorAction(0,1,0,0,0,0),
        CoupledOscillatorAction(1,-1,0,0,0,0),CoupledOscillatorAction(0,0,0.5,-0.5,0,0))
    design[mod1(length(s.history)+1,length(design))]
end

export CoupledOscillatorWorld, CoupledTruth, CoupledMetadata, CoupledOscillatorAction,
    CoupledCleanObservation, CoupledObservation, CoupledTaskDescription,
    generate_coupled_world, COUPLED_ENVIRONMENT_VERSION, COUPLED_EVALUATOR_PROBE_CANDIDATES
