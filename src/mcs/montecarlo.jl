using IterTools
import IteratorInterfaceExtensions
import TableTraits
using Random
using ProgressMeter
using Serialization
using CSVFiles
using FileIO

function print_nonempty(name, vector)
    if length(vector) > 0
        println("  $name:")
        for obj in vector
            println("    ", obj)
        end
    end
end

function Base.show(io::IO, sim_def::SimulationDef{T}) where T <: AbstractSimulationData
    println("SimulationDef{$T}")
    
    println("  rvdict:")
    for (key, value) in sim_def.rvdict
        println("    $key: $(typeof(value))")
    end

    print_nonempty("translist", sim_def.translist)
    print_nonempty("savelist",  sim_def.savelist)
    println("  nt_type: $(sim_def.nt_type)")

    Base.show(io, sim_def.data)  # note: data::T
end

function Base.show(io::IO, sim_inst::SimulationInstance{T}) where T <: AbstractSimulationData
    println("SimulationInstance{$T}")
    print_nonempty("translist for model params", sim_inst.translist_modelparams)
    
    Base.show(io, sim_inst.sim_def)

    println("  trials: $(sim_inst.trials)")
    println("  current_trial: $(sim_inst.current_trial)")
    sim_inst.current_trial > 0 && println("  current_data: $(sim_inst.current_data)")

    println("  $(length(sim_inst.models)) models")
    println("  $(length(sim_inst.results)) results dicts")    
end

function Base.show(obj::T) where T <: AbstractSimulationData
    nothing
end

"""
    _store_param_results(m::AbstractModel, datum_key::Tuple{Symbol, Symbol}, 
                        trialnum::Int, scen_name::Union{Nothing, String}, 
                        results::Dict{Tuple, DataFrame})

Store `results` for a single parameter `datum_key` in model `m` and return the 
dataframe for this particular `trial_num`/`scen_name` combination.
"""
function _store_param_results(m::AbstractModel, datum_key::Tuple{Symbol, Symbol}, 
                            trialnum::Int, scen_name::Union{Nothing, String}, 
                            results::Dict{Tuple, DataFrame})
    @debug "\nStoring trial results for $datum_key"

    (comp_name, datum_name) = datum_key
    dims = dim_names(m, comp_name, datum_name)
    has_scen = ! (scen_name === nothing)

    if length(dims) == 0        # scalar value
        value = m[comp_name, datum_name]
        # println("Scalar: $value")

        if haskey(results, datum_key)
            results_df = results[datum_key]
        else        
            cols = [[], []]
            names = [datum_name, :trialnum]
            if has_scen
                push!(cols, [])
                push!(names, :scen)
            end
            results_df = DataFrame(cols, names)
            results[datum_key] = results_df
        end

        trial_df = DataFrame(datum_name => value, :trialnum => trialnum)
        has_scen ? trial_df[!, :scen] .= scen_name : nothing
        append!(results_df, trial_df) 
        # println("results_df: $results_df")

    else
        trial_df = getdataframe(m, comp_name, datum_name)
        trial_df[!, :trialnum] .= trialnum
        has_scen ? trial_df[!, :scen] .= scen_name : nothing
        # println("size of trial_df: $(size(trial_df))")

        if haskey(results, datum_key)
            results_df = results[datum_key]
            # println("Appending trial_df $(size(trial_df)) to results_df $(size(results_df))")
            append!(results_df, trial_df)
        else
            # println("Setting results[$datum_key] = trial_df $(size(trial_df))")
            results[datum_key] = trial_df
        end
    end

    return trial_df
end

