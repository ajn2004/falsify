include(joinpath(@__DIR__,"V02SeedAudit.jl"))
length(ARGS)==1||error("usage: julia --project=. scripts/check_v0_2_seed_separation.jl CONFIRMATORY-SEEDS.json")
result=V02SeedAudit.audit_manifest(abspath(ARGS[1]))
println("confirmatory/pilot seed audit passed: ",result)
