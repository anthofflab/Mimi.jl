using ExcelFiles
using Mimi
using Random
using Statistics
using Test

include("../../wip/load_empirical_dist.jl")

filename = joinpath(@__DIR__, "RB-ECS-distribution.xls")
d = load_empirical_dist(filename, "Sheet1!A2:A1001", "Sheet1!B2:B1001")

# Set the seed to get repeatable results (with some caveats...)
Random.seed!(1234567)

# Get the statistical outline of the distribution
q = quantile.(Ref(d), [0.01, 0.10, 0.25, 0.50, 0.75, 0.90, 0.99])

expected = [1.47, 1.92, 2.33, 3.01, 4.16, 5.85, 9.16]
# @info "quantiles: $q\n expected: $expected"

@test isapprox(q, expected, atol=0.01)


# Test that the EmpiricalDistribution gets saved as a SampleStore and values 
# get re-used across multiple scenarios

num_scenarios = 4
num_trials = 5
output_dir = "./out/"

results = zeros(num_scenarios, num_trials)

_values = collect(1:10)

# try providing probabilities and also default uniform distribution of probabilities
for _probs in [0.1 * ones(10), nothing]

    _probs = 0.1 * ones(10)

    sd = @defsim begin
        sampling(LHSData)
        test.p = EmpiricalDistribution(_values, _probs)
    end 

    @defcomp test begin
        p = Parameter(default = 5)
        function run_timestep(p, v, d, t) end
    end

    scenario_args = [
        :num => collect(1:num_scenarios)
    ]

    function scenario_func(sim_inst::SimulationInstance{T}, tup::Tuple) where T <: AbstractSimulationData
        nothing
    end

    function post_trial_func(sim_inst::SimulationInstance{T}, trialnum::Int, ntimesteps::Int, 
                            tup::Tuple)  where T <: AbstractSimulationData
        m, = sim_inst.models
        scenario_num, = tup
        results[scenario_num, trialnum] = m[:test, :p]
    end

    m = Model()
    set_dimension!(m, :time, 2000:2001)
    add_comp!(m, test)

    si = run(sd, m, num_trials;
        results_output_dir = output_dir,
        scenario_args = scenario_args,
        scenario_func = scenario_func, 
        post_trial_func = post_trial_func
    )

    for rv in values(si.sim_def.rvdict)
        @test rv.dist isa Mimi.SampleStore
    end

    for i = 1:num_scenarios
        @test results[i, :] == results[1, :]
    end

    rm(output_dir, recursive = true)

    si1 = run(sd, m, num_trials)
    trial1 = copy(collect(values(si1.sim_def.rvdict))[1].dist.values)

    for rv in values(si1.sim_def.rvdict)
        @test rv.dist isa Mimi.SampleStore
    end

    si2 = run(sd, m, num_trials)
    trial2 = copy(collect(values(si2.sim_def.rvdict))[1].dist.values)

    @test trial1!=trial2
end