"""
    _store_trial_results(sim_inst::SimulationInstance{T}, trialnum::Int, 
                        scen_name::Union{Nothing, String}, output_dir::Union{Nothing, String}, 
                        streams::Dict{String, CSVFiles.CSVFileSaveStream{IOStream}}) where T <: AbstractSimulationData

Save the stored simulation results ` from trial `trialnum` and scenario `scen_name`
to files in the directory `output_dir`
"""
function _store_trial_results(sim_inst::SimulationInstance{T}, trialnum::Int, 
                                scen_name::Union{Nothing, String}, output_dir::Union{Nothing, String}, 
                                streams::Dict{String, CSVFiles.CSVFileSaveStream{IOStream}}) where T <: AbstractSimulationData
    savelist = sim_inst.sim_def.savelist

    model_index = 1
    for (m, results) in zip(sim_inst.models, sim_inst.results)
        for datum_key in savelist
            trial_df = _store_param_results(m, datum_key, trialnum, scen_name, results)
            if output_dir !== nothing

                # get sub_dir, which is different from output_dir if there are multiple models
                if (length(sim_inst.results) > 1)
                    sub_dir = joinpath(output_dir, "model_$(model_index)")
                else
                    sub_dir = output_dir   
                end      
                mkpath(sub_dir, mode=0o750) 

                # get filtered trial_df, which is different from trial_df if there are multiple scenarios
                if scen_name !== nothing
                    trial_df_filtered = filter(row -> row[:scen] .== scen_name, trial_df)[:, 1:end-1] # remove scen field
                else
                    trial_df_filtered = trial_df
                end

                datum_name = join(map(string, datum_key), "_")
                _save_trial_results(trial_df_filtered, datum_name, sub_dir, streams)
            end
        end
        model_index += 1
    end
end

"""
    _save_trial_results(trial_df::DataFrame, datum_name::String, output_dir::String, 
                        streams::Dict{String, CSVFiles.CSVFileSaveStream{IOStream}})

Save the stored simulation results in `trial_df` from trial `trialnum` to files 
in the directory `output_dir`
"""
function _save_trial_results(trial_df::DataFrame, datum_name::String, output_dir::AbstractString, streams::Dict{String, CSVFiles.CSVFileSaveStream{IOStream}}) where T <: AbstractSimulationData
    filename = joinpath(output_dir, "$datum_name.csv")
    if haskey(streams, filename)
        write(streams[filename], trial_df)
    else
        streams[filename] = savestreaming(filename, trial_df)
    end
end

"""
    save_trial_inputs(sim_inst::SimulationInstance, filename::String)

Save the trial inputs for `sim_inst` to `filename`.
"""
function save_trial_inputs(sim_inst::SimulationInstance, filename::String)
    mkpath(dirname(filename), mode=0o750)   # ensure that the specified path exists
    save(filename, sim_inst)
    return nothing
end

# TBD: Modify lhs() to return an array of SampleStore{T} instances?
"""
    get_trial(sim_inst::SimulationInstance, trialnum::Int)

Return a NamedTuple with the data for next trial. Note that the `trialnum`
parameter is used only to support a 1-deep data cache that allows this
function to be called successively with the same `trialnum` to retrieve
the same NamedTuple. If `trialnum` does not match the current trial number,
the argument is ignored.
"""
function get_trial(sim_inst::SimulationInstance, trialnum::Int)

    if sim_inst.current_trial == trialnum
        return sim_inst.current_data
    end

    sim_def = sim_inst.sim_def

    vals = [rand(rv.dist) for rv in values(sim_def.rvdict)]
    sim_inst.current_data = sim_def.nt_type((vals...,))
    sim_inst.current_trial = trialnum
    
    return sim_inst.current_data
end

"""
    generate_trials!(sim_inst::SimulationInstance{T}, samples::Int; filename::Union{String, Nothing}=nothing)

Generate trials for the given `SimulationInstance` using the defined `samplesize.
Call this before running the sim to pre-generate data to be used by all scenarios. 
Also saves inputs if a filename is given.
"""
function generate_trials!(sim_inst::SimulationInstance{T}, samplesize::Int;
                        filename::Union{String, Nothing}=nothing) where T <: AbstractSimulationData
    sample!(sim_inst, samplesize)

    # TBD: If user asks for trial data to be saved, generate it up-front, or 
    # open a file that can be written to for each trialnum/scenario set?
    if filename != nothing
        save_trial_inputs(sim_inst, filename)
    end
end

function sample!(sim_inst::MonteCarloSimulationInstance, samplesize::Int)
    sim_inst.trials = samplesize
    rand!(sim_inst)
end

