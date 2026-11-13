# Integer conversions and rounding to integers (DFX-002, DFX-003, DFX-004): every case is checked against the exact
# value of its two limbs, computed in BigFloat at a precision that holds any DoubleFloat exactly.
module IntegerTests

using DoubleFloatsX, Test, Random

const WIDTHS = (Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128)
const MODES = (
    RoundNearest,
    RoundNearestTiesAway,
    RoundNearestTiesUp,
    RoundToZero,
    RoundFromZero,
    RoundUp,
    RoundDown,
)
# a Double64's limbs span at most 2^1024 down to 2^-1074, 2098 bits, plus 53
const ORACLE_BITS = 2200

function exact(x::DoubleFloat)
    return setprecision(() -> BigFloat(HI(x)) + BigFloat(LO(x)), BigFloat, ORACLE_BITS)
end

# the integer the exact value rounds to under r, decided in exact arithmetic
function oracle(x::DoubleFloat, r::RoundingMode)
    return setprecision(BigFloat, ORACLE_BITS) do
        b = exact(x)
        f = floor(BigInt, b)
        d = b - f # exact, 0 <= d < 1
        frac = !iszero(d)
        r == RoundDown && return f
        r == RoundUp && return f + frac
        r == RoundToZero && return b < 0 ? f + frac : f
        r == RoundFromZero && return b < 0 ? f : f + frac
        c = cmp(2d, 1)
        c < 0 && return f
        c > 0 && return f + 1
        r == RoundNearest && return isodd(f) ? f + 1 : f
        r == RoundNearestTiesAway && return b < 0 ? f : f + 1
        r == RoundNearestTiesUp && return f + 1
        return error("no oracle for $r")
    end
end

inrange(::Type{I}, v::Integer) where {I} = typemin(I) <= v <= typemax(I)

# f() returns I(v) when v is an integer in I's range, and throws InexactError otherwise
function exact_or_throws(f, ::Type{I}, v) where {I}
    if v isa Integer && inrange(I, v)
        r = f()
        @test r isa I && r == v
    else
        @test_throws InexactError f()
    end
end

# canonical two-limb values: the normalising constructor, except for the signed zeros
dd(::Type{T}, hi, lo=0) where {T} = DoubleFloat(T(hi), T(lo))
function from_integer(::Type{T}, v::Integer) where {T}
    hi = T(v)
    isfinite(hi) || return DoubleFloat{T}(hi, zero(T))
    return DoubleFloat(hi, T(v - BigInt(hi)))
end

function cases(::Type{T}) where {T}
    p = precision(T)
    emax = exponent(floatmax(T))
    xs = DoubleFloat{T}[]
    for h in (0.0, -0.0), l in (0.0, -0.0)
        push!(xs, DoubleFloat{T}(T(h), T(l)))
    end
    tiny(h) = ldexp(one(T), exponent(T(h)) - p - 2)
    for v in (0.25, 0.3, 0.5, 0.75, 1, 1.5, 2, 2.5, 2.7, 3, 3.5, 4.5, 7, 100.5, 1000)
        push!(xs, dd(T, v), dd(T, -v))
        push!(
            xs,
            dd(T, v, tiny(v)),
            dd(T, v, -tiny(v)),
            dd(T, -v, tiny(v)),
            dd(T, -v, -tiny(v)),
        )
    end
    # large sparse integers and last-limb fractions and ties
    for k in (p - 1, p, p + 1, p + 7, 2p - 2, 2p + 4, 2p + 40), m in (0, 1, 2), s in (1, -1)
        k + 1 <= emax || continue
        hi = s * (ldexp(one(T), k) + m * ldexp(one(T), k - p + 1))
        for lo in (0.25, 0.5, 1, 1.5, 2.5, 3, 3.5, -0.25, -0.5, -1, -1.5, -2.5, -3, -3.5)
            push!(xs, dd(T, hi, lo))
        end
        push!(xs, DoubleFloat{T}(T(hi), -zero(T)))
    end
    # the limits of every width, their neighbours, and the edge typemax(I) + 1 with lo of either sign
    for I in WIDTHS, v in (typemin(I), typemax(I))
        for dv in (-1, 0, 1)
            push!(xs, from_integer(T, big(v) + dv))
        end
        e = ldexp(1.0, 8 * sizeof(I) - (I <: Signed))
        T(e) < floatmax(T) || continue
        for lo in (-1, -0.5, -0.0, 0.0, 0.5, 1, -2.5, -3), s in (1, -1)
            push!(xs, dd(T, s * e, lo))
        end
    end
    push!(xs, DoubleFloat{T}(T(-3), -zero(T))) # an integer with a -0.0 low limb
    # random values, integers and fractions, of every magnitude a width can hold
    rng = Xoshiro(20261113)
    for _ in 1:200
        e = rand(rng, 0:min(emax - 1, 2p + 8))
        hi = ldexp(T(rand(rng, 1:(2 ^ (p - 1)))), e - p + 1) * rand(rng, (1, -1))
        lo = if e < p
            ldexp(T(rand(rng) - 0.5), e - p - rand(rng, 1:3))
        else
            T(rand(rng, -8:8) / 2) + rand(rng, (0, 1)) * ldexp(T(rand(rng) - 0.5), -p)
        end
        push!(xs, DoubleFloat(hi, lo), DoubleFloat(round(hi), lo))
    end
    return filter(x -> isfinite(HI(x)), xs)
