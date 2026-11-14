# Gamma.jl's gamma functions are other functions than SpecialFunctions' of the same names, and its callers
# (HypergeometricFunctions among them) reach these; Gamma.gamma(::Complex) is exp(loggamma(z)), or the real gamma when
# the imaginary part is zero, so these four methods complete it for Double64.
module DoubleFloatsXGammaExt

using DoubleFloatsX: DoubleFloatsX, Double64
using Gamma: Gamma

Gamma.loggamma(z::Complex{Double64}) = DoubleFloatsX.SpecialFunctions.loggamma(z)
Gamma.gamma(x::Double64) = DoubleFloatsX.SpecialFunctions.gamma(x)
Gamma.loggamma(x::Double64) = DoubleFloatsX.SpecialFunctions.loggamma(x)
Gamma.logabsgamma(x::Double64) = DoubleFloatsX.SpecialFunctions.logabsgamma(x)

end
