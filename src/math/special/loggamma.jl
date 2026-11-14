# The complex loggamma, generic in the precision: SpecialFunctions' Complex{Float64} structure with the parameters of
# the type's precision, a local series in a strip along the real axis, and the upward shift rearranged.
# - Stirling's series where Re z >= w or |Im z| >= w;
# - the Taylor series of lg at 1 and 2 in their diamonds |Re z - c| + |Im z| < rho, relative accuracy at the zeros;
# - Hare's reflection for Re z < 1/2;
# - for |Im z| < ystrip, a downward shift to Re u in [1/2, 3/2) and the Taylor series of 1/gamma(1 + t) there;
# - otherwise the upward shift to Re z >= w.
# A shift's product is one product whose + to - sign flips are counted (Hare, J. Algorithms 25 (1997) 221-236,
# Proposition 2.2). The branch is the continuous one, lg(z + 1) = lg(z) + log(z), equal to log(gamma(z)) on the
# positive axis; on the cut the sign of a zero imaginary part chooses the side, and lg(conj(z)) = conj(lg(z)) exactly.
#
# Why the strip and the rearrangement. SpecialFunctions' upward shift, lg(z) = lg(z + r) - log(z (z + 1) ... (z + r - 1)),
# subtracts two terms of about w ln w, 44 at w = 16, where lg(z) is of order one, so each rounding of those terms costs
# up to 44 units of max(1, |lg|): measured up to 207 u of 2^-106 in Double64 near the real axis. In a fixed type no
# guard bits can absorb it (Arb and mpmath add them). Two changes remove it:
# - Near the real axis, |Im z| < ystrip, shift down instead: lg(z) = lg(u) + log(u (u + 1) ... (u + m - 1)),
#   u = z - m, Re u in [1/2, 3/2), with lg(u) = -log(1/gamma(1 + t)), t = u - 1, from the Taylor series of the entire
#   function 1/gamma (FLINT's local method). Every term then has the sign of lg(z) or a size below 6, so nothing
#   cancels. The series' truncation is below 2^-112 relative on |t| <= sqrt(1/4 + ystrip^2), since
#   |1/gamma(u)| >= 0.56 there; |Im lg(u)| <= 3.002 < π there, so the principal log is lg's branch.
# - Above it, rearrange the upward shift: with ζ = z + r and log(z + k) = log ζ + log(1 - (r - k)/ζ),
#   lg(z) = (z - 1/2) log ζ - ζ + log(2π)/2 + S(ζ) - log((1 - 1/ζ) (1 - 2/ζ) ... (1 - r/ζ)), S Stirling's sum. The
#   terms (ζ - 1/2) log ζ and r log ζ, each about 44, cancel exactly in the algebra, and none of the remaining ones is
#   larger than about |z| ln |ζ|, with |lg(z)| >= about π |Im z| / 2 here.
# The bound. Truncation: at most 2^-108 absolute in Stirling's series (Hare's bound at (w, N)), 2^-108 relative in the
# diamonds, 2^-111 absolute in the strip. Rounding: measured against Arb (tools/loggamma/sweep.jl), per component in
# units of 2^-106 of max(1, |lg|), relative in the diamonds; test/loggamma.jl holds the bounds per region.

"""
    LogGammaConstants{T}(w, N, K, ystrip, KR)

The constants of the complex loggamma in the type `T`: Stirling's series where `Re z >= w` or `|Im z| >= w`, with
`N - 1` terms; `K` terms of the Taylor series of lg at 1 and 2 in the diamonds `|Re z - c| + |Im z| < 1/10`; the
coefficients `c_0, ..., c_KR` of the Taylor series of `1/gamma(1 + t)`, used where `|Im z| < ystrip`. Each is rounded
once to `T` from a value of an exact rational (the Bernoulli numbers) or of MPFR's zeta at 1024 bits, by the
correctly rounding `convert(T, ::BigFloat)`.
"""
struct LogGammaConstants{T,NS,NT,NR}
    w::T
    rho::T
    ystrip::T
    stirling::NTuple{NS,T}  # B_2k / (2k (2k - 1)), k = 1, ..., N - 1
    taylor1::NTuple{NT,T}   # -γ, then (-1)^k ζ(k) / k, k = 2, ..., K
    taylor2::NTuple{NT,T}   # 1 - γ, then (-1)^k (ζ(k) - 1) / k, k = 2, ..., K
    rgamma::NTuple{NR,T}    # c_j of 1/gamma(1 + t) = sum_j c_j t^j, j = 0, ..., KR
    halflog2pi::T
    logpi::T
    pi::T
    halfpi::T
    twopi::T
end

# B_2, B_4, ..., B_2n exactly, by the Akiyama-Tanigawa algorithm
function _bernoulli_even(n::Int)
    a = Vector{Rational{BigInt}}(undef, 2n + 1)
    b = Rational{BigInt}[]
    for m in 0:(2n)
        a[m + 1] = 1 // big(m + 1)
        for j in m:-1:1
            a[j] = j * (a[j] - a[j + 1])
        end
        m >= 2 && iseven(m) && push!(b, a[1])
    end
    return b
