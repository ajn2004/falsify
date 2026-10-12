include(joinpath(@__DIR__, "StructuralGateAudit.jl"))
using .StructuralGateAudit

root = normpath(joinpath(@__DIR__, ".."))
input = joinpath(root, "results", "pilot-v0.2", "structural-v3-gate-v1", "diagnostic.json")
output = joinpath(root, "results", "pilot-v0.2", "structural-gate-audit-v1", "diagnostic.json")
audit_file(input; output)
println("wrote ", output)
