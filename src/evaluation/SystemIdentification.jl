module SystemIdentification

using SciMLBase: ODEProblem, solve
using OrdinaryDiffEqTsit5: Tsit5
import ..Falsify: ExperimentAction, OscillatorTruth, OscillatorWorld, OscillatorConfig,
    OscillatorMetadata, OscillatorExperiment, observe

export FitResult, fit_oscillator, predict_trace

struct FitResult
    status::Symbol
    zeta::Union{Nothing,Float64}
    omega0::Union{Nothing,Float64}
    objective::Union{Nothing,Float64}
    evaluations::Int
end

const ZETA_BOUNDS = (0.05, 0.40)
const OMEGA_BOUNDS = (0.80, 2.00)

function _trace(action::ExperimentAction, times, zeta, omega)
    forcing(t) = action.drive_acceleration_m_per_s2 * sin(2pi * action.drive_frequency_hz * t)
    function oscillator!(du, u, _, t)
        du[1] = u[2]
        du[2] = forcing(t) - 2zeta * omega * u[2] - omega^2 * u[1]
    end
    problem = ODEProblem(oscillator!, [action.initial_displacement_m, action.initial_velocity_m_per_s],
        (first(times), last(times)))
    solution = solve(problem, Tsit5(); saveat=times, reltol=1e-9, abstol=1e-11, dense=false)
    Float64[p[1] for p in solution.u]
end

function _evidence(pairs)
    data = Tuple{ExperimentAction,Vector{Float64},Vector{Float64}}[]
    for (action, observation) in pairs
        times = Float64[m.time_s for m in observation.measurements]
        values = Float64[m.displacement_m for m in observation.measurements]
        length(times) == length(values) >= 3 || continue
        all(isfinite, times) && all(isfinite, values) || continue
        issorted(times) || continue
        push!(data, (action, times, values))
    end
    data
end

"""Deterministic bounded least-squares fit with coarse-grid initialization and pattern refinement."""
function fit_oscillator(pairs; max_iterations::Int=160)
    data = _evidence(pairs)
    isempty(data) && return FitResult(:insufficient_evidence, nothing, nothing, nothing, 0)
    evaluations = Ref(0)
    function objective(z, w)
        evaluations[] += 1
        total = 0.0; n = 0
        try
            for (action, times, y) in data
                predicted = _trace(action, times, z, w)
                length(predicted) == length(y) || return Inf
                total += sum(abs2, predicted .- y); n += length(y)
            end
        catch
            return Inf
        end
        total / n
    end
    # Fixed 15×15 lattice is the sole initialization; ties resolve by iteration order.
    best = (Inf, 0.225, 1.4)
    for z in range(ZETA_BOUNDS...; length=15), w in range(OMEGA_BOUNDS...; length=15)
        value = objective(z, w)
        value < best[1] && (best = (value, z, w))
    end
    isfinite(best[1]) || return FitResult(:optimizer_failed, nothing, nothing, nothing, evaluations[])
    value, z, w = best
    dz = (ZETA_BOUNDS[2]-ZETA_BOUNDS[1])/14
    dw = (OMEGA_BOUNDS[2]-OMEGA_BOUNDS[1])/14
    for _ in 1:max_iterations
        improved = false
        for (cz, cw) in ((-dz,0.0),(dz,0.0),(0.0,-dw),(0.0,dw),(-dz,-dw),(-dz,dw),(dz,-dw),(dz,dw))
            nz = clamp(z+cz, ZETA_BOUNDS...); nw = clamp(w+cw, OMEGA_BOUNDS...)
            candidate = objective(nz,nw)
            if candidate < value
                value,z,w = candidate,nz,nw; improved = true
            end
        end
        if !improved
            dz *= 0.5; dw *= 0.5
            max(dz,dw) < 1e-8 && break
        end
    end
    FitResult(:success, z, w, value, evaluations[])
end

function predict_trace(action::ExperimentAction, times, zeta, omega)
    _trace(action, times, zeta, omega)
end

end