end

function LogGammaConstants{T}(w::Int, N::Int, K::Int, ystrip::Int, KR::Int) where {T}
    # the strip takes the principal log of 1/gamma(u) as lg's branch: max |Im lg(u)| over Re u in [1/2, 3/2],
    # |Im u| <= ystrip is 3.002 at ystrip = 4 and 3.738 > π at 4.5
    ystrip <= 4 || throw(
        ArgumentError(
            "ystrip = $ystrip: the strip's principal log is lg's branch only up to 4"
        ),
    )
    # 1024 bits: the recurrence for c_j cancels about 280 bits by j = 84
    return setprecision(BigFloat, 1024) do
        r(x::BigFloat) = convert(T, x)
        bern = _bernoulli_even(N - 1)
        st = ntuple(k -> r(BigFloat(bern[k] / (2k * (2k - 1)))), N - 1)
        γ = BigFloat(MathConstants.eulergamma)
        ζ = [k == 1 ? γ : SpecialFunctions.zeta(BigFloat(k)) for k in 1:max(K, KR)]  # ζ[1] holds γ
        t1 = ntuple(k -> k == 1 ? r(-γ) : r((-1)^k * ζ[k] / k), K)
        t2 = ntuple(k -> k == 1 ? r(1 - γ) : r((-1)^k * (ζ[k] - 1) / k), K)
        # 1/gamma(1 + t) = exp(-lg(1 + t)) = exp(sum_k g_k t^k), g_1 = γ, g_k = (-1)^(k+1) ζ(k)/k: n c_n = sum k g_k c_(n-k)
        g = [k == 1 ? γ : (-1)^(k + 1) * ζ[k] / k for k in 1:KR]
        c = [one(BigFloat)]
        for n in 1:KR
            push!(c, sum(k * g[k] * c[n - k + 1] for k in 1:n) / n)
        end
        p = BigFloat(π)
        return LogGammaConstants{T,N - 1,K,KR + 1}(
            T(w),
            T(0.1),
            T(ystrip),
            st,
            t1,
            t2,
            ntuple(j -> r(c[j]), KR + 1),
            r(log(2p) / 2),
            r(log(p)),
            r(p),
            r(p / 2),
            r(2p),
        )
    end
end

# c[1] + t (c[2] + t (c[3] + ...)), Horner
@inline function _horner(c::NTuple{N,T}, t::Complex{T}) where {N,T}
    s = Complex(c[N], zero(T))
    @inbounds for k in (N - 1):-1:1
        s = s * t + c[k]
    end
    return s
end

# the principal log; |w| by hypot, since the type's complex log squares the parts and overflows past 2^512
_log(w::Complex) = Complex(log(abs(w)), atan(imag(w), real(w)))

# Stirling's series: (z - 1/2) log z - z + log(2π)/2 + sum_k B_2k / (2k (2k - 1) z^(2k - 1)), Horner in 1/z^2
function _loggamma_stirling(z::Complex{T}, C::LogGammaConstants{T}) where {T}
    a = abs(z)
    zinv = conj(z / a) / a  # the type's inv(z) squares the parts and returns NaN past 2^511
    return (z - T(0.5)) * _log(z) - z +
           C.halflog2pi +
           zinv * _horner(C.stirling, zinv * zinv)
end

# log(f(1) f(2) ... f(n)) on the continuous branch, each factor's argument in [0, π): the principal log of the
# product plus 2πi times the count of + to - sign flips of the partial products' imaginary parts (Hare's
# Proposition 2.2); n >= 1
@inline function _log_prod(f, n::Int, C::LogGammaConstants)
    p = f(1)
    sb = false
    signflips = 0
    for j in 2:n
        p *= f(j)
        sb′ = signbit(imag(p))
        signflips += sb′ & (sb′ != sb)
        sb = sb′
    end
    l = _log(p)
    return Complex(real(l), imag(l) + signflips * C.twopi)
end

# log sin(πz) for Im z >= 0, z not a pole: the principal branch of Base's log(sinpi(z)), Im z = +0 taken from above.
# Built from the real sinpi, cospi, sinh and cosh (Base's complex sinpi allocates for this type); x is reduced exactly
# to [-1/2, 1/2] first, since the type's sinpi rounds its argument to 113 bits and so loses the distance to an
# integer; the imaginary part of a real argument is set here, since the type's products and log lose a zero's sign.
function _log_sinpi(x::T, y::T, C::LogGammaConstants{T}) where {T}
    if isinteger(2x)  # sin(πx) is ±0 or ±1 exactly, cos(πx) ±1 or 0, as Base's sinpi takes them
        if isinteger(x)  # y > 0 here: sin(πz) = ±i sinh(πy)
            return Complex(log(_sinh(C.pi * y)), isodd(x) ? -C.halfpi : C.halfpi)
        end
        return Complex(log(_cosh(C.pi * y)), isinteger((2x - 1) / 4) ? zero(T) : C.pi)
    end
    n = round(x)
    s, c = sinpi(x - n), cospi(x - n)  # x - n is exact
    if isodd(n)
        s, c = -s, -c
    end
    if iszero(y)  # sin(π(x + i0)) = sin(πx) + i0 cos(πx): the sign of cos(πx) chooses the side of a negative sine
        return Complex(log(abs(s)), signbit(s) ? (signbit(c) ? -C.pi : C.pi) : zero(T))
    end
    py = C.pi * y
    return _log(Complex(s * _cosh(py), c * _sinh(py)))
