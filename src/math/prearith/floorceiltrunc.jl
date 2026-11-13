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

# to an integer type, every width: the value rounded here, then converted exactly (Base's own methods
# differ between Julia versions and before 1.11 need a trunc of their own for each type)
for f in (:floor, :ceil, :trunc, :round)
    @eval $f(::Type{I}, x::DoubleFloat{T}) where {I<:Base.BitInteger, T<:IEEEFloat} = I($f(x))
    @eval $f(::Type{Integer}, x::DoubleFloat{T}) where {T<:IEEEFloat} = Int($f(x))
end
round(::Type{I}, x::DoubleFloat{T}, r::RoundingMode) where {I<:Base.BitInteger, T<:IEEEFloat} = I(round(x, r))
round(::Type{Integer}, x::DoubleFloat{T}, r::RoundingMode) where {T<:IEEEFloat} = Int(round(x, r))

# For a finite non-integer x: x = n + f exactly with n = nh + nl an integer and 0 < |f| < 1 (f takes the low
# limb's sign when the high limb is an integer); returns nh, nl, sign(f) and cmp(|f|, 1/2), decided on the limbs
function intfrac(x::DoubleFloat{T}) where {T<:IEEEFloat}
    hi, lo = HILO(x)
    if isinteger(hi)
        t = trunc(lo)
        d = lo - t # exact
        return hi, t, sign(d), cmp(abs(d), T(0.5))
    end
    t = trunc(hi)
    d = hi - t # exact; |lo| <= ulp(hi)/2 carries hi + lo past no integer and no half-integer
    c = cmp(abs(d), T(0.5))
    if iszero(c) && !iszero(lo) # hi is a half-integer: lo breaks the tie
        c = signbit(lo) == signbit(d) ? 1 : -1
    end
    return t, zero(T), sign(d), c
end

# The integer nearest x; at a tie, n + sign(f) when away(nh, nl, sign(f)), else n
function nearest(x::DoubleFloat{T}, away::F) where {T<:IEEEFloat, F}
    (isinteger(x) || !isfinite(HI(x))) && return x
    nh, nl, s, c = intfrac(x)
    k = (c > 0 || (iszero(c) && away(nh, nl, s))) ? s : zero(T)
    hi, lo = two_sum(nh, nl + k) # nl + k is exact: |nl| < 2^(precision(T)-1)
    return DoubleFloat{T}(copysign(hi, HI(x)), lo) # a zero takes x's sign, as Base's
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

# a tie to the even integer, the parity of nh + nl (nh is even when nl is not zero)
function round(x::DoubleFloat{T}, ::RoundingMode{:Nearest}) where {T<:IEEEFloat}
    return nearest(x, (nh, nl, s) -> xor(isodd(nh), isodd(nl)))
end

function round(x::DoubleFloat{T}, ::RoundingMode{:NearestTiesAway}) where {T<:IEEEFloat}
    return nearest(x, (nh, nl, s) -> signbit(s) == signbit(x)) # n + s is the farther from zero
end

function round(x::DoubleFloat{T}, ::RoundingMode{:NearestTiesUp}) where {T<:IEEEFloat}
    return nearest(x, (nh, nl, s) -> s > 0)
end

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
