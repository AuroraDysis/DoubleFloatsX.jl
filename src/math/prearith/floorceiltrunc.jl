function floor(x::DoubleFloat{T}) where {T<:IEEEFloat}
    isinteger(x) && return x
    if isinteger(HI(x)) # LO(x) is mixed or fractional: hi + floor(lo), renormalized
        DoubleFloat(HI(x), floor(LO(x)))
    else # HI(x) is mixed or fractional
        DoubleFloat{T}(floor(HI(x)), zero(T))
    end
end

ceil(x::DoubleFloat{T}) where {T<:IEEEFloat} = -floor(-x)

function trunc(x::DoubleFloat{T}) where {T<:IEEEFloat}
    signbit(x) ? ceil(x) : floor(x)
end

# For a finite non-integer x: x = t + f exactly with t = th + tl = trunc(x), which cannot overflow T
# (|tl| <= 2^(precision(T)-1)), and 0 < |f| < 1 of x's sign; returns th, tl and cmp(|f|, 1/2), decided on the limbs
function truncfrac(x::DoubleFloat{T}) where {T<:IEEEFloat}
    hi, lo = HILO(x)
    if isinteger(hi)
        t = trunc(lo)
        d = lo - t # exact, of lo's sign
        c = cmp(abs(d), T(0.5))
        signbit(d) == signbit(hi) && return hi, t, c
        return hi, t + sign(d), -c # lo against hi's sign: trunc(x) is hi + t + sign(d), |f| is 1 - |d|
    end
    t = trunc(hi)
    d = hi - t # exact; |lo| <= ulp(hi)/2 carries hi + lo past no integer and no half-integer
    c = cmp(abs(d), T(0.5))
    if iszero(c) && !iszero(lo) # hi is a half-integer: lo breaks the tie
        c = signbit(lo) == signbit(d) ? 1 : -1
    end
    return t, zero(T), c
end

# Whether rounding by the mode leaves trunc(x) for the next integer from zero, from c = cmp(|x - trunc(x)|, 1/2),
# the parity of trunc(x) and the sign of x
roundsaway(::RoundingMode{:ToZero}, c, odd, neg) = false
roundsaway(::RoundingMode{:FromZero}, c, odd, neg) = true
roundsaway(::RoundingMode{:Up}, c, odd, neg) = !neg
roundsaway(::RoundingMode{:Down}, c, odd, neg) = neg
roundsaway(::RoundingMode{:Nearest}, c, odd, neg) = c > 0 || (iszero(c) && odd) # a tie to even
roundsaway(::RoundingMode{:NearestTiesAway}, c, odd, neg) = c >= 0
roundsaway(::RoundingMode{:NearestTiesUp}, c, odd, neg) = c > 0 || (iszero(c) && !neg)

isoddsum(th, tl) = xor(isodd(th), isodd(tl)) # the parity of th + tl, two integers

# The integer nearest x, a tie decided by the mode
function nearest(x::DoubleFloat{T}, r::RoundingMode) where {T<:IEEEFloat}
    (isinteger(x) || !isfinite(HI(x))) && return x
    th, tl, c = truncfrac(x)
    k = roundsaway(r, c, isoddsum(th, tl), signbit(HI(x))) ? copysign(one(T), HI(x)) : zero(T)
    hi, lo = two_sum(th, tl + k) # tl + k is exact
    return DoubleFloat{T}(copysign(hi, HI(x)), lo) # a zero takes x's sign, as Base's
end

# To an integer type, every width, decided on the limbs: trunc(x) converted exactly, then one step from zero or
# none. Rounding in T first would overflow T next to floatmax(T), where a wide integer type still holds the result.
function round(::Type{I}, x::DoubleFloat{T}, r::RoundingMode) where {I<:Base.BitInteger, T<:IEEEFloat}
    (isinteger(x) || !isfinite(HI(x))) && return I(x)
    th, tl, c = truncfrac(x)
    neg = signbit(HI(x))
    n = I(DoubleFloat(th, tl)) # when trunc(x) is beyond I, so is the result, n or one further from zero
    roundsaway(r, c, isoddsum(th, tl), neg) || return n
    m, overflow = neg ? Base.Checked.sub_with_overflow(n, one(I)) : Base.Checked.add_with_overflow(n, one(I))
    overflow && throw(InexactError(nameof(I), I, x))
    return m
