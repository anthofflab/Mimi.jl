using Mimi
using Distributions
using Test

@defcomp test1 begin
    p = Parameter(default = 5)
    function run_timestep(p, v, d, t) end
end

@defcomp test2 begin
    p = Parameter(default = 5)
    function run_timestep(p, v, d, t) end
end

@defcomp test3 begin
    a = Parameter(default = 5)
    function run_timestep(p, v, d, t) end
end

##
## Tests for set_translist_modelparams
##

sd = @defsim begin
    sampling(LHSData)
    p = Normal(0, 1)
end

#------------------------------------------------------------------------------
# Test a failure to find the unshared parameter in any components
m = Model()
set_dimension!(m, :time, 2000:10:2050)
add_comp!(m, test3)

fail_expr1 = :(
    run(sd, m, 100)
)

err1 = try eval(fail_expr1) catch err err end 
@test occursin("Cannot resolve because p not found in any of the components of Model1.", sprint(showerror, err1))

#------------------------------------------------------------------------------
# Test a failure due to finding the unshared parameter in more than one component
m = Model()
set_dimension!(m, :time, 2000:10:2050)
add_comp!(m, test1)
add_comp!(m, test2)

fail_expr2 = :(
    run(sd, m, 100)
)

err2 = try eval(fail_expr2) catch err err end 
@test occursin("Cannot resolve because parameter name p found in more than one component of Model1", sprint(showerror, err2))

#------------------------------------------------------------------
# Test a failure due to finding an unshared parameter in one model, but not 
# the other

m1 = Model()
set_dimension!(m1, :time, 2000:10:2050)
add_comp!(m1, test1)

m2 = Model()
set_dimension!(m2, :time, 2000:10:2050)
add_comp!(m2, test3)

fail_expr3 = :(
    run(sd, [m1, m2], 100)
)

err3 = try eval(fail_expr3) catch err err end 
@test occursin("Cannot resolve because p not found in any of the components of Model2", sprint(showerror, err3))

#------------------------------------------------------------------------------
# Test success cases 

# unshared parameter set by default
m = Model()
set_dimension!(m, :time, 2000:10:2050)
add_comp!(m, test1)
run(sd, m, 100)

# shared parameter 
m1 = Model()
set_dimension!(m1, :time, 2000:10:2050)
add_comp!(m1, test1)
add_comp!(m1, test2)
add_shared_param!(m1, :model_p, 5)
connect_param!(m1, :test1, :p, :model_p)
connect_param!(m1, :test2, :p, :model_p)
run(sd, m, 100)

# unshared parameter in both models with different names
m1 = Model()
set_dimension!(m1, :time, 2000:10:2050)
add_comp!(m1, test1)

m2 = Model()
set_dimension!(m2, :time, 2000:10:2050)
add_comp!(m2, test2)

run(sd, [m1, m2], 100)

#------------------------------------------------------------------------------
# Test warning for compname.paramname syntax in a shared parameter case

# shared parameter 
m = Model()
set_dimension!(m, :time, 2000:10:2050)
add_comp!(m, test1) # test1.p is unshared with default of 5
add_comp!(m, test2) # test2.p is unshared with default of 5
add_shared_param!(m, :model_p, 6) 
connect_param!(m, :test1, :p, :model_p)
# now test1.p is shared, connected to model_p with a value of 6, test2.p is still unshared

sd = @defsim begin
    sampling(LHSData)
    test2.p = Normal(0, 1)
end
run(sd, m, 2) # no warnings

sd = @defsim begin
    sampling(LHSData)
    test1.p = Normal(0, 1)
end
msg = "Parameter indicated in `defsim` as test1.p is connected to a SHARED parameter model_p. Thus the value will be varied in all component parameters connected to that shared model parameter.  We suggest using model_p = distribution syntax to be transparent about this."
@test_logs (:warn, msg) run(sd, m, 2) #should work but warn 

sd = @defsim begin
    sampling(LHSData)
    p = Normal(0, 1)
end
@test_throws ErrorException run(sd, m, 2) #should error, can't resolve

##
## Tests for set_translist_modelparams with a default (not shared)
##

sd = @defsim begin
    sampling(LHSData)
    test1.p = Normal(0, 1)
end

# simple case
m = Model()
set_dimension!(m, :time, 2000:10:2050)
add_comp!(m, test1)
run(sd, m, 100)

# component not found
m = Model()
set_dimension!(m, :time, 2000:10:2050)
add_comp!(m, test2)
fail_expr = :(run(sd, m, 100))
err4 = try eval(fail_expr) catch err err end 
@test occursin("Component test1 does not exist in Model1.", sprint(showerror, err4))

m1 = Model()
set_dimension!(m1, :time, 2000:10:2050)
add_comp!(m1, test2)
m2 = Model()
set_dimension!(m2, :time, 2000:10:2050)
add_comp!(m2, test1)
fail_expr = :(run(sd, [m1, m2], 100))
err5 = try eval(fail_expr) catch err err end 
@test occursin("Component test1 does not exist in Model1.", sprint(showerror, err5))

# transform used only for one of the component's parameters p
m = Model()
set_dimension!(m, :time, 2000:10:2050)
add_comp!(m, test1)
add_comp!(m, test2) # no transform used
run(sd, m, 100)

# two models, both with component parameter pair
m1 = Model()
set_dimension!(m1, :time, 2000:10:2050)
add_comp!(m1, test1)

m2 = Model()
set_dimension!(m2, :time, 2000:10:2050)
add_comp!(m2, test1)

run(sd, [m1, m2], 100)
