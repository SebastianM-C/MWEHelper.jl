using Test
using Logging: Warn
using MWEHelper

include("mwe.jl")

@testset "MWEHelper" begin
    @testset "bug_report mwe1" begin
        tmpfile = tempname() * ".md"
        @test_logs min_level = Warn bug_report("test mwe1", mwe1; filename = tmpfile)
        report = read(tmpfile, String)
        rm(tmpfile)

        # Correct packages detected
        @test occursin("using ModelingToolkitBase", report)

        # Aliases detected
        @test occursin("t_nounits as t", report)
        @test occursin("D_nounits as D", report)

        # Helper functions included
        @test occursin("function create_sys", report)
        @test occursin("function get_eqs", report)

        # No duplicates
        @test count("function create_sys", report) == 1
        @test count("function get_eqs", report) == 1

        # MWE source and call included
        @test occursin("function mwe1", report)
        @test occursin("mwe1()", report)
    end

    @testset "bug_report mwe2" begin
        tmpfile = tempname() * ".md"
        @test_logs min_level = Warn bug_report("test mwe2", mwe2; filename = tmpfile)
        report = read(tmpfile, String)
        rm(tmpfile)

        # Correct packages detected
        @test occursin("using ModelingToolkitBase", report)

        # Aliases detected
        @test occursin("t_nounits as t", report)
        @test occursin("D_nounits as D", report)

        # Helper functions included, no duplicates
        @test occursin("function create_sys", report)
        @test occursin("function get_eqs", report)
        @test count("function create_sys", report) == 1
        @test count("function get_eqs", report) == 1

        # MWE source and call included
        @test occursin("function mwe2", report)
        @test occursin("mwe2()", report)
    end

    @testset "bug_report mwe3" begin
        tmpfile = tempname() * ".md"
        @test_logs min_level = Warn bug_report("test mwe3", mwe3; filename = tmpfile)
        report = read(tmpfile, String)
        rm(tmpfile)

        # Global binding detected
        @test occursin("_name = :foo", report)

        # Aliases detected
        @test occursin("t_nounits as t", report)
        @test occursin("D_nounits as D", report)

        # Helper functions included, no duplicates
        @test occursin("function create_sys", report)
        @test occursin("function get_eqs", report)
        @test count("function create_sys", report) == 1
        @test count("function get_eqs", report) == 1

        # MWE source and call included
        @test occursin("function mwe3", report)
        @test occursin("mwe3()", report)
    end
end