end
for (J, K) in ((:Integer, :Int), (:Signed, :Int), (:Unsigned, :UInt))
    @eval round(::Type{$J}, x::DoubleFloat{T}, r::RoundingMode) where {T<:IEEEFloat} = round($K, x, r)
end
# Base's own methods differ between Julia versions, and before 1.11 need a trunc for each type
for (f, r) in ((:floor, :RoundDown), (:ceil, :RoundUp), (:trunc, :RoundToZero), (:round, :RoundNearest))
    @eval $f(::Type{I}, x::DoubleFloat{T}) where {I<:Base.BitInteger, T<:IEEEFloat} = round(I, x, $r)
    for J in (:Integer, :Signed, :Unsigned)
        @eval $f(::Type{$J}, x::DoubleFloat{T}) where {T<:IEEEFloat} = round($J, x, $r)
    end
end

round(x::DoubleFloat{T}) where {T<:IEEEFloat} = round(x, RoundNearest)

function round(x::DoubleFloat{T}, ::RoundingMode{:Up}) where {T<:IEEEFloat}
    return ceil(x)
end

function round(x::DoubleFloat{T}, ::RoundingMode{:Down}) where {T<:IEEEFloat}
    return floor(x)
end

function round(x::DoubleFloat{T}, ::RoundingMode{:ToZero}) where {T<:IEEEFloat}
    return isnegative(x) ? ceil(x) : floor(x)
end

function round(x::DoubleFloat{T}, ::RoundingMode{:FromZero}) where {T<:IEEEFloat}
    return isnegative(x) ? floor(x) : ceil(x)
end

round(x::DoubleFloat{T}, r::RoundingMode{:Nearest}) where {T<:IEEEFloat} = nearest(x, r)
round(x::DoubleFloat{T}, r::RoundingMode{:NearestTiesAway}) where {T<:IEEEFloat} = nearest(x, r)
round(x::DoubleFloat{T}, r::RoundingMode{:NearestTiesUp}) where {T<:IEEEFloat} = nearest(x, r)

"""
     spread(x)
the nearest integer to x, away from zero
spread complements trunc()
"""
function spread(x::DoubleFloat{T}) where {T<:IEEEFloat}
    (!isfinite(x) || isinteger(x)) && return x
    if isinteger(HI(x))
        if signbit(LO(x))
              signbit(HI(x)) ? DoubleFloat{T}(HI(x)-one(T), zero(T)) : DoubleFloat{T}(HI(x), zero(T))
        else
              signbit(HI(x)) ? DoubleFloat{T}(HI(x), zero(T)) : DoubleFloat{T}(HI(x)+one(T), zero(T))
        end
    else
        signbit(HI(x)) ? DoubleFloat{T}(floor(HI(x)), zero(T)) :  DoubleFloat{T}(ceil(HI(x)), zero(T))
    end
end

function spread(x::T) where {T<:IEEEFloat}
    (!isfinite(x) || isinteger(x)) && return x
    return trunc(x + sign(x))
end

"""
    tld(x, y)
Truncate the result of x/y.
"""
tld(x::T, y::T) where {T<:IEEEFloat} = trunc(x/y)

"""
    sld(x, y)
Spread the result of x/y.
""" sld
sld(x::T, y::T) where {T<:IEEEFloat} = spread(x/y)

for (F,G) in ((:tld, :trunc), (:sld, :spread))
    @eval begin
        function $F(x::DoubleFloat{T}, y::DoubleFloat{T}) where {T<:IEEEFloat}
            z = x / y
            return $G(z)
        end
    end
end

for (F,G) in ((:fld, :floor), (:cld, :ceil), (:tld, :trunc), (:sld, :spread))
    @eval begin
        function $F(x::DoubleFloat{T}, y::T1) where {T<:IEEEFloat, T1<:IEEEFloat}
            z = x / y
            return $G(z)
        end
        function $F(x::T1, y::DoubleFloat{T}) where {T<:IEEEFloat, T1<:IEEEFloat}
            z = x / y
            return $G(z)
        end
    end
end
