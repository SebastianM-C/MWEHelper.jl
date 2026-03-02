module MWEHelper

export bug_report

import Pkg
using InteractiveUtils: versioninfo
using CodeTracking: code_string, definition
using MethodAnalysis: methodinstances

# Strip directory components from @ Module path/file.jl:N stack frame lines
# Normalize stack traces for comparison:
# - Strip directory components and line numbers from frame locations (line numbers
#   differ because the reproduced script has a generated preamble).
# - Strip leading whitespace from each line (REPL uses 2-space indent, scripts 1-space).
function normalize_stacktrace(trace::AbstractString)
    trace = replace(trace, r"@ (\S+) \S*[/\\](\S+\.jl)(?::\d+)?" => s"@ \1 \2")
    trace = replace(trace, r"^[ \t]+"m => "")
    return trace
end

# The original trace is captured inside bug_report via catch_backtrace(), so it
# includes the bug_report frame and REPL machinery below the user's mwe() call.
# Trim everything from the first MWEHelper frame downwards.
function unwrap_original_trace(trace::AbstractString)
    lines = split(trace, '\n')
    for (i, line) in enumerate(lines)
        # Match "@ SomeModule.MWEHelper file.jl" — module name, not path component
        occursin(r"@\s+(?:\w+\.)*MWEHelper\b", line) || continue
        # Walk back to the start of this frame (the [N] header line)
        j = i
        while j > 1 && !occursin(r"^\s*\[\d+\]", lines[j])
            j -= 1
        end
        return join(lines[1:(j - 1)], '\n')
    end
    return trace
end

# Strip LoadError wrapping and script-runner boilerplate that appears when Julia
# executes a file (but not in a REPL catch block).
function unwrap_script_error(trace::AbstractString)
    # Discard any preamble (precompile messages, deprecation warnings, etc.) before the error line.
    idx = findfirst(r"^ERROR:"m, trace)
    isnothing(idx) || (trace = trace[first(idx):end])
    # "ERROR: LoadError: <msg>" → "<msg>"
    trace = replace(trace, r"^ERROR: LoadError: " => "")
    # Drop the "in expression starting at ..." trailer (anchored to end of string)
    trace = replace(trace, r"\nin expression starting at [^\n]*\n?\z" => "")
    # Drop known Julia script-runner frames from the bottom of the stacktrace.
    # Each frame is two lines: "[N] name\n   @ location". Strip from the end only
    # so that any inner LoadError frames mid-trace are preserved.
    for pat in [
            r"\n\s+\[\d+\] _start\(\)\n[^\n]*\z",
            r"\n\s+\[\d+\] exec_options\(opts::Base\.JLOptions\)\n[^\n]*\z",
            r"\n\s+\[\d+\] include\(mod::Module, _path::String\)\n[^\n]*\z",
            r"\n\s+\[\d+\] top-level scope\n[^\n]*\z",
        ]
        trace = replace(trace, pat => "")
    end
    return trace
end

# LCS-based unified diff of two line vectors
function lcs_diff(a::Vector{<:AbstractString}, b::Vector{<:AbstractString})
    m, n = length(a), length(b)
    dp = zeros(Int, m + 1, n + 1)
    for i in 1:m, j in 1:n
        dp[i + 1, j + 1] = a[i] == b[j] ? dp[i, j] + 1 : max(dp[i, j + 1], dp[i + 1, j])
    end
    lines = String[]
    i, j = m, n
    while i > 0 || j > 0
        if i > 0 && j > 0 && a[i] == b[j]
            pushfirst!(lines, "  " * a[i]); i -= 1; j -= 1
        elseif j > 0 && (i == 0 || dp[i + 1, j] >= dp[i, j + 1])
            pushfirst!(lines, "+ " * b[j]); j -= 1
        else
            pushfirst!(lines, "- " * a[i]); i -= 1
        end
    end
    return join(lines, '\n')
end

# Compare original and reproduced traces after path normalisation.
# Returns (:full_match | :partial_match | :no_match, diff_string)
function compare_traces(original::AbstractString, reproduced::AbstractString)
    norm_orig = normalize_stacktrace(unwrap_original_trace(original))
    norm_repr = normalize_stacktrace(unwrap_script_error(reproduced))
    norm_orig == norm_repr && return :full_match, ""
    level = first(split(norm_orig, '\n')) == first(split(norm_repr, '\n')) ?
        :partial_match : :no_match
    diff = lcs_diff(split(norm_orig, '\n'), split(norm_repr, '\n'))
    return level, diff
end

function callee_methods(ci::Core.CodeInstance)
    edges = ci.edges
    result = Method[]
    isnothing(edges) && return result
    i = 1
    while i ≤ length(edges)
        item = edges[i]
        if item isa Int          # query metadata: [Int, Type] pair
            i += 2
        elseif item isa Core.CodeInstance
            push!(result, item.def.def)   # .def = MethodInstance, .def.def = Method
            i += 1
        elseif item isa Core.MethodInstance
            push!(result, item.def)
            i += 1
        elseif item isa Method   # failed abstract call
            push!(result, item)
            i += 1
        else                     # Type/UnionAll: invoke-edge pair [sig, callee]
            callee = edges[i + 1]
            if callee isa Core.CodeInstance
                push!(result, callee.def.def)
            elseif callee isa Core.MethodInstance
                push!(result, callee.def)
            elseif callee isa Method
                push!(result, callee)
            end
            i += 2
        end
    end
    return result