end

# sinh and cosh for log sin(πz), whose error enters lg with weight one: Double64's own err by up to 26 units of 2^-106
# relative, so they go through Float128 (113 bits) as Double64's sinpi and cospi do
_sinh(x) = sinh(x)
_cosh(x) = cosh(x)
_sinh(x::Double64) = Double64(sinh(Float128(x)))
_cosh(x::Double64) = Double64(cosh(Float128(x)))

function _loggamma(z::Complex{T}, C::LogGammaConstants{T}) where {T}
    x, y = reim(z)
    if !isfinite(x) || !isfinite(y)  # SpecialFunctions' table for Complex{Float64}
        if isinf(x) && isfinite(y)
            return Complex(
                x, x > 0 ? (iszero(y) ? y : copysign(T(Inf), y)) : copysign(T(Inf), -y)
            )
        elseif isfinite(x) && isinf(y)
            return Complex(T(-Inf), y)
        else
            return Complex(T(NaN), T(NaN))
        end
    elseif signbit(y)
        return conj(_loggamma(Complex(x, -y), C))
    elseif x >= C.w || y >= C.w
        return _loggamma_stirling(z, C)
    elseif abs(x - 1) + y < C.rho
        t = Complex(x - 1, y)
        return t * _horner(C.taylor1, t)
    elseif abs(x - 2) + y < C.rho
        t = Complex(x - 2, y)
        return t * _horner(C.taylor2, t)
    elseif x < T(0.5)
        if iszero(y) && isinteger(x)  # a pole: Im is the upper side's just right of it, and -π at -0.0 as SpecialFunctions
            return Complex(T(Inf), iszero(x) ? (signbit(x) ? -C.pi : -zero(T)) : x * C.pi)
        end
        # Hare's Proposition 3.1: log π - log sin(πz) - lg(1 - z) + 2πi floor(x/2 + 1/4) for Im z >= 0
        return Complex(C.logpi, C.twopi * floor(x / 2 + T(0.25))) - _log_sinpi(x, y, C) -
               _loggamma(1 - z, C)
    elseif y < C.ystrip
        # lg(z) = lg(u) + log(u (u + 1) ... (u + m - 1)), u = z - m, Re u in [1/2, 3/2)
        m = Int(floor(x - T(0.5)))
        u = Complex(x - m, y)
        # lg(u) = -log(1/gamma(u)), the Taylor series of 1/gamma(1 + t) at t = u - 1; |Im lg(u)| < 3.01 < π there, so
        # the principal log is lg's branch
        lu = -_log(_horner(C.rgamma, u - 1))
        return m == 0 ? lu : lu + _log_prod(j -> u + (j - 1), m, C)
    end
    # lg(z) = lg(ζ) - log(z (z + 1) ... (z + r - 1)), ζ = z + r, Re ζ >= w, with each log(z + k) written as
    # log ζ + log(1 - (r - k)/ζ), so that no term is of the size of lg(ζ):
    # lg(z) = (z - 1/2) log ζ - ζ + log(2π)/2 + sum_k B_2k / (2k (2k - 1) ζ^(2k - 1)) - log((1 - 1/ζ) ... (1 - r/ζ)),
    # each factor's argument in (0, π/2)
    r = Int(ceil(C.w - x))
    ζ = Complex(x + r, y)
    # 1/ζ with one Newton step: inv's own error, up to 5.6 u, would enter all r factors alike, with weight
    # sum_j |j/(ζ - j)| up to 22; a new name, since the closure below would box a reassigned one
    ζ0 = inv(ζ)
    ζinv = ζ0 + ζ0 * (1 - ζ * ζ0)
    return (z - T(0.5)) * _log(ζ) - ζ +
           C.halflog2pi +
           ζinv * _horner(C.stirling, ζinv * ζinv) - _log_prod(j -> 1 - j * ζinv, r, C)
end

# 106 bits: (w, N) = (16, 21), the cheapest w whose N meets Hare's bound 4 sqrt(πN) |T_N(w)| <= 2^-108; K = 35 Taylor
# terms meet 2^-108 relative in the diamonds of radius 1/10; ystrip = 4, the largest the strip's branch allows, where
# the rearranged upward shift above it errs by at most 13.2 u (it erred by 31 u at y = 4 before the rearrangement);
# KR = 83, past which every term |c_j| |t|^j is below 2^-112 on |t| <= sqrt(1/4 + 4^2)
const _LOGGAMMA_DOUBLE64 = LogGammaConstants{Double64}(16, 21, 35, 4, 83)

SpecialFunctions.loggamma(z::Complex{Double64}) = _loggamma(z, _LOGGAMMA_DOUBLE64)
