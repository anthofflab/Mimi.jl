using Classes
using DataStructures

#
# 1. Types supporting parameterized Timestep and Clock objects
#

abstract type AbstractTimestep end

struct FixedTimestep{FIRST, STEP, LAST} <: AbstractTimestep
    t::Int
end

struct VariableTimestep{TIMES} <: AbstractTimestep
    t::Int
    current::Int 

    function VariableTimestep{TIMES}(t::Int = 1) where {TIMES}
        # The special case below handles when functions like next_step step beyond
        # the end of the TIMES array.  The assumption is that the length of this
        # last timestep, starting at TIMES[end], is 1.
        current::Int = t > length(TIMES) ? TIMES[end] + 1 : TIMES[t]
        
        return new(t, current)
    end
end

mutable struct Clock{T <: AbstractTimestep}
	ts::T

	function Clock{T}(FIRST::Int, STEP::Int, LAST::Int) where T
		return new(FixedTimestep{FIRST, STEP, LAST}(1))
    end
    
    function Clock{T}(TIMES::NTuple{N, Int} where N) where T
        return new(VariableTimestep{TIMES}())
    end
end

mutable struct TimestepArray{T_TS <: AbstractTimestep, T, N}
	data::Array{T, N}

    function TimestepArray{T_TS, T, N}(d::Array{T, N}) where {T_TS, T, N}
		return new(d)
	end

    function TimestepArray{T_TS, T, N}(lengths::Int...) where {T_TS, T, N}
		return new(Array{T, N}(undef, lengths...))
	end
end

# Since these are the most common cases, we define methods (in time.jl)
# specific to these type aliases, avoiding some of the inefficiencies
# associated with an arbitrary number of dimensions.
const TimestepMatrix{T_TS, T} = TimestepArray{T_TS, T, 2}
const TimestepVector{T_TS, T} = TimestepArray{T_TS, T, 1}

#
# 2. Dimensions
#

abstract type AbstractDimension end

const DimensionKeyTypes   = Union{AbstractString, Symbol, Int, Float64}
const DimensionRangeTypes = Union{UnitRange{Int}, StepRange{Int, Int}}

struct Dimension{T <: DimensionKeyTypes} <: AbstractDimension
    dict::OrderedDict{T, Int}

    function Dimension(keys::Vector{T}) where {T <: DimensionKeyTypes}
        dict = OrderedDict(collect(zip(keys, 1:length(keys))))
        return new{T}(dict)
    end

    function Dimension(rng::T) where {T <: DimensionRangeTypes}
        return Dimension(collect(rng))
    end

    Dimension(i::Int) = Dimension(1:i)

    # Support Dimension(:foo, :bar, :baz)
    function Dimension(keys::T...) where {T <: DimensionKeyTypes}
        vector = [key for key in keys]
        return Dimension(vector)
    end
end

#
# Simple optimization for ranges since indices are computable.
# Unclear whether this is really any better than simply using 
# a dict for all cases. Might scrap this in the end.
#
mutable struct RangeDimension{T <: DimensionRangeTypes} <: AbstractDimension
    range::T
 end

#
# 3. Types supporting Parameters and their connections
#
abstract type ModelParameter end

# TBD: rename ScalarParameter, ArrayParameter, and AbstractParameter?

mutable struct ScalarModelParameter{T} <: ModelParameter
    value::T

    function ScalarModelParameter{T}(value::T) where T
        new(value)
    end

    function ScalarModelParameter{T1}(value::T2) where {T1, T2}
        try
            new(T1(value))
        catch err
            error("Failed to convert $value::$T2 to $T1")
        end
    end
end

mutable struct ArrayModelParameter{T} <: ModelParameter
    values::T
    dimensions::Vector{Symbol} # if empty, we don't have the dimensions' name information

    function ArrayModelParameter{T}(values::T, dims::Vector{Symbol}) where T
        new(values, dims)
    end
end

ScalarModelParameter(value) = ScalarModelParameter{typeof(value)}(value)

Base.convert(::Type{ScalarModelParameter{T}}, value::Number) where {T} = ScalarModelParameter{T}(T(value))

Base.convert(::Type{T}, s::ScalarModelParameter{T}) where {T} = T(s.value)

ArrayModelParameter(value, dims::Vector{Symbol}) = ArrayModelParameter{typeof(value)}(value, dims)