end

function collect_global_bindings(f)
    bindings = Dict{Symbol, Any}()
    seen = Set{Method}()
    for m in methods(f)
        _collect_bindings!(bindings, m, seen)
    end
    return bindings
end

# code_lowered(m::Method) returns [] for REPL-defined methods (m.source is nothing).
# Fall back to code_lowered(f, types) which works in both cases.
function _method_lowered(m::Method)
    cis = code_lowered(m)
    isempty(cis) || return cis
    ft = m.sig.parameters[1]
    isconcretetype(ft) && isdefined(ft, :instance) || return cis
    f = ft.instance
    arg_types = Tuple{m.sig.parameters[2:end]...}
    return try
        code_lowered(f, arg_types)
    catch
        cis
    end
end

function _collect_bindings!(bindings::Dict{Symbol, Any}, m::Method, seen::Set{Method})
    m in seen && return
    push!(seen, m)

    cis = _method_lowered(m)
    isempty(cis) && return
    ci = first(cis)
    walk(x::GlobalRef) =
    if x.mod === Main && isdefined(Main, x.name) &&
            Base.binding_module(Main, x.name) === Main
        val = getfield(Main, x.name)
        if val isa Function
            for m2 in methods(val)
                _collect_bindings!(bindings, m2, seen)
            end
        else
            bindings[x.name] = val
        end
    end
    walk(x::Expr) = foreach(walk, x.args)
    walk(_) = nothing
    return foreach(walk, ci.code)
end

function collect_import_aliases(f)
    # alias_name => (source_module, canonical_name) for `using M: foo as bar` imports
    aliases = Dict{Symbol, Tuple{Module, Symbol}}()
    seen = Set{Method}()
    for m in methods(f)
        _collect_aliases!(aliases, m, seen)
    end
    return aliases
end

function _alias_canonical_name(source_mod::Module, val, alias::Symbol)
    # If source_mod exports the value under the same name, it's a regular import (not `as`).
    try
        isdefined(source_mod, alias) && getfield(source_mod, alias) === val && return alias
    catch end
    # Fast path: nameof — but only accept if it actually refers to val in source_mod.
    # (e.g. nameof(D_nounits) = :Differential, which is the type, not the instance)
    canonical = try
        nameof(val)
    catch
        alias
    end
    if canonical !== alias
        try
            isdefined(source_mod, canonical) && getfield(source_mod, canonical) === val && return canonical
        catch end
    end
    # Slow path: search source module for a binding that holds the same object
    for name in names(source_mod; all = true, imported = false)
        isdefined(source_mod, name) || continue
        try
            getfield(source_mod, name) === val && return name
        catch end
    end
    return nothing
end

function _collect_aliases!(aliases::Dict{Symbol, Tuple{Module, Symbol}}, m::Method, seen::Set{Method})
    m in seen && return
    push!(seen, m)
    cis = _method_lowered(m)
    isempty(cis) && return
    ci = first(cis)
    function walk(x::GlobalRef)
        x.mod === Main || return
        isdefined(Main, x.name) || return
        local val = getfield(Main, x.name)
        source_mod = Base.binding_module(Main, x.name)
        if source_mod !== Main
            canonical = _alias_canonical_name(source_mod, val, x.name)
            isnothing(canonical) || canonical === x.name || (aliases[x.name] = (source_mod, canonical))
        end
        # Recurse into Main-defined helpers to find aliases they use
        return val isa Function && source_mod === Main &&
            foreach(m2 -> _collect_aliases!(aliases, m2, seen), methods(val))
    end
    walk(x::Expr) = foreach(walk, x.args)
    walk(_) = nothing
    return foreach(walk, ci.code)
end

function format_binding(name::Symbol, value)
    prefix = Base.isconst(Main, name) ? "const " : ""
    return "$(prefix)$(name) = $(repr(value))"
end

function collect_deps!(
        dep_src::Vector{String}, pkgs, ci::Core.CodeInstance,
        seen::Set{Method} = Set{Method}(), seen_defs::Set{String} = Set{String}()
    )
    deps = callee_methods(ci)

    module_deps = map(d -> Base.moduleroot(d.module), deps)
    required_pkgs = unique(filter(m -> m ∉ [Core, Base, Main], module_deps))
    push!(pkgs, required_pkgs)

    main_deps = filter(d -> d.module == Main && d ∉ seen, deps)
    for dep in main_deps
        push!(seen, dep)
    end

    for dep in main_deps
        result = definition(String, dep)
        isnothing(result) && continue
        current_def = result[1]
        current_def in seen_defs && continue
        push!(seen_defs, current_def)
        @debug "Adding $dep"
        push!(dep_src, current_def)
    end

    for dep in main_deps
        @debug "Collecting deps for $(dep.name)"
        spec = dep.specializations
        if typeof(spec) == Core.MethodInstance
            isdefined(spec, :cache) && collect_deps!(dep_src, pkgs, spec.cache, seen, seen_defs)
        elseif typeof(spec) == Core.SimpleVector
            for i in 1:length(spec)
                if !isnothing(spec[i]) && isdefined(spec[i], :cache)
                    collect_deps!(dep_src, pkgs, spec[i].cache, seen, seen_defs)
                end
            end
        else
            error("Unknown case $(typeof(spec)). Please open an issue in MWEHelper with steps to repoduce this.")
        end
    end
    return
