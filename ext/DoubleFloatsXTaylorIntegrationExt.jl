# TaylorIntegration's step for Double64 time. Its _exact_step for AbstractFloat proves t0 + δt exact by an IEEE two-sum
# and steps back by prevfloat, neither of which holds for a double-word number, so a Double64 integration throws "no
# exact step found". This method keeps the contract its callers rely on (taylorinteg, its fixed-time output and its
# root-finding, TaylorIntegration 0.18.19 and 0.18.20): a nonzero step moves t0; no step passes tmax; the step that
# reaches tmax lands on it, t0 + δt == tmax as the callers add (the fixed-time output indexes past its end otherwise);
# a step is at most |δt|, but for the one that reaches tmax, which may exceed it by a rounding. Zero means no
# permitted step moves t0, and the callers stop. It extends an internal, underscored function (read at TaylorIntegration 0.18.19 and
# 0.18.20, src/integrator/stepsize.jl): a rename or a new signature there makes this extension fail to load or go
# uncalled, and test/taylorintegration.jl, whole Double64 integrations against their closed forms, then fails.
module DoubleFloatsXTaylorIntegrationExt

using DoubleFloatsX: Double64, HI, LO
using TaylorIntegration: TaylorIntegration

# equal values, limb by limb in IEEE: Double64's own == tells a -0.0 low limb from +0.0, so Double64(3.0, -0.0) as tmax
# would never be "reached"
_same(a::Double64, b::Double64) = HI(a) == HI(b) && LO(a) == LO(b)

function TaylorIntegration._exact_step(
    t0::Double64, δt::Double64, tmax::Double64, sign_tstep::Int
)
    s = sign_tstep
    d = tmax - t0
    t1 = t0 + δt
    if s * δt < s * d && s * t1 < s * tmax  # an interior step, which ends before tmax
        return _same(t1, t0) ? zero(δt) : δt
    end
    _same(t0 + d, tmax) && return d  # the step that reaches tmax lands on it
    # t0 + (tmax - t0) misses tmax, as when that difference needs more than two limbs: stop first at t1 = t0 + δ before
    # tmax, δ the difference's high limb, its Float64 neighbour toward zero, or half the difference, taking the first
    # from which t1 + (tmax - t1) lands, as the callers add; else the first that moves t0 and passes no tmax
    h = HI(d)
    δs = (Double64(h), Double64(s > 0 ? prevfloat(h) : nextfloat(h)), d * 0.5)
    for δ in δs
        t1 = t0 + δ
        s * t0 < s * t1 < s * tmax && _same(t1 + (tmax - t1), tmax) && return δ
    end
    for δ in δs
        t1 = t0 + δ
        s * t0 < s * t1 < s * tmax && return δ
    end
    return zero(δt)
end

end