"""
    Random.rand!(sim_inst::SimulationInstance{T})

Replace all RVs originally of type Distribution with SampleStores with 
values drawn from that original distribution.
"""
function Random.rand!(sim_inst::SimulationInstance{T}) where T <: AbstractSimulationData
    sim_def = sim_inst.sim_def
    rvdict = sim_def.rvdict
    trials = sim_inst.trials

    for rv in values(sim_def.rvdict)
        # use underlying distribution, if known
        orig_dist = (rv.dist isa SampleStore ? rv.dist.dist : rv.dist)
        dist = (orig_dist === nothing ? rv.dist : orig_dist)
        values = rand(dist, trials)
        rvdict[rv.name] = RandomVariable(rv.name, SampleStore(values, orig_dist))
    end
end

"""
    _copy_sim_params(sim_inst::SimulationInstance{T})

Copy the parameters that are perturbed so we can restore them after each trial. This
is necessary when we are applying distributions by adding or multiplying original values.
"""
function _copy_sim_params(sim_inst::SimulationInstance{T}) where T <: AbstractSimulationData

    # If there is a MarginalModel, need to copy the params for both the base and marginal modeldefs separately
    flat_model_list = _get_flat_model_list(sim_inst)
    param_vec = Vector{Dict{Symbol, ModelParameter}}(undef, length(flat_model_list))

    for (i, m) in enumerate(flat_model_list)
        md = modelinstance_def(m)
        param_vec[i] = Dict{Symbol, ModelParameter}(trans.paramnames[i] => copy(model_param(md, trans.paramnames[i])) for trans in sim_inst.translist_modelparams)
    end

    return param_vec
end

function _restore_sim_params!(sim_inst::SimulationInstance{T}, 
                              param_vec::Vector{Dict{Symbol, ModelParameter}}) where T <: AbstractSimulationData
    
    # Need to flatten the list of models so that if there is a MarginalModel,
    # both its base and marginal models will have their separate params restored
    flat_model_list = _get_flat_model_list(sim_inst)

    for (i, m) in enumerate(flat_model_list)
        params = param_vec[i]
        md = m.mi.md
        for trans in sim_inst.translist_modelparams
            name = trans.paramnames[i]
            param = params[name]
            _restore_param!(param, name, md, i, trans)
        end
    end

    return nothing
end

function _restore_param!(param::ScalarModelParameter{T}, name::Symbol, md::ModelDef, i::Int, trans::TransformSpec_ModelParams) where T
    md_param = model_param(md, name)
    md_param.value = param.value
end

function _restore_param!(param::ArrayModelParameter{T}, name::Symbol, md::ModelDef, i::Int, trans::TransformSpec_ModelParams) where T
    md_param = model_param(md, name)
    indices = _param_indices(param, md, i, trans)
    md_param.values[indices...] = param.values[indices...]
end

function _param_indices(param::ArrayModelParameter{T}, md::ModelDef, i::Int, trans::TransformSpec_ModelParams) where T
    pdims = dim_names(param)   # returns [] for scalar parameters
    num_pdims = length(pdims)

    tdims  = trans.dims
    num_dims = length(tdims) 

    # special case for handling reshaped data where a single draw returns a matrix of values
    if num_dims == 0
        indices = repeat([Colon()], num_pdims)
        return indices
    end

    if num_pdims != num_dims
        pname = trans.paramnames[i]
        error("Dimension mismatch: model parameter :$pname has $num_pdims dimensions ($pdims); Sim has $num_dims")
    end

    indices = Vector()
    for (dim_name, dim_values) in zip(pdims, tdims)
        dim = dimension(md, dim_name)
        dim_indices = dim[dim_values]
        dim_name == :time ? dim_indices = TimestepIndex.(dim_indices) : nothing
        push!(indices, dim_indices)
    end

    return indices
end

function _perturb_param!(param::ScalarModelParameter{T}, md::ModelDef, i::Int, trans::TransformSpec_ModelParams, rvalue::Number) where T
    op = trans.op

    if op == :(=)
        param.value = T(rvalue)

    elseif op == :(*=)
        param.value *= rvalue

    else
        param.value += rvalue
    end
