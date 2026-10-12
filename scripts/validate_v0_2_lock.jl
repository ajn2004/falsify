include(joinpath(@__DIR__,"V02Lock.jl"))
lockpath=length(ARGS)==0 ? joinpath(@__DIR__,"..","research","v0.2-prereg-1.lock.json") : abspath(ARGS[1])
result=V02ProtocolLock.validate_lock(lockpath)
println("V0.2 protocol lock valid: $(result.protocol_id); $(result.checked_files) files checked")