end

function bug_report(msg::String, mwe; filename::String = "bug_report.md", verbose::Bool = false, overwrite::Bool = false)
    @info "Starting bug report process..."
    mwe_source = code_string(mwe, ())
    stack_trace = try
        mwe()
    catch err
        sprint(showerror, err, catch_backtrace())
    else
        error("The `mwe()` function did not throw an error.")
    end

    mi = methodinstances(mwe, ())
    ci = only(mi).cache
    dep_src = String[]
    required_pkgs = []
    collect_deps!(dep_src, required_pkgs, ci)

    all_deps = join(dep_src, "\n")
    all_pkgs = unique(string.(nameof.(Iterators.flatten(required_pkgs))))

    global_bindings = collect_global_bindings(mwe)  # recurses into Main helpers
    bindings_src = join([format_binding(n, v) for (n, v) in global_bindings], "\n")

    import_aliases = collect_import_aliases(mwe)
    alias_imports = join(
        [
            "using $(nameof(Base.moduleroot(mod))): $canonical as $alias"
                for (alias, (mod, canonical)) in import_aliases
        ],
        "\n"
    )

    full_mwe = join(
        filter(
            !isempty, [
                isempty(all_pkgs) ? "" : "using $(join(all_pkgs, ", "))",
                alias_imports,
                bindings_src,
                all_deps,
                mwe_source,
                "$(nameof(mwe))()",
            ]
        ), "\n\n"
    )

    @info "Testing MWE reproducibility..."
    test_env = mktempdir()

    current_project = Base.active_project()
    pkg_versions = Dict(info.name => info.version for (_, info) in Pkg.dependencies())
    reproduction_note = ""
    pkg_st = ""
    pkg_m = ""

    pkg_io = verbose ? Base.stdout : devnull

    try
        Pkg.activate(test_env; io = pkg_io)
        for pkg in all_pkgs
            v = get(pkg_versions, pkg, nothing)
            spec = v !== nothing ? Pkg.PackageSpec(name = pkg, version = v) : Pkg.PackageSpec(name = pkg)
            Pkg.add(spec; io = pkg_io)
        end

        write(joinpath(test_env, "mwe.jl"), full_mwe)

        err_buf = IOBuffer()
        cmd = ignorestatus(`$(Base.julia_cmd()) --startup-file=no --color=no --check-bounds=yes --compiled-modules=yes --depwarn=yes --project=$test_env $(joinpath(test_env, "mwe.jl"))`)
        proc = run(pipeline(cmd, stderr = err_buf))
        reproduced_stderr = String(take!(err_buf))

        if proc.exitcode == 0
            @warn "MWE exited without error — it may be incomplete."
            reproduction_note = "✗ MWE completed without error. The MWE may be incomplete."
        else
            match_level, diff = compare_traces(stack_trace, reproduced_stderr)
            if match_level == :full_match
                @info "✔ Error fully reproduced in an isolated environment ($test_env)."
                reproduction_note = "\n$filename is ready."
            elseif match_level == :partial_match
                @info "⚠ Error message matches but stack trace differs. Check $test_env for the isolated environment."
                reproduction_note = "\nDiff (- original  + reproduced):\n```\n$diff\n```"
            else
                @error "✗ The MWE resulted in a different error — the MWE may be incomplete. Check $test_env for the isolated environment."
                reproduction_note = "\nDiff (- original  + reproduced):\n```\n$diff\n```"
            end
        end

        println(reproduction_note)

        pkg_st = sprint(io -> Pkg.status(; io))
        pkg_m = sprint(io -> Pkg.status(; mode = Pkg.PKGMODE_MANIFEST, io))
    finally
        Pkg.activate(isnothing(current_project) ? "." : current_project; io = pkg_io)
    end
    ver = sprint(versioninfo)

    report = """
    Bug description: $msg

    Minimal Working Example:
    ```julia
    $full_mwe
    ```

    Error & stacktrace:
    ```
    $stack_trace
    ```

    Environment:
    - Output of `using Pkg; Pkg.status()`
    ```
    $pkg_st
    ```
    - Output of `using Pkg; Pkg.status(; mode = PKGMODE_MANIFEST)`
    ```
    $pkg_m
    ```
    - Output of `versioninfo()`
    ```
    $ver
    ```
    """

    if !overwrite && isfile(filename)
        @warn "File \"$filename\" already exists. Use `overwrite=true` to overwrite it."
    else
        open(filename, "w") do io
            write(io, report)
        end
    end

    return nothing
end

end # module MWEHelper
