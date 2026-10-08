# Exploratory deterministic apparatus checks only; not benchmark results.
using OrdinaryDiffEqTsit5: Tsit5
using SciMLBase: ODEProblem, solve
using Random: MersenneTwister, rand
using LinearAlgebra: Diagonal, I, eigen, norm, svdvals
using Statistics: median

const TIMES = collect(range(0.0, 10.0; length=101))
function trace(f!, initial)
    problem = ODEProblem(f!, initial, (first(TIMES), last(TIMES)))
    sol = solve(problem, Tsit5(); saveat=TIMES, reltol=1e-9, abstol=1e-11, dense=false)
    reduce(hcat, sol.u)'
end

function coupled(x10, x20; k=2.5, kc=1.0, c=0.35, v10=0.0, v20=0.0)
    m1, m2 = 1.0, 1.5
    function rhs!(du, u, _, t)
        du[1] = u[3]; du[2] = u[4]
        du[3] = -(c*u[3] + k*u[1] + kc*(u[1]-u[2]))/m1
        du[4] = -(c*u[4] + k*u[2] + kc*(u[2]-u[1]))/m2
    end
    trace(rhs!, [x10,x20,v10,v20])
end

const COUPLED_LOWER = [1.5, 0.3, 0.15]
const COUPLED_UPPER = [4.0, 2.0, 0.8]
const IDENT_DESIGNS = ((1.0, 0.0, 0.0, 0.0), (0.0, 1.0, 0.0, 0.0))
coupled_data(p, designs) = reduce(vcat, (vec(coupled(d[1],d[2];v10=d[3],v20=d[4],k=p[1],kc=p[2],c=p[3])[:,1:2]) for d in designs))

function coupled_jacobian(p, designs)
    scales = COUPLED_UPPER .- COUPLED_LOWER
    base = coupled_data(p, designs)
    J = zeros(length(base), 3)
    for j in 1:3
        δ = 1e-5 * scales[j]
        pp, pm = copy(p), copy(p)
        pp[j] += δ; pm[j] -= δ
        J[:,j] = (coupled_data(pp, designs) .- coupled_data(pm, designs)) ./ (2δ) .* scales[j]
    end
    J
end

function fit_coupled(y, designs, initial; maxiter=80)
    p = clamp.(copy(initial), COUPLED_LOWER, COUPLED_UPPER)
    loss = sum(abs2, coupled_data(p, designs) .- y)
    λ = 1e-4
    for _ in 1:maxiter
        r = coupled_data(p, designs) .- y
        J = coupled_jacobian(p, designs)
        step = (J'J + λ*I) \ (J'r)
        # `step` is in range-normalized coordinates because each Jacobian
        # column is scaled by its physical parameter range. Convert back to
        # physical units by multiplying by that range.
        candidate = clamp.(p .- step .* (COUPLED_UPPER .- COUPLED_LOWER), COUPLED_LOWER, COUPLED_UPPER)
        newloss = sum(abs2, coupled_data(candidate, designs) .- y)
        if newloss < loss
            p, loss, λ = candidate, newloss, max(λ/3, 1e-10)
            norm(step) < 1e-7 && break
        else
            λ = min(λ*10, 1e8)
        end
    end
    p, loss
end

function sensitivity_condition(p, designs)
    singular_values = svdvals(coupled_jacobian(p, designs))
    rank = count(>(maximum(singular_values)*1e-8), singular_values)
    rank, singular_values[1] / singular_values[end]
end

function nonlinear(x0; beta=0.5, zeta=0.15, omega=1.3)
    function rhs!(du, u, _, t)
        du[1] = u[2]
        du[2] = -2zeta*omega*u[2] - omega^2*u[1] - beta*u[1]^3
    end
    trace(rhs!, [x0,0.0])[:,1]
end

function fit_linear(y, action; grid=21)
    best = (Inf, NaN, NaN)
    for zeta in range(0.08, 0.30; length=grid), omega in range(0.9, 1.8; length=grid)
        pred = if action.drive_acceleration_m_per_s2 == 0
            nonlinear(action.initial_displacement_m; beta=0, zeta, omega)
        else
            # Driven candidate evaluated by the same ODE/sampling contract.
            function rhs!(du, u, _, t)
                du[1] = u[2]
                du[2] = action.drive_acceleration_m_per_s2 * sin(2pi*action.drive_frequency_hz*t) -
                    2zeta*omega*u[2] - omega^2*u[1]
            end
            trace(rhs!, [action.initial_displacement_m, action.initial_velocity_m_per_s])[:,1]
        end
        score = sum(abs2, pred .- y) / length(y)
        score < best[1] && (best = (score, zeta, omega))
    end
    best
end

