# Policy-independent deterministic comparison of the coupled evaluator forced probe.
using Falsify, LinearAlgebra, Statistics, JSON3
const SEEDS=collect(9560201:9560232)
const FREQUENCIES=(0.25,0.40,0.55,0.70,1.00,1.40)
const RANGES=((1.5,4.0),(0.3,2.0),(0.15,0.8))
function trace(world,f)
    o=execute_experiment(world,CoupledOscillatorAction(0,0,0,0,0.5,f))
    vcat(collect(o.x1_m),collect(o.x2_m))
end
rows=Any[]
for f in FREQUENCIES
    minima=Float64[]; maxima=Float64[]
    for seed in SEEDS
        w=generate_coupled_world(seed); y=trace(w,f); J=zeros(length(y),3)
        p=(w.truth.stiffness_k_n_per_m,w.truth.coupling_kc_n_per_m,w.truth.damping_c_n_s_per_m)
        for j in 1:3
            h=1e-4*(RANGES[j][2]-RANGES[j][1]); pm=collect(p); pp=collect(p);pm[j]-=h;pp[j]+=h
            wm=CoupledOscillatorWorld(CoupledTruth(pm...),w.provenance);wp=CoupledOscillatorWorld(CoupledTruth(pp...),w.provenance)
            J[:,j]=(trace(wp,f)-trace(wm,f))/(2h)*(RANGES[j][2]-RANGES[j][1])
        end
        sv=svdvals(J);push!(minima,sv[end]);push!(maxima,maximum(abs,y))
    end
    push!(rows,(frequency_hz=f,median_minimum_scaled_singular_value=median(minima),
        median_peak_displacement_m=median(maxima),maximum_peak_displacement_m=maximum(maxima)))
end
sort!(rows,by=x->-x.median_minimum_scaled_singular_value)
out=joinpath(@__DIR__,"..","results","pilot-v0.2","probe-diagnostics-v1.json")
mkpath(dirname(out));write(out,JSON3.write((designation="exploratory deterministic apparatus diagnostic; no policies",
    world_seeds=SEEDS,candidates=[(x1=0.0,x2=0.0,v1=0.0,v2=0.0,force_N=0.5,frequency_Hz=f) for f in FREQUENCIES],ranking=rows,selected=first(rows))))
println(JSON3.write(rows));println("wrote $out")