end

# rvalue is an Array so we expect the dims to match and don't need to worry about
# broadcasting
function _perturb_param!(param::ArrayModelParameter{T}, md::ModelDef, i::Int,
    trans::TransformSpec_ModelParams, rvalue::Array{<: Number, N}) where {T, N}
    
    op = trans.op
    pvalue = value(param)
    indices = _param_indices(param, md, i, trans)

    if op == :(=)
        pvalue[indices...] = rvalue

    elseif op == :(*=)
        pvalue[indices...] *= rvalue

    else
        pvalue[indices...] += rvalue

    end
end

# rvalue is a Number so we might need to deal with broadcasting
function _perturb_param!(param::ArrayModelParameter{T}, md::ModelDef, i::Int,
                         trans::TransformSpec_ModelParams, rvalue::Number) where {T, N}
    op = trans.op
    pvalue = value(param)
    indices = _param_indices(param, md, i, trans)

    if op == :(=)
        
        # first we check for a time index
        ti = get_time_index_position(param)

        # If there is no time index we have all methods needed to broadcast normally
        if isnothing(ti)
            broadcast_flag = sum(map(x -> length(x) > 1, indices)) > 0
            broadcast_flag ? pvalue[indices...] .= rvalue : pvalue[indices...] = rvalue
        
        else
            indices1, ts, indices2 = split_indices(indices, ti)
            non_ts_indices = [indices1..., indices2...]
            broadcast_flag = isempty(non_ts_indices) ? false : sum(map(x -> length(x) > 1, non_ts_indices)) > 0
            
            # Loop over the Array of TimestepIndex 
            if isa(ts, Array) 
                for el in ts
                    broadcast_flag ? pvalue[indices1..., el, indices2...] .= rvalue : pvalue[indices1..., el, indices2...] = rvalue
                end

            # The time is just a single TimestepIndex and we can proceed with broadcast 
            else     
                broadcast_flag ? pvalue[indices...] .= rvalue : pvalue[indices...] = rvalue
            end
        end

    elseif op == :(*=)
        pvalue[indices...] *= rvalue

    else 
        pvalue[indices...] += rvalue
    end
end

"""
    _perturb_params!(sim_inst::SimulationInstance{T}, trialnum::Int)

Modify the stochastic parameters for all models in `sim_inst`, using the 
values drawn for trial `trialnum`.
"""
function _perturb_params!(sim_inst::SimulationInstance{T}, trialnum::Int) where T <: AbstractSimulationData
    if trialnum > sim_inst.trials
        error("Attempted to run trial $trialnum, but only $(sim_inst.trials) trials are defined")
    end

    trialdata = get_trial(sim_inst, trialnum)

    # If it's a MarginalModel, need to perturb the params in both the base and marginal modeldefs
    flat_model_list = _get_flat_model_list(sim_inst)
    for (i, m) in enumerate(flat_model_list)
        for trans in sim_inst.translist_modelparams       
            param = model_param(m.mi.md, trans.paramnames[i])
            rvalue = getfield(trialdata, trans.rvname)
            _perturb_param!(param, m.mi.md, i, trans, rvalue)
        end
    end
    return nothing
end

function _reset_rvs!(sim_def::SimulationDef{T}) where T <: AbstractSimulationData
    for rv in values(sim_def.rvdict)
        if rv.dist isa SampleStore
            reset(rv.dist)
        end
    end
end

"""
    _reset_results!(sim_inst::SimulationInstance{T})

Reset all simulation results storage to a vector of empty dicts
"""
function _reset_results!(sim_inst::SimulationInstance{T}) where T <: AbstractSimulationData
    sim_inst.results = [Dict{Tuple, DataFrame}() for m in sim_inst.models]
end

# Append a string representation of the tuple args to the given directory name
function _compute_output_dir(orig_output_dir, tup)
    if orig_output_dir === nothing
        output_dir = nothing
    else
        output_dir = joinpath(orig_output_dir, join(map(string, tup), "_"))
        mkpath(output_dir, mode=0o750)
    end
    return output_dir
end

