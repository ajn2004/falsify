# Environment B: model-class identification with a class-neutral public interface.
@enum DuffingClass linear duffing

struct DuffingTruth
    model_class::DuffingClass
    zeta::Float64
    omega0::Float64
    beta::Float64
end

struct DuffingMetadata
    solver::String
    reltol::Float64
    abstol::Float64
    world_seed::Int
    package_version::VersionNumber
end

struct DuffingWorld <: AbstractEnvironment
    truth::DuffingTruth
    config::OscillatorConfig
    provenance::DuffingMetadata
end

struct CleanDuffingObservation <: AbstractPolicyObservation
    times::Vector{Float64}
    displacement::Vector{Float64}
end

const DUFFING_ZETA_RANGE = (0.08, 0.30)
const DUFFING_OMEGA_RANGE = (0.9, 1.8)
const DUFFING_BETA_RANGE = (0.15, 0.8)

"""Draw class, zeta, omega0, then beta (including for linear worlds).

The final beta draw is intentionally consumed in both classes. Thus each world
uses four ordered world-RNG draws and subsequent draws do not depend on class.
"""
function generate_duffing_world(seed::Integer; config::OscillatorConfig=OscillatorConfig())
    seed >= 0 || throw(ArgumentError("seed must be nonnegative"))
    config.final_time == 10.0 && config.sample_count == 101 ||
        throw(ArgumentError("V0.2 model-class schedule is fixed at 10 s and 101 samples"))
    rng = MersenneTwister(seed)
    klass = rand(rng, Bool) ? duffing : linear
    zeta = DUFFING_ZETA_RANGE[1] + rand(rng) * (DUFFING_ZETA_RANGE[2] - DUFFING_ZETA_RANGE[1])
    omega0 = DUFFING_OMEGA_RANGE[1] + rand(rng) * (DUFFING_OMEGA_RANGE[2] - DUFFING_OMEGA_RANGE[1])
    beta_draw = DUFFING_BETA_RANGE[1] + rand(rng) * (DUFFING_BETA_RANGE[2] - DUFFING_BETA_RANGE[1])
    truth = DuffingTruth(klass, zeta, omega0, klass == linear ? 0.0 : beta_draw)
    meta = DuffingMetadata("Tsit5", config.reltol, config.abstol, Int(seed),
        something(Base.pkgversion(@__MODULE__), v"0.0.0"))
    DuffingWorld(truth, config, meta)
end

metadata(world::DuffingWorld) = world.provenance
evaluator_truth(world::DuffingWorld) = (model_class=string(world.truth.model_class),
    zeta=world.truth.zeta, omega0=world.truth.omega0, beta=world.truth.beta)
environment_id(::DuffingWorld) = "linear_vs_duffing_v0_2"
environment_version(::DuffingWorld) = "1"
action_schema_version(::DuffingWorld) = "1"
observation_schema_version(::DuffingWorld) = "1"
policy_contract_profile(::DuffingWorld) = "scientist-v0-2-schema-driven-v1"
action_schema(::DuffingWorld) = legacy_action_schema()
parse_action(::Type{DuffingWorld}, text::AbstractString) = legacy_parse_action(text)

function public_task(world::DuffingWorld)
    description = """The hidden system is one of these two candidate hypotheses:
H_L: x'' + 2ζω₀ x' + ω₀²x = a sin(2πft)
H_D: x'' + 2ζω₀ x' + ω₀²x + βx³ = a sin(2πft)
Units: x in m, time in s, ζ dimensionless, ω₀ in rad/s, β in m^-2 s^-2, and a in m/s². Controls: initial displacement [-2,2] m; initial velocity [-2,2] m/s; drive acceleration [-1,1] m/s²; drive frequency [0,3] Hz. Zero drive requires zero frequency; nonzero drive requires positive frequency. Each experiment runs for 10 s with 101 equally spaced samples. Available observations are sampled displacement and declared measurement uncertainty. Choose experiments to distinguish the hypotheses."""
    OscillatorTaskDescription(description, world.config.final_time, world.config.sample_count,
        X0_RANGE, V0_RANGE, DRIVE_ACCELERATION_RANGE, DRIVE_FREQUENCY_RANGE)
end

function duffing_observe(world::DuffingWorld, action::ExperimentAction)
    validate_environment_action(world, action).valid || throw(ArgumentError("invalid experiment action"))
    truth = world.truth
    forcing(t) = action.drive_acceleration_m_per_s2 * sin(2pi * action.drive_frequency_hz * t)
    function rhs!(du, u, _, t)
        du[1] = u[2]
        du[2] = forcing(t) - 2truth.zeta*truth.omega0*u[2] - truth.omega0^2*u[1] - truth.beta*u[1]^3
    end
    times = collect(range(0.0, world.config.final_time; length=world.config.sample_count))
    problem = ODEProblem(rhs!, [action.initial_displacement_m, action.initial_velocity_m_per_s],
        (0.0, world.config.final_time))
    solution = solve(problem, Tsit5(); saveat=times, reltol=world.config.reltol,
        abstol=world.config.abstol, dense=false)
    CleanDuffingObservation(times, Float64[point[1] for point in solution.u])
end

function validate_environment_action(::DuffingWorld, action::ExperimentAction)
    _validate_oscillator_environment_action(action)
end

execute_experiment(world::DuffingWorld, action::ExperimentAction) = duffing_observe(world, action)
public_action(::DuffingWorld, action::ExperimentAction) = action
public_observation(::DuffingWorld, observation::Observation) = observation

function apply_environment_noise(world::DuffingWorld, clean::CleanDuffingObservation,
        ::CleanObservation, seed, index)
    seed >= 0 || throw(ArgumentError("noise seed must be nonnegative"))
    index > 0 || throw(ArgumentError("intervention index must be positive"))
    Observation(Tuple(Measurement(t, x, 0.0) for (t,x) in zip(clean.times, clean.displacement)), "none", 0.0)
end
function apply_environment_noise(world::DuffingWorld, clean::CleanDuffingObservation,
        noise::GaussianObservationNoise, seed, index)
    rng = MersenneTwister(_noise_stream_seed(seed, index))
    Observation(Tuple(Measurement(t, x + noise.sigma_m*randn(rng), noise.sigma_m)
        for (t,x) in zip(clean.times, clean.displacement)), "gaussian_additive", noise.sigma_m)
end

function environment_provenance(world::DuffingWorld)
    (; solver=world.provenance.solver, reltol=world.config.reltol, abstol=world.config.abstol,
       final_time_s=world.config.final_time, sample_count=world.config.sample_count,
       generation_order="class,zeta,omega0,beta_draw_always", noise_implementation=NOISE_IMPLEMENTATION_VERSION)
end
