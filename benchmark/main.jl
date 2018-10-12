using PkgBenchmark

#function to compare the package benchmark suite performance at the target git id
#at the target and the baeline git id (eg. branch, commit, etc.)
filepath = "/Users/lisarennels/.julia/v0.6/Mimi/benchmark/judge_results.md"

function benchmarkMimi(target::String, baseline::String; filepath::String = filepath)

    #the default parameter for 
    results = judge("Mimi", target, baseline)

    #gather the results in order to print a short summmary of the comparison
    trial_judgement = collect(PkgBenchmark.benchmarkgroup(results))
    target_results_nums = collect(PkgBenchmark.benchmarkgroup(PkgBenchmark.target_result(results)))
    baseline_results_nums = collect(PkgBenchmark.benchmarkgroup(PkgBenchmark.baseline_result(results)))
    
    println("Results Summary: ")
    for i = 1:length(trial_judgement)
        println(trial_judgement[i]...)
        println("Min for Target: ", target_results_nums[i]...)
        println("Min for Baseline: ", baseline_results_nums[i]...)
        println("")
    end

    #print results file
    export_markdown(string(filepath), results)

    return results
end

# # Temporary test
# trials = []
# targets = []
# baselines = []
# b ="benchmark-branch1"
# for i = 1:10
#     results = judge("Mimi", b, b);
#     trial_judgement = collect(PkgBenchmark.benchmarkgroup(results))
#     target_results_nums = collect(PkgBenchmark.benchmarkgroup(PkgBenchmark.target_result(results)))
#     baseline_results_nums = collect(PkgBenchmark.benchmarkgroup(PkgBenchmark.baseline_result(results)))

#     push!(trials, trial_judgement)
#     push!(targets, target_results_nums)
#     push!(baselines, baseline_results_nums)
# end