"""
    Base.run(sim_def::SimulationDef{T}, 
            models::Union{Vector{M}, AbstractModel}, 
            samplesize::Int;
            ntimesteps::Int=typemax(Int), 
            trials_output_filename::Union{Nothing, AbstractString}=nothing, 
            results_output_dir::Union{Nothing, AbstractString}=nothing, 
            pre_trial_func::Union{Nothing, Function}=nothing, 
            post_trial_func::Union{Nothing, Function}=nothing,
            scenario_func::Union{Nothing, Function}=nothing,
            scenario_placement::ScenarioLoopPlacement=OUTER,
            scenario_args=nothing,
            results_in_memory::Bool=true) where {T <: AbstractSimulationData, M <: AbstractModel}

Run the simulation definition `sim_def` for the `models` using `samplesize` samples.

Optionally run the `models` for `ntimesteps`, if specified, 
else to the maximum defined time period. Note that trial data are applied to all the 
associated models even when running only a portion of them.   

If provided, the generated trials and results will be saved in the indicated 
`trials_output_filename` and `results_output_dir` respectively. If `results_in_memory` is set
to false, then results will be cleared from memory and only stored in the
`results_output_dir`.

If `pre_trial_func` or `post_trial_func` are defined, the designated functions are called 
just before or after (respectively) running a trial. The functions must have the signature:

    fn(sim_inst::SimulationInstance, trialnum::Int, ntimesteps::Int, tup::Tuple)

where `tup` is a tuple of scenario arguments representing one element in the cross-product
of all scenario value vectors. In situations in which you want the simulation loop to run only
some of the models, the remainder of the runs can be handled using a `pre_trial_func` or
`post_trial_func`.

If provided, `scenario_args` must be a `Vector{Pair}`, where each `Pair` is a symbol and a 
`Vector` of arbitrary values that will be meaningful to `scenario_func`, which must have
the signature:

    scenario_func(sim_inst::SimulationInstance, tup::Tuple)

By default, the scenario loop encloses the simulation loop, but the scenario loop can be
placed inside the simulation loop by specifying `scenario_placement=INNER`. When `INNER` 
is specified, the `scenario_func` is called after any `pre_trial_func` but before the model
is run.

Returns the type `SimulationInstance` that contains a copy of the original `SimulationDef`,
along with mutated information about trials, in addition to the model list and 
results information.
"""
function Base.run(sim_def::SimulationDef{T}, 
                models::Union{Vector{M}, AbstractModel}, 
                samplesize::Int;
                ntimesteps::Int=typemax(Int), 
                trials_output_filename::Union{Nothing, AbstractString}=nothing, 
                results_output_dir::Union{Nothing, AbstractString}=nothing, 
                pre_trial_func::Union{Nothing, Function}=nothing, 
                post_trial_func::Union{Nothing, Function}=nothing,
                scenario_func::Union{Nothing, Function}=nothing,
                scenario_placement::ScenarioLoopPlacement=OUTER,
                scenario_args=nothing,
                results_in_memory::Bool=true) where {T <: AbstractSimulationData, M <: AbstractModel}

    # If the provided models list has both a Model and a MarginalModel, it will be a Vector{Any}, and needs to be converted
    if models isa Vector{Any}
        models = convert(Vector{AbstractModel}, models)
    end
            
    # Quick check for results saving
    if (!results_in_memory) && (results_output_dir === nothing)
        error("The results_in_memory keyword arg is set to ($results_in_memory) and 
        results_output_dir keyword arg is set to ($results_output_dir), thus 
        results will not be saved either in memory or in a file.")
    end

    # Initiate the SimulationInstance and set the models and trials for the copied 
    # sim held within sim_inst
    sim_inst = SimulationInstance{typeof(sim_def.data)}(sim_def)
    set_models!(sim_inst, models)
    generate_trials!(sim_inst, samplesize; filename=trials_output_filename)
    set_translist_modelparams!(sim_inst) # should this use m.md or m.mi.md (after building below)?

    if (scenario_func === nothing) != (scenario_args === nothing)
        error("run: scenario_func and scenario_arg must both be nothing or both set to non-nothing values")
    end

    for m in sim_inst.models
        is_built(m) || build!(m)
    end

    trials = 1:sim_inst.trials

    # Save the original dir since we modify the output_dir to store scenario results
    orig_results_output_dir = results_output_dir

    # booleans vars to simplify the repeated tests in the loop below
    has_results_output_dir  = (orig_results_output_dir !== nothing)
    has_scenario_func  = (scenario_func !== nothing)
    has_outer_scenario = (has_scenario_func && scenario_placement == OUTER)
    has_inner_scenario = (has_scenario_func && scenario_placement == INNER)

    if has_scenario_func
        scen_names  = [arg.first  for arg in scenario_args]
        scen_values = [arg.second for arg in scenario_args]

        # precompute all combinations of scenario arguments so we can run
        # a single loop regardless of the number of scenario arguments.
        arg_tuples = Iterators.product(scen_values...)

        if has_outer_scenario
            arg_tuples_outer = arg_tuples
            arg_tuples_inner = (nothing,)   # allows one iteration when no scenario loop specified
        else
            arg_tuples_outer = (nothing,)   # as above
            arg_tuples_inner = arg_tuples
        end
    else
        arg_tuples = arg_tuples_outer = arg_tuples_inner = (nothing,)
        scen_name = nothing
    end
    
    # Set up progress bar
    nscenarios = length(arg_tuples)
    ntrials = length(trials)
    total_runs = nscenarios * ntrials
    counter = 1
    p = Progress(total_runs, counter, "Running $ntrials trials for $nscenarios scenarios...")

    for outer_tup in arg_tuples_outer
        if has_outer_scenario
            @debug "Calling outer scenario_func with $outer_tup"
            scenario_func(sim_inst, outer_tup)

            # we'll store the results of each in a subdir composed of tuple values
            results_output_dir = _compute_output_dir(orig_results_output_dir, outer_tup)

            # we'll need a scenario name for the DataFrame
            scen_name = join(map(string, outer_tup), "_")
        end
                
        # Save the params to be perturbed so we can reset them after each trial
        original_values = _copy_sim_params(sim_inst)        
        
        # Reset internal index to 1 for all stored parameters to reuse the data
        _reset_rvs!(sim_inst.sim_def)

        # Create a Dictionary of streams
        streams = Dict{String, CSVFiles.CSVFileSaveStream{IOStream}}()

        try 
            for (i, trialnum) in enumerate(trials)
                @debug "Running trial $trialnum"

                for inner_tup in arg_tuples_inner
                    tup = has_inner_scenario ? inner_tup : outer_tup

                    _perturb_params!(sim_inst, trialnum)

                    if pre_trial_func !== nothing
                        @debug "Calling pre_trial_func($trialnum, $tup)"
                        pre_trial_func(sim_inst, trialnum, ntimesteps, tup)
                    end               

                    if has_inner_scenario
                        @debug "Calling inner scenario_func with $inner_tup"
                        scenario_func(sim_inst, inner_tup)

                        results_output_dir = _compute_output_dir(orig_results_output_dir, inner_tup)

                        # we'll need a scenario name for the DataFrame
                        scen_name = join(map(string, inner_tup), "_")
                    end

                    for m in sim_inst.models   # note that list of models may be changed in scenario_func
                        @debug "Running model"
                        run(m, ntimesteps=ntimesteps)
                    end
                    
                    if post_trial_func !== nothing
                        @debug "Calling post_trial_func($trialnum, $tup)"
                        post_trial_func(sim_inst, trialnum, ntimesteps, tup)
                    end

                    _store_trial_results(sim_inst, trialnum, scen_name, results_output_dir, streams)
                    _restore_sim_params!(sim_inst, original_values)

                    counter += 1
                    ProgressMeter.update!(p, counter)                

                    if has_results_output_dir && ! results_in_memory
                        _reset_results!(sim_inst)
                    end
                end
            end
        finally 
            close.(values(streams))   # use broadcasting to close all stream 
        end
    end

    return sim_inst
end

"""
    _get_flat_model_list(sim_inst::SimulationInstance{T}) where T <: AbstractSimulationData

Return a flattened vector of models, splatting out the base and modified models of 
a MarginalModel.
"""
function _get_flat_model_list(sim_inst::SimulationInstance{T}) where T <: AbstractSimulationData

    flat_model_list = []
    for m in sim_inst.models
        if m isa MarginalModel
            push!(flat_model_list, m.base)
            push!(flat_model_list, m.modified)
        else
            push!(flat_model_list, m)
        end
    end
    return flat_model_list
end

"""
    _get_flat_model_list_names(sim_inst::SimulationInstance{T}) where T <: AbstractSimulationData

Return a vector of names referring to a flattened vector of models, splatting out 
the base and modified models of a MarginalModel.
"""
function _get_flat_model_list_names(sim_inst::SimulationInstance{T}) where T <: AbstractSimulationData 

    flat_model_list_names = [] # use for errors
    for (i, m) in enumerate(sim_inst.models)
        if m isa MarginalModel
            push!(flat_model_list_names, Symbol("Model$(i)_Base"))
            push!(flat_model_list_names, Symbol("Model$(i)_Modified"))
        else
            push!(flat_model_list_names, Symbol("Model$(i)"))
        end
    end
    return flat_model_list_names

end

# Set models
"""
    set_models!(sim_inst::SimulationInstance{T}, models::Vector{M}) where {T <: AbstractSimulationData, M <: AbstractModel}
	
Set the `models` to be used by the SimulationDef held by `sim_inst`. 
"""
function set_models!(sim_inst::SimulationInstance{T}, models::Vector{M}) where {T <: AbstractSimulationData, M <: AbstractModel}
    sim_inst.models = models
    _reset_results!(sim_inst)    # sets results vector to same length
end

"""
    set_models!(sim_inst::SimulationInstance{T}, m::AbstractModel)  where T <: AbstractSimulationData
	
Set the model `m` to be used by the Simulation held by `sim_inst`.
"""
set_models!(sim_inst::SimulationInstance{T}, m::AbstractModel)  where T <: AbstractSimulationData = set_models!(sim_inst, [m])

"""
    set_translist_modelparams!(sim_inst::SimulationInstance{T})

Create the transform spec list for the simulation instance, finding the matching
model parameter names for each transform spec parameter for each model.
"""
function set_translist_modelparams!(sim_inst::SimulationInstance{T}) where T <: AbstractSimulationData

    # build flat model list that splats out the base and modified models of MarginalModel
    flat_model_list = _get_flat_model_list(sim_inst)
    flat_model_list_names = _get_flat_model_list_names(sim_inst)

    # allocate simulation instance translist
    sim_inst.translist_modelparams = Vector{TransformSpec_ModelParams}(undef, length(sim_inst.sim_def.translist))

    for (trans_idx, trans) in enumerate(sim_inst.sim_def.translist)
        
        # initialize the vector of model parameters
        model_parameters_vec = Vector{Symbol}(undef, length(flat_model_list))

        # handling an unshared parameter specific to a component/parameter pair
        compname = trans.compname
        if !isnothing(compname)
            for (model_idx, m) in enumerate(flat_model_list)
                
                # check for component in the model
                compname in keys(components(m.md)) || error("Component $compname does not exist in $(flat_model_list_names[model_idx]).")

                model_param_name = get_model_param_name(m.md, compname, trans.paramname)
                
                # if this is a shared parameter the user should use syntax without 
                # compname in it, although this could warn or error
                if is_shared(model_param(m.md, model_param_name))
                    @warn string("Parameter indicated in `defsim` as $compname.$(trans.paramname) ",
                            "is connected to a SHARED parameter $model_param_name. Thus the ",
                            "value will be varied in all component parameters connected to ",
                            "that shared model parameter.  We suggest using $model_param_name = distribution ",
                            "syntax to be transparent about this.")
                end
                model_parameters_vec[model_idx] = model_param_name
            end

        # no component, so this should be referring to a shared parameter ... but 
        # historically might not have done so and been using one set by default etc.
        else
            paramname = trans.paramname
            suggestion_string = "use the `ComponentName.ParameterName` syntax in your SimulationDefinition to explicitly define this transform ie. `ComponentName.$paramname = RandomVariable`"
            
            for (model_idx, m) in enumerate(flat_model_list)
                model_name = flat_model_list_names[model_idx]

                # found the shared parameter
                if has_parameter(m.md, paramname)
                    model_parameters_vec[model_idx] = paramname 

                # didn't find the shared parameter, will try to resolve
                else
                    @warn "Parameter name $paramname not found in $model_name's shared parameter list, will attempt to resolve."
                    unshared_paramname = nothing
                    unshared_compname = nothing 
                                        
                    for (compname, compdef) in components(m.md)
                        if has_parameter(compdef, paramname)
                            if isnothing(unshared_paramname) # first time the parameter was found in a component
                                unshared_paramname = get_model_param_name(m.md, compname, paramname) # NB might not need to use m.mi.md here could be m.md
                                unshared_compname = compname
                            else # already found in a previous component
                                error("Cannot resolve because parameter name $paramname found in more than one component of $model_name, including $unshared_compname and $compname. Please $suggestion_string.")
                            end
                        end
                    end
                    if isnothing(unshared_paramname)
                        error("Cannot resolve because $paramname not found in any of the components of $model_name.  Please $suggestion_string.")
                    else
                        @warn("Found $paramname in $unshared_compname with model parameter name $unshared_paramname. Will use this model parameter, but in the future we suggest you $suggestion_string")
                        model_parameters_vec[model_idx] = unshared_paramname 
                    end
                end
            end
        end
        new_trans = TransformSpec_ModelParams(model_parameters_vec, trans.op, trans.rvname, trans.dims)
        sim_inst.translist_modelparams[trans_idx] = new_trans
    end
end
            
#
# Iterator functions for Simulation instance directly, and for use as an IterableTable.
#
function Base.iterate(sim_inst::SimulationInstance{T}) where T <: AbstractSimulationData
    _reset_rvs!(sim_inst.sim_def)
    trialnum = 1
    return get_trial(sim_inst, trialnum), trialnum + 1
end

function Base.iterate(sim_inst::SimulationInstance{T}, trialnum) where T <: AbstractSimulationData
    if trialnum > sim_inst.trials
        return nothing
    else
        return get_trial(sim_inst, trialnum), trialnum + 1
    end
end

IteratorInterfaceExtensions.isiterable(sim_inst::SimulationInstance{T}) where T <: AbstractSimulationData = true
TableTraits.isiterabletable(sim_inst::SimulationInstance{T}) where T <: AbstractSimulationData = true

IteratorInterfaceExtensions.getiterator(sim_inst::SimulationInstance{T}) where T = SimIterator{sim_inst.sim_def.nt_type, T}(sim_inst)

column_names(sim_def::SimulationDef{T}) where T <: AbstractSimulationData = fieldnames(sim_def.nt_type)
column_types(sim_def::SimulationDef{T}) where T <: AbstractSimulationData = [eltype(fld) for fld in values(sim_def.rvdict)]

column_names(sim_inst::SimulationInstance{T}) where T <: AbstractSimulationData = column_names(sim_inst.sim_def)
column_types(sim_inst::SimulationInstance{T}) where T <: AbstractSimulationData = column_types(sim_inst.sim_def)

#
# Iteration support (which in turn supports the "save" method)
#
column_names(iter::SimIterator) = column_names(iter.sim_inst)
column_types(iter::SimIterator) = error("Not implemented") # Used to be `IterableTables.column_types(iter.sim_def)`

function Base.iterate(iter::SimIterator)
    _reset_rvs!(iter.sim_inst.sim_def)
    idx = 1
    return get_trial(iter.sim_inst, idx), idx + 1
end

function Base.iterate(iter::SimIterator, idx)
    if idx > iter.sim_inst.trials
        return nothing
    else
        return get_trial(iter.sim_inst, idx), idx + 1
    end
end

Base.length(iter::SimIterator) = iter.sim_inst.trials

Base.eltype(::Type{SimIterator{NT, T}}) where {NT, T} = NT
