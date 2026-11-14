# TaylorIntegration's step for Double64 time. Its _exact_step for AbstractFloat proves t0 + δt exact by an IEEE two-sum
# and steps back by prevfloat, neither of which holds for a double-word number, so a Double64 integration throws "no
# exact step found". This method keeps what its callers rely on (taylorinteg, its fixed-time output and its
# root-finding, TaylorIntegration 0.18.19 and 0.18.20): a step is at most |δt|, and a nonzero step moves t0; zero means
# no permitted step moves t0, and the callers stop. The step that reaches tmax is clamped to it, which lands on tmax
# when tmax - t0 is exact in Double64. It extends an internal, underscored function (read at TaylorIntegration 0.18.19 and
# 0.18.20, src/integrator/stepsize.jl): a rename or a new signature there makes this extension fail to load or go
# uncalled, and test/taylorintegration.jl, whole Double64 integrations against their closed forms, then fails.
module DoubleFloatsXTaylorIntegrationExt

using DoubleFloatsX: Double64
using TaylorIntegration: TaylorIntegration

function TaylorIntegration._exact_step(
    t0::Double64, δt::Double64, tmax::Double64, sign_tstep::Int
)
    s = sign_tstep
    d = tmax - t0
    t1 = t0 + δt
    if s * δt < s * d && s * t1 < s * tmax  # an interior step, which ends before tmax
        return t1 == t0 ? zero(δt) : δt
    end
    return d  # the step that reaches tmax, clamped to it
end

end
