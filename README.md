## MWEHelper

This package tries to make it easier to provide good MWEs when reporting bugs
by automatically fetching the environment information and testing that your
MWE reproduces the error in an isolated environment.

The main interface is `bug_report(msg::String, mwe; filename::String = "bug_report.md")`,
which takes a message describing the bug and a minimal working example (MWE)
that reproduces the error. `mwe` should be a function with no arguments that
reproduces the error. The package tries to automatically grab all the dependencies
of the function, such as other functions, global variables, and packages.

Once we get the full code, a temporary environment is created and the MWE is
tested to ensure it reproduces the error.

Inside the temporary environment, the MWE is executed using
```
$(Base.julia_cmd()) --startup-file=no --color=no --check-bounds=yes --compiled-modules=yes --depwarn=yes --project=$test_env
```
to ensure that the same julia version is used and that the error is unrelated
to any local environment configuration (e.g. startup.jl or `--check-bounds=no`).

The environment information is collected from the temporary environment
and used to generate a Markdown report with the bug description,
MWE, and environment information (following the SciML issue template),
and saves it to `filename` (defaults to `"bug_report.md"`).

### Usage
```julia
using MWEHelper

function my_mwe()
    sqrt(-1)
end

bug_report("My bug description", my_mwe)
```

Note that the MWE should be formulated as a function with no arguments that
raises an error. If you have a MWE where a result is wrong but no error is raised,
you can still use `bug_report` by formulating your MWE using `@test result == expected`.
This should both raise an error and also serve as a potential test case for package developers.

### Limitations
This package uses CodeTracking.jl to introspect the MWE dependencies. It is recommended to load Revise.jl
if you have the mwe defined only in the REPL.

### Disclaimer

This package is experimental (especially the introspection parts that grab the mwe dependencies)
and was written with help from Claude.