function main()
    # Identical seeded construction and solver run must be exactly reproducible.
    a = coupled(1.0, 0.0); b = coupled(1.0, 0.0)
    @assert a == b && all(isfinite, a)
    x1 = coupled(1.0, 0.0); x2 = coupled(0.0, 1.0); anti = coupled(1.0, -1.0)
    @assert maximum(abs, x1[:,2]) > 1e-3
    @assert maximum(abs, x2[:,1]) > 1e-3
    @assert maximum(abs, anti[:,1] .- x1[:,1]) > 1e-2

    # Unequal known masses make the mode shapes depend on hidden k and kc.
    modal_shapes(k, kc) = eigen(Diagonal([1.0,1.5]) \ [k+kc -kc; -kc k+kc]).vectors
    @assert norm(modal_shapes(1.5,0.3) - modal_shapes(4.0,2.0)) > 1e-2
    @assert coupled(1.0, 0.0; kc=0.3) != coupled(1.0, 0.0; kc=2.0)
    rng1, rng2 = MersenneTwister(149), MersenneTwister(149)
    draws1 = [(1.5 + 2.5rand(rng1), 0.3 + 1.7rand(rng1), 0.15 + 0.65rand(rng1)) for _ in 1:64]
    draws2 = [(1.5 + 2.5rand(rng2), 0.3 + 1.7rand(rng2), 0.15 + 0.65rand(rng2)) for _ in 1:64]
    @assert draws1 == draws2
    @assert all(all(isfinite, coupled(0.7, -0.4; k, kc, c)) for (k,kc,c) in draws1)

    # Noiseless deterministic recovery and scaled sensitivity screen over 16
    # representative truths. Multistart fitting is not a noisy pilot result.
    fit_starts = ([2.75,1.15,0.475], [3.8,0.45,0.7], [1.7,1.8,0.2])
    cond_single, cond_two = Float64[], Float64[]
    for (k,kc,c) in draws1[1:16]
        truth = [k,kc,c]
        for (design_index, designs) in enumerate((IDENT_DESIGNS[1:1], IDENT_DESIGNS))
            y = coupled_data(truth, designs)
            rank, condition = sensitivity_condition(truth, designs)
            @assert rank == 3 && isfinite(condition)
            design_index == 1 ? push!(cond_single, condition) : push!(cond_two, condition)
            for start in fit_starts
                estimate, residual = fit_coupled(y, designs, start)
                @assert residual < 1e-3 "fit failed for truth=$truth start=$start designs=$design_index estimate=$estimate residual=$residual"
                @assert maximum(abs.((estimate .- truth) ./ (COUPLED_UPPER .- COUPLED_LOWER))) < 1e-2
            end
        end
    end

    # At small amplitude the cubic contribution scales as x^3; high amplitude
    # must expose a larger departure from the same linear parameterization.
    low_delta = sqrt(sum(abs2, nonlinear(0.2) .- nonlinear(0.2; beta=0.0))/length(TIMES))
    high_delta = sqrt(sum(abs2, nonlinear(1.5) .- nonlinear(1.5; beta=0.0))/length(TIMES))
    @assert isfinite(low_delta) && isfinite(high_delta) && high_delta > 20low_delta
    @assert all(isfinite, nonlinear(2.0))

    # Structural ambiguity is checked against a refitted linear candidate, not
    # merely a same-parameter trajectory comparison. The low-amplitude case
    # should be much closer than the high-amplitude case at this illustrative
    # truth. A grid check is exploratory and makes no class-accuracy claim.
    low_action = (initial_displacement_m=0.2, initial_velocity_m_per_s=0.0,
        drive_acceleration_m_per_s2=0.0, drive_frequency_hz=0.0)
    high_action = merge(low_action, (initial_displacement_m=1.5,))
    low_y, high_y = nonlinear(0.2), nonlinear(1.5)
    low_fit = fit_linear(low_y, low_action)
    high_fit = fit_linear(high_y, high_action)
    low_refit_rmse, high_refit_rmse = sqrt(low_fit[1]), sqrt(high_fit[1])
    @assert low_refit_rmse < high_refit_rmse
    @assert low_refit_rmse < 0.01 # illustrative near-ambiguity scale, not a threshold

    # Public structural schema allowlist: no class/truth/seed-bearing keys.
    public_action_keys = Set((:initial_displacement_m, :initial_velocity_m_per_s,
        :drive_acceleration_m_per_s2, :drive_frequency_hz))
    public_observation_keys = Set((:time_s, :displacement_m, :uncertainty_m))
    @assert !any(k -> occursin("class", String(k)) || occursin("truth", String(k)) || occursin("seed", String(k)), public_action_keys)
    @assert !any(k -> occursin("class", String(k)) || occursin("truth", String(k)) || occursin("seed", String(k)), public_observation_keys)
    println("V0.2 DESIGN/PILOT ONLY (not confirmatory): coupled finite/repeatable across 64 fixed-seed truths; 16 truths pass noiseless multistart recovery and full-rank scaled sensitivity checks.")
    println("Coupled scaled Jacobian condition numbers (single vs two predeclared starts), median: $(median(cond_single)) vs $(median(cond_two)).")
    println("Duffing-vs-linear same-parameter RMS departures: low amplitude = $low_delta m; high amplitude = $high_delta m; ratio = $(high_delta/low_delta).")
    println("After bounded linear nuisance refit (illustrative noiseless unforced cases): low-amplitude residual RMSE = $low_refit_rmse m; high-amplitude residual RMSE = $high_refit_rmse m; fitted low-case zeta/omega = $(low_fit[2:3]).")
    println("Public action/measurement key allowlist contains no class, truth, or seed fields.")
end

main()