# Allow values to be obtained from either parameter type using one method name.
value(param::ArrayModelParameter)  = param.values
value(param::ScalarModelParameter) = param.value

dimensions(obj::ArrayModelParameter) = obj.dimensions
dimensions(obj::ScalarModelParameter) = []


abstract type AbstractConnection end

struct InternalParameterConnection <: AbstractConnection
    src_comp_name::Symbol
    src_var_name::Symbol
    dst_comp_name::Symbol
    dst_par_name::Symbol
    ignoreunits::Bool
    backup::Union{Symbol, Nothing} # a Symbol identifying the external param providing backup data, or nothing
    offset::Int

    function InternalParameterConnection(src_comp::Symbol, src_var::Symbol, dst_comp::Symbol, dst_par::Symbol,
                                         ignoreunits::Bool, backup::Union{Symbol, Nothing}=nothing; offset::Int=0)
        self = new(src_comp, src_var, dst_comp, dst_par, ignoreunits, backup, offset)
        return self
    end
end

struct ExternalParameterConnection  <: AbstractConnection
    comp_name::Symbol
    param_name::Symbol      # name of the parameter in the component
    external_param::Symbol  # name of the parameter stored in md.ccd.external_params
end

#
# 4. Types supporting structural definition of models and their components
#

# To identify components, we create a variable with the name of the component
# whose value is an instance of this type, e.g.
# const global adder = ComponentId(module_name, comp_name) 
struct ComponentId
    module_name::Symbol
    comp_name::Symbol
end

ComponentId(m::Module, comp_name::Symbol) = ComponentId(nameof(m), comp_name)

#
# TBD: consider a naming protocol that adds Cls to class struct names 
# so it's obvious in the code.
#

# Objects with a `name` attribute
@class NamedObj begin
    name::Symbol
end

"""
    nameof(obj::NamedDef) = obj.name 

Return the name of `def`.  `NamedDef`s include `DatumDef`, `ComponentDef`, 
`CompositeComponentDef`, `DatumReference` and `DimensionDef`.
"""
@method Base.nameof(obj::NamedObj) = obj.name

# Stores references to the name of a component variable or parameter
@class DatumReference <: NamedObj begin
    comp_id::ComponentId
end

comp_name(dr::DatumReference) = dr.comp_id.comp_name

# *Def implementation doesn't need to be performance-optimized since these
# are used only to create *Instance objects that are used at run-time. With
# this in mind, we don't create dictionaries of vars, params, or dims in the
# ComponentDef since this would complicate matters if a user decides to
# add/modify/remove a component. Instead of maintaining a secondary dict, 
# we just iterate over sub-components at run-time as needed. 

global const BindingTypes = Union{Int, Float64, DatumReference}

@class DimensionDef <: NamedObj

# Similar structure is used for variables and parameters (parameters merely adds `default`)
@class mutable DatumDef(getter_prefix="", setters=false) <: NamedObj begin
    datatype::DataType
    dimensions::Vector{Symbol}
    description::String
    unit::String
end

@class mutable VariableDef <: DatumDef

@class mutable ParameterDef <: DatumDef begin
    # ParameterDef adds a default value, which can be specified in @defcomp
    default::Any
end

# to allow getters to be created
import Base: first, last

@class mutable ComponentDef(getter_prefix="") <: NamedObj begin
    comp_id::Union{Nothing, ComponentId}    # allow anonynous top-level (composite) ComponentDefs (must be referenced by a ModelDef)
    variables::OrderedDict{Symbol, VariableDef}
    parameters::OrderedDict{Symbol, ParameterDef}
    dimensions::OrderedDict{Symbol, Union{Nothing, DimensionDef}}
    first::Union{Nothing, Int}
    last::Union{Nothing, Int}
    is_uniform::Bool

    function ComponentDef(self::ComponentDef, comp_id::Nothing)
        error("Leaf ComponentDef objects must have a valid ComponentId name (not nothing)")
    end

    # ComponentDefs are created "empty". Elements are subsequently added.
    function ComponentDef(self::_ComponentDef_, comp_id::Union{Nothing, ComponentId}=nothing; 
                          name::Union{Nothing, Symbol}=nothing)
        if name === nothing
            name = (comp_id === nothing ? gensym("anonymous") : comp_id.comp_name)
        end

        NamedObj(self, name)
        self.comp_id = comp_id
        self.variables  = OrderedDict{Symbol, VariableDef}()
        self.parameters = OrderedDict{Symbol, ParameterDef}() 
        self.dimensions = OrderedDict{Symbol, Union{Nothing, DimensionDef}}()
        self.first = self.last = nothing
        self.is_uniform = true
        return self

        return ComponentDef(comp_id, name=name)
    end

    function ComponentDef(comp_id::Union{Nothing, ComponentId}; 
                          name::Union{Nothing, Symbol}=nothing)
        self = new()
        return ComponentDef(self, comp_id, name=name)
    end    
