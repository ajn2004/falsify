@testset "DAL-202 structural gate audit integrity" begin
    A = StructuralGateAudit
    function fixture()
        rows = Any[]
        for (seed, klass) in ((11,"linear"),(12,"duffing")), strategy in ("random","diverse_open_loop"),
                design in (strategy == "random" ? (1:3) : (1:1)), budget in (1,2), noise in 1:3
            selected = if klass == "linear"
                noise == 3 ? "undetermined" : "linear"
            elseif design == 1
                noise == 3 ? "undetermined" : "linear"
            else
                noise == 3 ? "undetermined" : "duffing"
            end
            push!(rows, (strategy, world_seed=seed, design_replicate=design, budget,
                truth_class=klass, noise_replicate=noise, selected_class=selected,
                fit_linear="success", fit_duffing="success", correct=(selected==klass),
                selected_prediction_rmse=0.01noise))
        end
        rows
    end
    manifest=(strategies=("random","diverse_open_loop"), world_seeds=(11,12),
        design_replicates=Dict("random"=>1:3,"diverse_open_loop"=>1:1),
        budgets=(1,2), noise_replicates=(1,2,3), class_counts=Dict("linear"=>1,"duffing"=>1))
    run(rows; kw...)=A.audit(rows; manifest..., kw...)
    rows = fixture()
    result = run(rows)
    random = only(filter(x->x.strategy=="random" && x.budget==1, result.summary))
    @test random.distinct_physical_worlds == 2
    @test random.design_replicates == 3
    @test random.world_design_groups == 6
    @test random.noise_replicates == 3
    @test random.class_conditional_confusion_world_design_groups["linear"]["linear"] == 3
    @test random.class_accuracy_by_physical_world[2].equal_world_mean_correct_design_fraction ≈ 2/3
    @test random.class_accuracy_by_physical_world[2].design_outcome_majority.correct_worlds == 1
    @test occursin("descriptive ensemble", random.class_accuracy_by_physical_world[2].design_outcome_majority.aggregation_level)
    @test random.class_accuracy_by_physical_world[2].world_cluster_bootstrap_95pct.seed != 0

    tied = deepcopy(rows)
    for i in eachindex(tied)
        r=tied[i]
        if r.strategy=="diverse_open_loop" && r.world_seed==12 && r.budget==1
            selected=r.noise_replicate==1 ? "linear" : r.noise_replicate==2 ? "duffing" : "undetermined"
            tied[i]=merge(r,(selected_class=selected,correct=(selected==r.truth_class),))
        end
    end
    tied_result=run(tied)
    tied_cell=only(filter(x->x.strategy=="diverse_open_loop"&&x.budget==1,tied_result.summary))
    @test tied_cell.class_conditional_confusion_world_design_groups["duffing"]["undetermined"]==1

    # Each deletion attacks one dimension of the declared Cartesian manifest.
    @test_throws ArgumentError run(filter(r->r.budget==1,rows))
    @test_throws ArgumentError run(filter(r->r.strategy=="random",rows))
    @test_throws ArgumentError run(filter(r->!(r.strategy=="random" && r.world_seed==11),rows))
    @test_throws ArgumentError run(filter(r->!(r.strategy=="random" && r.world_seed==11 && r.design_replicate==2),rows))
    @test_throws ArgumentError run(filter(r->!(r.strategy=="random" && r.world_seed==11 && r.design_replicate==1 && r.budget==1 && r.noise_replicate==3),rows))
    @test_throws ArgumentError run(filter(r->!(r.strategy=="random" && r.world_seed==11 && r.design_replicate==1 && r.budget==1 && r.noise_replicate==1),rows))
    @test_throws ArgumentError run([rows; first(rows)])
    @test_throws ArgumentError run([rows; merge(first(rows),(strategy="unexpected",))])
    @test_throws ArgumentError run([rows; merge(first(rows),(budget=99,))])
    @test_throws ArgumentError run([rows; merge(first(rows),(noise_replicate=4,))])
    @test_throws ArgumentError run([rows; merge(first(rows),(design_replicate=4,))])
    inconsistent = [r.world_seed==11 ? merge(r,(truth_class="duffing",correct=(r.selected_class=="duffing"),)) : r for r in rows]
    @test_throws ArgumentError run(inconsistent)

    failed = deepcopy(rows); failed[1] = merge(failed[1], (fit_duffing="iteration_limit",))
    failed_result = run(failed)
    failed_cell = only(filter(x->x.strategy=="random" && x.budget==1, failed_result.summary))
    @test failed_cell.nonconvergent_world_design_groups == 1
    @test failed_cell.nonconvergent_observation_rows == 1
    @test failed_cell.class_conditional_confusion_world_design_groups["linear"]["fit_failure"] == 1

    root = normpath(joinpath(@__DIR__, ".."))
    source = joinpath(root,"results","pilot-v0.2","structural-v3-gate-v1","diagnostic.json")
    expected = joinpath(root,"results","pilot-v0.2","structural-gate-audit-v1","diagnostic.json")
    first_audit = JSON3.write(A.audit_file(source))
    second_audit = JSON3.write(A.audit_file(source))
    @test first_audit == second_audit
    @test first_audit == read(expected,String)
    @test occursin(bytes2hex(sha256(read(source))), first_audit)
end