end

canonical(x::DoubleFloat) = HI(x) + LO(x) == HI(x)

@testset "integer conversions $T" for T in (Float16, Float32, Float64)
    for x in cases(T)
        @test canonical(x)
        b = exact(x)
        v = isinteger(b) ? BigInt(b) : nothing
        for I in WIDTHS
            exact_or_throws(() -> I(x), I, v)
            exact_or_throws(() -> convert(I, x), I, v)
        end
        exact_or_throws(() -> Integer(x), Int, v)
        exact_or_throws(() -> Signed(x), Int, v)
        exact_or_throws(() -> Unsigned(x), UInt, v)
    end
    for x in (
        DoubleFloat{T}(T(NaN), zero(T)),
        DoubleFloat{T}(T(Inf), zero(T)),
        DoubleFloat{T}(T(-Inf), zero(T)),
    )
        for I in WIDTHS
            @test_throws InexactError I(x)
            @test_throws InexactError convert(I, x)
            @test_throws InexactError round(I, x)
        end
    end
end

@testset "rounding to integers $T" for T in (Float16, Float32, Float64)
    for x in cases(T)
        for r in MODES
            want = oracle(x, r)
            y = round(x, r)
            @test exact(y) == want
            @test canonical(y) && isinteger(HI(y)) && isinteger(LO(y))
            @test signbit(y) == signbit(x) # a zero takes x's sign, as Base's
            for I in WIDTHS
                exact_or_throws(() -> round(I, x, r), I, want)
            end
        end
        for (f, r) in (
            (floor, RoundDown), (ceil, RoundUp), (trunc, RoundToZero), (round, RoundNearest)
        )
            want = oracle(x, r)
            @test exact(f(x)) == want
            for I in WIDTHS
                exact_or_throws(() -> f(I, x), I, want)
            end
            exact_or_throws(() -> f(Integer, x), Int, want)
        end
    end
    for r in MODES
        @test isnan(round(DoubleFloat{T}(T(NaN), zero(T)), r))
        @test round(DoubleFloat{T}(T(Inf), zero(T)), r) == T(Inf)
        @test round(DoubleFloat{T}(T(-Inf), zero(T)), r) == T(-Inf)
    end
end

# fixed cases: the boundary hi = 2^(n-1) with lo < 0, the last-limb ties, and the upstream defects
@testset "integer boundaries" begin
    @test Int64(DoubleFloat{Float64}(2.0^63, -1.0)) === typemax(Int64)
    @test Int64(DoubleFloat{Float64}(2.0^63, -1024.0)) === typemax(Int64) - 1023
    @test_throws InexactError Int64(DoubleFloat{Float64}(2.0^63, 0.0))
    @test_throws InexactError Int64(DoubleFloat{Float64}(2.0^63, -0.0))
    @test Int64(DoubleFloat{Float64}(-2.0^63, 1.0)) === typemin(Int64) + 1
    @test_throws InexactError Int64(DoubleFloat{Float64}(-2.0^63, -1.0))
    @test Int128(DoubleFloat{Float64}(2.0^127, -1.0)) === typemax(Int128)
    @test UInt128(DoubleFloat{Float64}(2.0^128, -1.0)) === typemax(UInt128)
    @test UInt64(DoubleFloat{Float64}(2.0^64, -1.0)) === typemax(UInt64)
    @test Int16(DoubleFloat{Float16}(Float16(2^15), Float16(-1))) === typemax(Int16)
    @test_throws InexactError Int128(DoubleFloat{Float64}(2.0^110, 0.25))
    @test_throws InexactError Int64(Double64(2.5))
    @test UInt8(DoubleFloat{Float64}(-0.0, -0.0)) === 0x00
    @test convert(Int32, Double64(5)) === Int32(5)
