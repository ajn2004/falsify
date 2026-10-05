module Falsify

using OrdinaryDiffEqTsit5: Tsit5
using Random: MersenneTwister, rand
using SciMLBase: ODEProblem, solve

export OscillatorConfig, OscillatorExperiment, CleanOscillatorObservation,
       OscillatorTaskDescription, OscillatorMetadata, OscillatorWorld,
       generate_world, observe, public_task, evaluator_truth, metadata

"""Numerical and sampling configuration. Defaults are part of V0 apparatus."""
struct OscillatorConfig
    final_time::Float64
    sample_count::Int
    reltol::Float64
    abstol::Float64
    function OscillatorConfig(final_time::Real=10.0, sample_count::Integer=101; reltol=1e-9, abstol=1e-11)
        final_time > 0 || throw(ArgumentError("final_time must be positive"))
        sample_count >= 2 || throw(ArgumentError("sample_count must be at least 2"))
        reltol > 0 && abstol > 0 || throw(ArgumentError("solver tolerances must be positive"))
        new(Float64(final_time), Int(sample_count), Float64(reltol), Float64(abstol))
    end
end

"""Environment-native intervention in SI units; drive acceleration is m/s²."""
Base.@kwdef struct OscillatorExperiment
    initial_displacement::Float64 = 1.0
    initial_velocity::Float64 = 0.0
    drive_acceleration_m_per_s2::Float64 = 0.0
    drive_frequency_hz::Float64 = 1.0
end

struct CleanOscillatorObservation
    times::Vector{Float64}
    displacement::Vector{Float64}
end

"""Only protocol-approved information; safe to provide to an experimental policy."""
struct OscillatorTaskDescription
    model_description::String
    final_time::Float64
    sample_count::Int
    displacement_bounds::Tuple{Float64,Float64}
    velocity_bounds::Tuple{Float64,Float64}
    drive_acceleration_bounds_m_per_s2::Tuple{Float64,Float64}
    drive_frequency_bounds_hz::Tuple{Float64,Float64}
end

struct OscillatorMetadata
    solver::String
    reltol::Float64
    abstol::Float64
    world_seed::Int
    package_version::VersionNumber
end

struct OscillatorTruth
    damping_ratio::Float64
    natural_frequency::Float64
end

"""Evaluator-owned world. Do not pass this object to a policy."""
struct OscillatorWorld
    truth::OscillatorTruth
    config::OscillatorConfig
    provenance::OscillatorMetadata
end

const ZETA_RANGE = (0.05, 0.40)
const OMEGA_RANGE = (0.80, 2.00)
const X0_RANGE = (-2.0, 2.0)
const V0_RANGE = (-2.0, 2.0)
const DRIVE_ACCELERATION_RANGE = (-1.0, 1.0)
const DRIVE_FREQUENCY_RANGE = (0.0, 3.0)

"""Generate truth using independent, explicit world-generation RNG state."""
function generate_world(seed::Integer; config::OscillatorConfig=OscillatorConfig())
    seed >= 0 || throw(ArgumentError("seed must be nonnegative"))
    rng = MersenneTwister(seed)
    truth = OscillatorTruth(
        ZETA_RANGE[1] + rand(rng) * (ZETA_RANGE[2] - ZETA_RANGE[1]),
        OMEGA_RANGE[1] + rand(rng) * (OMEGA_RANGE[2] - OMEGA_RANGE[1]),
    )
    OscillatorWorld(truth, config, OscillatorMetadata("Tsit5", config.reltol, config.abstol,
        Int(seed), something(Base.pkgversion(@__MODULE__), v"0.0.0")))
end

"""Return policy-visible task information, without seeds, truth, or solver internals."""
public_task(world::OscillatorWorld) = OscillatorTaskDescription(
    "x'' + 2ζω₀x' + ω₀²x = a_d*sin(2πf*t); displacement in meters, time in seconds, drive acceleration in m/s²",
    world.config.final_time, world.config.sample_count, X0_RANGE, V0_RANGE, DRIVE_ACCELERATION_RANGE, DRIVE_FREQUENCY_RANGE)

metadata(world::OscillatorWorld) = world.provenance
evaluator_truth(world::OscillatorWorld) = (damping_ratio=world.truth.damping_ratio,
    natural_frequency=world.truth.natural_frequency)

function validate(action::OscillatorExperiment)
    within(value, bounds) = isfinite(value) && bounds[1] <= value <= bounds[2]
    within(action.initial_displacement, X0_RANGE) || throw(ArgumentError("invalid experiment action"))
    within(action.initial_velocity, V0_RANGE) || throw(ArgumentError("invalid experiment action"))
    within(action.drive_acceleration_m_per_s2, DRIVE_ACCELERATION_RANGE) || throw(ArgumentError("invalid experiment action"))
    within(action.drive_frequency_hz, DRIVE_FREQUENCY_RANGE) || throw(ArgumentError("invalid experiment action"))
    nothing
end

"""Run one valid intervention and return the protocol-sampled clean displacement."""
function observe(world::OscillatorWorld, action::OscillatorExperiment)
    validate(action)
    zeta, omega0 = world.truth.damping_ratio, world.truth.natural_frequency
    forcing(t) = action.drive_acceleration_m_per_s2 * sin(2pi * action.drive_frequency_hz * t)
    function oscillator!(du, u, _, t)
        du[1] = u[2]
        du[2] = forcing(t) - 2zeta * omega0 * u[2] - omega0^2 * u[1]
    end
    times = collect(range(0.0, world.config.final_time; length=world.config.sample_count))
    problem = ODEProblem(oscillator!, [action.initial_displacement, action.initial_velocity],
        (0.0, world.config.final_time))
    solution = solve(problem, Tsit5(); saveat=times, reltol=world.config.reltol,
        abstol=world.config.abstol, dense=false)
    CleanOscillatorObservation(times, Float64[point[1] for point in solution.u])
end

end