end

@class mutable CompositeComponentDef <: ComponentDef begin
    comps_dict::OrderedDict{Symbol, _ComponentDef_}
    bindings::Vector{Pair{DatumReference, BindingTypes}}
    exports::Vector{Pair{DatumReference, Symbol}}
    
    internal_param_conns::Vector{InternalParameterConnection}
    external_param_conns::Vector{ExternalParameterConnection}
    external_params::Dict{Symbol, ModelParameter}

    # Names of external params that the ConnectorComps will use as their :input2 parameters.
    backups::Vector{Symbol}

    sorted_comps::Union{Nothing, Vector{Symbol}}

    function CompositeComponentDef(self::_CompositeComponentDef_, 
                                   comp_id::ComponentId, comps::Vector{T},
                                   bindings::Vector{Pair{DatumReference, BindingTypes}},
                                   exports::Vector{Pair{DatumReference, Symbol}}) where {T <: _ComponentDef_}
    
        comps_dict = OrderedDict{Symbol, T}([nameof(cd) => cd for cd in comps])
        in_conns = Vector{InternalParameterConnection}() 
        ex_conns = Vector{ExternalParameterConnection}()
        ex_params = Dict{Symbol, ModelParameter}()
        backups = Vector{Symbol}()
        sorted_comps = nothing
        
        ComponentDef(self, comp_id)         # superclass init [TBD: allow for alternate comp_name?]
        CompositeComponentDef(self, comps_dict, bindings, exports, in_conns, ex_conns, 
                              ex_params, backups, sorted_comps)
        return self
    end

    function CompositeComponentDef(comp_id::ComponentId, comps::Vector{T},
                                   bindings::Vector{Pair{DatumReference, BindingTypes}},
                                   exports::Vector{Pair{DatumReference, Symbol}}) where {T <: absclass(ComponentDef)}

        self = new()
        return CompositeComponentDef(self, comp_id, comps, bindings, exports)
    end

    function CompositeComponentDef(self::Union{Nothing, absclass(CompositeComponentDef)}=nothing)
        self = (self === nothing ? new() : self)

        comp_id  = ComponentId(:anonymous, :anonymous)      # TBD: pass these in?
        comps    = Vector{absclass(ComponentDef)}()
        bindings = Vector{Pair{DatumReference, BindingTypes}}()
        exports  = Vector{Pair{DatumReference, Symbol}}()
        return CompositeComponentDef(self, comp_id, comps, bindings, exports)
    end
end

@method external_param(obj::CompositeComponentDef, name::Symbol) = obj.external_params[name]

@method add_backup!(obj::CompositeComponentDef, backup) = push!(obj.backups, backup)


@class mutable ModelDef <: CompositeComponentDef begin
    dimensions2::Dict{Symbol, Dimension}
    number_type::DataType
    
    function ModelDef(self::_ModelDef_, number_type::DataType=Float64)
        CompositeComponentDef(self)  # call super's initializer

        dimensions = Dict{Symbol, Dimension}()
        return ModelDef(self, dimensions, number_type)
    end

    function ModelDef(number_type::DataType=Float64)
        self = new()
        return ModelDef(self, number_type)
    end
end

#
# 5. Types supporting instantiated models and their components
#

# Supertype for variables and parameters in component instances
@class ComponentInstanceData(getters=false, setters=false){NT <: NamedTuple} begin
    nt::NT
end

@method nt(obj::ComponentInstanceData) = getfield(obj, :nt)
@method types(obj::ComponentInstanceData) = typeof(nt(obj)).parameters[2].parameters
@method Base.names(obj::ComponentInstanceData)  = keys(nt(obj))
@method Base.values(obj::ComponentInstanceData) = values(nt(obj))

_make_data_obj(subclass::DataType, nt::NT) where {NT <: NamedTuple} = subclass{NT}(nt)

