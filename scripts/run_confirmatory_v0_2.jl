module ConfirmatoryRunnerV02
include(joinpath(@__DIR__,"V02Lock.jl"))
using JSON3
const ROOT=normpath(joinpath(@__DIR__,".."))
const LOCK=joinpath(ROOT,"research","v0.2-prereg-1.lock.json")
export validate_before_start, main
function validate_before_start(lock=LOCK;root=ROOT)
    # This function runs before config load, artifact creation, or provider construction.
    checked=V02ProtocolLock.validate_lock(lock;root)
    cfg=JSON3.read(read(joinpath(root,checked.execution_config),String))
    output=joinpath(root,String(cfg.artifact_namespace))
    ispath(output)&&error("confirmatory output namespace already exists; refusing duplicate execution")
    checked
end
function main(args=ARGS)
    isempty(args)||error("confirmatory runner accepts no overrides; edit requires a new preregistration")
    validate_before_start()
    error("DAL-157 execution engine is not enabled in this DAL-156 workspace")
end
end
if abspath(PROGRAM_FILE)==@__FILE__
    ConfirmatoryRunnerV02.main()
end
