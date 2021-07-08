# This script runs the tests for all models that are known to us. For 
# registered models it will use the latest tagged version, for all other
# models it will use the latest `master` branch version.
#
# The script assumes that Mimi is deved into ~/.julia/dev/Mimi, and will
# run the tests with the version of Mimi that is in that location.
#
# To run the script, simply call it via
#
#   julia --color=yes test_all_models.jl
#

using Pkg
pkg_that_errored = []

# first set of packages to test
packages_to_test = [
    "MimiDICE2010" => ("https://github.com/anthofflab/MimiDICE2010.jl", "master")
    "MimiDICE2013" => ("https://github.com/anthofflab/MimiDICE2013.jl", "master"), 
    "MimiDICE2016" => ("https://github.com/AlexandrePavlov/MimiDICE2016.jl", "master"),
    "MimiDICE2016R2" => ("https://github.com/anthofflab/MimiDICE2016R2.jl", "master"),
    "MimiRICE2010" => ("https://github.com/anthofflab/MimiRICE2010.jl", "master"), 
    "MimiFUND" => ("https://github.com/fund-model/MimiFUND.jl", "master"),
    "MimiPAGE2009" => ("https://github.com/anthofflab/MimiPAGE2009.jl", "master"),
    "MimiPAGE2020" => ("https://github.com/lrennels/MimiPAGE2020.jl", "master"),
    "MimiSNEASY" => ("https://github.com/anthofflab/MimiSNEASY.jl", "master"),
    "MimiFAIR" => ("https://github.com/anthofflab/MimiFAIR.jl", "master"),
    "MimiMAGICC" => ("https://github.com/anthofflab/MimiMAGICC.jl", "master"),
    "MimiHector" => ("https://github.com/anthofflab/MimiHector.jl", "master")
]

mktempdir() do folder_name

    Pkg.activate(folder_name)

    Pkg.develop(PackageSpec(path=joinpath(@__DIR__, "..")))

    Pkg.add([i isa Pair ? PackageSpec(url=i[2][1], rev=i[2][2]) : PackageSpec(i) for i in packages_to_test])

    Pkg.resolve()

    for pkg_info in packages_to_test
        pkg = pkg_info isa Pair ? pkg_info[1] : pkg_info
        @info "Now testing $pkg."
        try
            Pkg.test(PackageSpec(pkg))
        catch err
            push!(pkg_that_errored, pkg)
        end
    end

    println()
    println()
    println()

    println("The following packages errored:")
    for p in pkg_that_errored
        println(p)
    end
end

# test separately because needs MimiFUND 3.8.6
packages_to_test = [
   "MimiIWG" => ("https://github.com/rffscghg/MimiIWG.jl", "master")
]

mktempdir() do folder_name

    Pkg.activate(folder_name)

    Pkg.develop(PackageSpec(path=joinpath(@__DIR__, "..")))

    Pkg.add([i isa Pair ? PackageSpec(url=i[2][1], rev=i[2][2]) : PackageSpec(i) for i in packages_to_test])

    Pkg.resolve()

    for pkg_info in packages_to_test
        pkg = pkg_info isa Pair ? pkg_info[1] : pkg_info
        @info "Now testing $pkg."
        try
            Pkg.test(PackageSpec(pkg))
        catch err
            push!(pkg_that_errored, pkg)
        end
    end
end

println()
println()
println()

println("The following packages errored:")
for p in pkg_that_errored
    println(p)
end