function _make_data_obj(subclass::DataType, names, types, values)
    NT = NamedTuple{names, types}
    _make_data_obj(subclass, NT(values))
end

@class ComponentInstanceParameters{NT <: NamedTuple} <: ComponentInstanceData
@class ComponentInstanceVariables{NT <: NamedTuple}  <: ComponentInstanceData

ComponentInstanceParameters(names, types, values) = _make_data_obj(ComponentInstanceParameters, names, types, values)
ComponentInstanceVariables(names, types, values)  = _make_data_obj(ComponentInstanceVariables, names, types, values)

@class mutable ComponentInstance(getters=false, setters=false){TV <: ComponentInstanceVariables, TP <: ComponentInstanceParameters} begin
    comp_name::Symbol
    comp_id::ComponentId
    variables::TV
    parameters::TP
    dim_dict::Dict{Symbol, Vector{Int}}
    first::Union{Nothing, Int}
    last::Union{Nothing, Int}
    init::Union{Nothing, Function}
    run_timestep::Union{Nothing, Function}

    function ComponentInstance(self::absclass(ComponentInstance),
                               comp_def::ComponentDef, vars::TV, pars::TP,
                               name::Symbol=nameof(comp_def)) where
                {TV <: ComponentInstanceVariables, TP <: ComponentInstanceParameters}
        
        self.comp_id = comp_id = comp_def.comp_id
        self.comp_name = name
        self.dim_dict = Dict{Symbol, Vector{Int}}()     # values set in "build" stage
        self.variables = vars
        self.parameters = pars
        self.first = comp_def.first
        self.last = comp_def.last

        comp_module = Main.eval(comp_id.module_name)

        # The try/catch allows components with no run_timestep function (as in some of our test cases)
        # CompositeComponentInstances use a standard method that just loops over inner components.
        # TBD: use FunctionWrapper here?
        function get_func(name)
            if is_composite(self)
                return nothing
            end

            func_name = Symbol("$(name)_$(self.comp_name)")
            try
                Base.eval(comp_module, func_name)
            catch err
                nothing
            end        
        end

        # `is_composite` indicates a ComponentInstance used to store summary
        # data for ComponentInstance and is not itself runnable.
        self.init         = get_func("init")
        self.run_timestep = get_func("run_timestep")

        return self
    end

    # Create an empty instance with the given type parameters
    function ComponentInstance{TV, TP}() where {TV <: ComponentInstanceVariables, TP <: ComponentInstanceParameters}
        return new{TV, TP}
    end
end

function ComponentInstance(comp_def::ComponentDef, vars::TV, pars::TP,
                           name::Symbol=nameof(comp_def)) where
        {TV <: ComponentInstanceVariables, TP <: ComponentInstanceParameters}

    self = ComponentInstance{TV, TP}()
    return ComponentInstance(self, comp_def, vars, pars, name)
end

# These can be called on CompositeComponentInstances and ModelInstances
@method compdef(obj::ComponentInstance) = compdef(comp_id(obj))
@method dims(obj::ComponentInstance) = obj.dim_dict
@method has_dim(obj::ComponentInstance, name::Symbol) = haskey(obj.dim_dict, name)
@method dimension(obj::ComponentInstance, name::Symbol) = obj.dim_dict[name]
@method first_period(obj::ComponentInstance) = obj.first
@method last_period(obj::ComponentInstance) = obj.last
@method first_and_last(obj::ComponentInstance) = (obj.first, obj.last)

@class mutable CompositeComponentInstance{TV <: ComponentInstanceVariables, 
                                          TP <: ComponentInstanceParameters} <: ComponentInstance begin
    comps_dict::OrderedDict{Symbol, absclass(ComponentInstance)}
    firsts::Vector{Int}        # in order corresponding with components
    lasts::Vector{Int}
    clocks::Vector{Clock}
    
    function CompositeComponentInstance(self::absclass(CompositeComponentInstance),
                                        comps::Vector{absclass(ComponentInstance)},
                                        comp_def::ComponentDef, name::Symbol=nameof(comp_def))
        comps_dict = OrderedDict{Symbol, absclass(ComponentInstance)}()
        firsts = Vector{Int}()
        lasts  = Vector{Int}()
        clocks = Vector{Clock}()

        for ci in comps
            comps_dict[ci.comp_name] = ci
            push!(firsts, ci.first)
            push!(lasts, ci.last)
            # push!(clocks, ?)
        end
        
        (vars, pars) = _collect_vars_pars(comps)
        ComponentInstance(self, comp_def, vars, pars, name)
        CompositeComponentInstance(self, comps_dict, firsts, lasts, clocks)
        return self
    end

    # Constructs types of vars and params from sub-components
    function CompositeComponentInstance(comps::Vector{absclass(ComponentInstance)},
                                        comp_def::ComponentDef,
                                        name::Symbol=nameof(comp_def))
        (TV, TP) = _comp_instance_types(comps)
        self = new{TV, TP}()
        CompositeComponentInstance(self, comps, comp_def, name)
    end
