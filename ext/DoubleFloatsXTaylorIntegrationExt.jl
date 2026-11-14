# TaylorIntegration's step for Double64 time. Its _exact_step for AbstractFloat proves t0 + δt exact by an IEEE two-sum
# and steps back by prevfloat, neither of which holds for a double-word number, so a Double64 integration throws "no
# exact step found"; this method is the package's own one for exact types (its method on ::Real), the clamp to tmax
# alone; the last time is tmax exactly when tmax - t0 is exact in Double64, and otherwise can pass it by a unit of the
# low limb. It extends an internal, underscored function (read at TaylorIntegration 0.18.19 and 0.18.20,
# src/integrator/stepsize.jl): a rename or a new signature there makes this extension fail to load or go uncalled,
# and test/taylorintegration.jl, a whole Double64 integration against its closed form, then fails.
module DoubleFloatsXTaylorIntegrationExt

using DoubleFloatsX: Double64
using TaylorIntegration: TaylorIntegration

function TaylorIntegration._exact_step(
    t0::Double64, δt::Double64, tmax::Double64, sign_tstep::Int
)
    return sign_tstep * min(sign_tstep * δt, sign_tstep * (tmax - t0))
end

end
