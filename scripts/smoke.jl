using Falsify
using OrdinaryDiffEqTsit5
using Random
using SciMLBase
using TOML

const ROOT = normpath(joinpath(@__DIR__, ".."))
const CONFIG_PATH = joinpath(ROOT, "configs", "smoke.toml")
const RESULT_DIR = joinpath(ROOT, "results", "raw")

config = TOML.parsefile(CONFIG_PATH)
initial_value = Float64(config["initial_value"])
decay_rate = Float64(config["decay_rate"])
final_time = Float64(config["final_time"])
sample_count = Int(config["sample_count"])

decay!(du, u, p, t) = (du[1] = -p * u[1])
problem = ODEProblem(decay!, [initial_value], (0.0, final_time), decay_rate)
solution = solve(problem, Tsit5(); saveat=range(0.0, final_time; length=sample_count))

# Independent seeded noise exists only to demonstrate explicit RNG ownership.
rng = MersenneTwister(Int(config["noise_seed"]))
noise_scale = Float64(config["noise_scale"])
noisy_values = [value + noise_scale * randn(rng) for value in solution[1, :]]

result = Dict(
    "schema_version" => 1,
    "package_version" => string(Base.pkgversion(Falsify)),
    "julia_version" => string(VERSION),
    "config" => config,
    "times" => collect(solution.t),
    "clean_values" => collect(solution[1, :]),
    "noisy_values" => noisy_values,
)

mkpath(RESULT_DIR)
result_path = joinpath(RESULT_DIR, "bootstrap-smoke.toml")
open(result_path, "w") do io
    TOML.print(io, result)
end

println("Falsify $(Base.pkgversion(Falsify)) smoke calculation completed.")
println("Wrote $(relpath(result_path, ROOT))")