end

# These methods can be called on ModelInstances as well
@method components(obj::CompositeComponentInstance) = values(comps_dict)
@method has_comp(obj::CompositeComponentInstance, name::Symbol) = haskey(obj.comps_dict, name)
@method compinstance(obj::CompositeComponentInstance, name::Symbol) = obj.comps_dict[name]

@method is_leaf(ci::ComponentInstance) = true
@method is_leaf(ci::CompositeComponentInstance) = false
@method is_composite(ci::ComponentInstance) = !is_leaf(ci)

# TBD: write these
function _comp_instance_types(comps::Vector{absclass(ComponentInstance)})
    error("Need to define comp_instance_types")
end

function _collect_vars_pars(comps::Vector{absclass(ComponentInstance)})
    error("Need to define comp_instance_types")
end

# A container class that wraps the dimension dictionary when passed to run_timestep()
# and init(), so we can safely implement Base.getproperty(), allowing `d.regions` etc.
struct DimDict
    dict::Dict{Symbol, Vector{Int}}
end

# Special case support for Dicts so we can use dot notation on dimension.
# The run_timestep() and init() funcs pass a DimDict of dimensions by name 
# as the "d" parameter.
Base.getproperty(dimdict::DimDict, property::Symbol) = getfield(dimdict, :dict)[property]


# ModelInstance holds the built model that is ready to be run
@class ModelInstance{TV <: ComponentInstanceVariables, 
                     TP <: ComponentInstanceParameters} <: CompositeComponentInstance begin
    md::ModelDef

    # similar to generated constructor, but taking TV and TP from superclass instance
    function ModelInstance(md::ModelDef, s::CompositeComponentInstance{TV, TP}) where 
                {TV <: ComponentInstanceVariables, TP <: ComponentInstanceParameters}

        new{TV, TP}(s.comp_name, s.comp_id, s.variables, s.parameters, s.dim_dict, s.first, s.last, 
                    s.init, s.run_timestep, s.comps_dict, s.firsts, s.lasts, s.clocks, md)
    end
end
#
# 6. User-facing Model types providing a simplified API to model definitions and instances.
#
"""
    Model

A user-facing API containing a `ModelInstance` (`mi`) and a `ModelDef` (`md`).  
This `Model` can be created with the optional keyword argument `number_type` indicating
the default type of number used for the `ModelDef`.  If not specified the `Model` assumes
a `number_type` of `Float64`.
"""
mutable struct Model
    md::ModelDef
    mi::Union{Nothing, ModelInstance}
        
    function Model(number_type::DataType=Float64)
        return new(ModelDef(number_type), nothing)
    end

    # Create a copy of a model, e.g., to create marginal models
    function Model(m::Model)
        return new(deepcopy(m.md), nothing)
    end
end

""" 
    MarginalModel

A Mimi `Model` whose results are obtained by subtracting results of one `base` Model 
from those of another `marginal` Model` that has a difference of `delta`.
"""
struct MarginalModel
    base::Model
    marginal::Model
    delta::Float64

    function MarginalModel(base::Model, delta::Float64=1.0)
        return new(base, Model(base), delta)
    end
end

function Base.getindex(mm::MarginalModel, comp_name::Symbol, name::Symbol)
    return (mm.marginal[comp_name, name] .- mm.base[comp_name, name]) ./ mm.delta
end

#
# 7. Reference types provide more convenient syntax for interrogating Components
#

"""
    ComponentReference

A container for a component, for interacting with it within a model.
"""
struct ComponentReference
    model::Model
    comp_name::Symbol
end

"""
    VariableReference
    
A container for a variable within a component, to improve connect_param! aesthetics,
by supporting subscripting notation via getindex & setindex .
"""
struct VariableReference
    model::Model
    comp_name::Symbol
    var_name::Symbol
end
