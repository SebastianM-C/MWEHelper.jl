using ModelingToolkitBase
using ModelingToolkitBase: D_nounits as D, t_nounits as t

function get_eqs(x, y, a, b, c, d)
    return [
        D(x) ~ a * x + b * y
        D(y) ~ c * x + d * y
    ]
end

function create_sys(; name)
    @variables x(t) y(t)
    @parameters a b c d
    eqs = get_eqs(x, y, a, b, c, d)
    return System(eqs, t; name)
end

function mwe1()
    sys = create_sys(name = :mwe1)
    return ODEProblem(sys, [x => 1, y => 2], (0.0, 10.0))
end

function mwe2()
    sys = create_sys(name = :mwe1)
    return ODEProblem(sys, [sys.x => 1, sys.y => 2], (0.0, 10.0))
end

_name = :foo

function mwe3()
    sys = create_sys(name = _name)
    return ODEProblem(sys, [sys.x => 1, sys.y => 2], (0.0, 10.0))
end
