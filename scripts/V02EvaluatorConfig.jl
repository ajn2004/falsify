module V02EvaluatorConfigFile
using JSON3, SHA
using Falsify: V02EvaluatorConfig
export load_config, file_sha256
file_sha256(path)=bytes2hex(sha256(read(path)))
function load_config(path)
    x=JSON3.read(read(path,String))
    required=Set((:version,:coupled_k,:coupled_kc,:coupled_c,:coupled_forced_probe,
        :coupled_prediction_scale_m,:structural_zeta,:structural_omega,:structural_beta,
        :structural_probes,:structural_prediction_scale_m,:failure_penalty,:grid_points,
        :max_iterations,:tolerance))
    Set(keys(x))==required || throw(ArgumentError("evaluator config fields differ from the frozen schema"))
    V02EvaluatorConfig(version=String(x.version),coupled_k=Tuple(Float64.(x.coupled_k)),
        coupled_kc=Tuple(Float64.(x.coupled_kc)),coupled_c=Tuple(Float64.(x.coupled_c)),
        coupled_forced_probe=Tuple(Float64.(x.coupled_forced_probe)),
        coupled_prediction_scale_m=Float64(x.coupled_prediction_scale_m),
        structural_zeta=Tuple(Float64.(x.structural_zeta)),structural_omega=Tuple(Float64.(x.structural_omega)),
        structural_beta=Tuple(Float64.(x.structural_beta)),
        structural_probes=Tuple(Tuple(Float64.(p)) for p in x.structural_probes),
        structural_prediction_scale_m=Float64(x.structural_prediction_scale_m),
        failure_penalty=Float64(x.failure_penalty),grid_points=Int(x.grid_points),
        max_iterations=Int(x.max_iterations),tolerance=Float64(x.tolerance))
end
end