end

@testset "last-limb ties" begin
    D(hi, lo) = DoubleFloat(hi, lo)
    @test round(D(2.0^60, 3.5)) == D(2.0^60, 4.0)
    @test round(D(2.0^60, 2.5)) == D(2.0^60, 2.0)
    @test round(D(2.0^60, -2.5)) == D(2.0^60, -2.0)
    @test round(D(2.0^53 + 2, -0.5)) == D(2.0^53 + 2, 0.0)
    @test round(D(2.5, 2.0^-60)) == 3
    @test round(D(2.5, -2.0^-60)) == 2
    @test round(D(-2.5, 2.0^-60)) == -2
    @test round(Int64, D(2.0^60, 3.5)) === 2^60 + 4
    @test round(Int64, D(2.0^60, 3.5), RoundNearestTiesAway) === 2^60 + 4
    @test round(Int64, D(2.0^60, -3.5), RoundNearestTiesAway) === 2^60 - 3
    @test round(Int64, D(-2.0^60, 3.5), RoundNearestTiesAway) === -2^60 + 3
    @test round(Int64, D(2.0^60, -3.5), RoundNearestTiesUp) === 2^60 - 3
    @test ceil(D(2.0^53, 0.5)) == D(2.0^53, 1.0)
    @test floor(D(2.0^53 + 2, -0.5)) == D(2.0^53, 1.0)
end

@testset "DFX-003: ceil and trunc of an exact integer" begin
    @test ceil(Double64(3.0)) == 3
    @test ceil(Double64(-3.0)) == -3
    @test trunc(Double64(-3.0)) == -3
    @test Int(floor(DoubleFloat{Float64}(-3.0, -0.0))) === -3 # upstream's == tells a -0.0 low limb from +0.0
    @test Int(floor(DoubleFloat{Float64}(3.0, -0.0))) === 3
    @test ceil(Int, Double64(9.0)) === 9
    # x + copysign(0.5, x) at the ties 2.5 and -2.5
    @test ceil(Double64(2.5) + 0.5) == 3
    @test trunc(Double64(-2.5) - 0.5) == -3
    @test ceil(Double64(-2.5) - 0.5) == -3
    @test trunc(Double64(-2.5) + 0.5) == -2
    @test cld(Double64(6), Double64(3)) == 2
    @test div(Double64(-6), Double64(3)) == -2
end

@testset "DFX-004: round ties to even as Base's" begin
    for v in (2.5, -2.5, 3.5, 2.7, 4.6, -2.7, 1.7, 2.3, 0.5, -0.5, 1.5)
        @test round(Double64(v)) == round(v)
        @test round(Int, Double64(v)) === round(Int, v)
        for r in MODES
            @test round(Double64(v), r) == round(v, r)
            @test round(Int, Double64(v), r) === round(Int, v, r)
        end
    end
end

# allocations after warm-up, with the target type a static parameter
nalloc(f::F, ::Type{I}, x) where {F,I} = (f(I, x); @allocated f(I, x))
function nalloc(::Type{I}, x, r::RoundingMode) where {I}
    return (round(I, x, r); @allocated round(I, x, r))
end
nalloc_ctor(::Type{I}, x) where {I} = (I(x); @allocated I(x))
nalloc_hot(s) = (ceil(Int, s^2); @allocated ceil(Int, s^2))

@testset "integer conversions allocate nothing $T" for T in (Float16, Float32, Float64)
    n = DoubleFloat{T}(T(5), zero(T))
    y = DoubleFloat(T(5.5), ldexp(one(T), -precision(T) - 4))
    for I in WIDTHS
        @test nalloc_ctor(I, n) == 0
        @test nalloc(convert, I, n) == 0
        for f in (round, floor, ceil, trunc)
            @test nalloc(f, I, y) == 0
        end
        for r in MODES
            @test nalloc(I, y, r) == 0
        end
    end
end

@testset "ceil(Int, s^2) allocates nothing" begin
    @test nalloc_hot(Double64(3) + Double64(2.0)^-60) == 0
    @test ceil(Int, (Double64(3) + Double64(2.0)^-60)^2) === 10
    @test ceil(Int, Double64(3)^2) === 9
end

end # module IntegerTests
