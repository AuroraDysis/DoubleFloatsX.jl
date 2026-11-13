# For Double64 the hi limb IS the correctly rounded Float64; for the narrower
# types Float64 can hold both limbs, so dropping lo would lose up to 2^-24
# (2^-11) of relative accuracy for Double32 (Double16).
@inline Base.Float64(x::DoubleFloat{Float64}) = HI(x)
@inline Base.Float64(x::DoubleFloat{T}) where {T<:IEEEFloat} = Float64(HI(x)) + Float64(LO(x))
@inline Base.Float32(x::DoubleFloat{T}) where {T<:IEEEFloat} = Float32(Float64(x))
@inline Base.Float16(x::DoubleFloat{T}) where {T<:IEEEFloat} = Float16(Float64(x))

# Exact, or InexactError, as Base's for an IEEEFloat; computed on the limbs, which are integers when the
# value is (hi is fl(x), so lo = x - hi is an integer once hi is one)
function (::Type{I})(x::DoubleFloat{T}) where {I<:Base.BitInteger, T<:IEEEFloat}
    hi, lo = HILO(x)
    (isinteger(hi) && isinteger(lo)) || throw(InexactError(nameof(I), I, x))
    # hi = typemax(I) + 1, beyond I, is in range when lo < 0
    if Float64(hi) == ldexp(1.0, 8 * sizeof(I) - (I <: Signed))
        lo < 0 || throw(InexactError(nameof(I), I, x))
        return typemax(I) - (I(-lo) - one(I))
    end
    n = I(hi) # InexactError for any other hi out of range, and then x is out of range too
    r, overflow = signbit(lo) ? Base.Checked.sub_with_overflow(n, I(-lo)) : Base.Checked.add_with_overflow(n, I(lo))
    overflow && throw(InexactError(nameof(I), I, x))
    return r
end

Base.Integer(x::DoubleFloat{T}) where {T<:IEEEFloat} = Int(x)
Base.Signed(x::DoubleFloat{T}) where {T<:IEEEFloat} = Int(x)
Base.Unsigned(x::DoubleFloat{T}) where {T<:IEEEFloat} = UInt(x)

@inline Base.BigFloat(x::DoubleFloat{T}) where {T<:IEEEFloat} = BigFloat(HI(x)) + BigFloat(LO(x))
@inline Base.BigInt(x::DoubleFloat{T}) where {T<:IEEEFloat} = BigInt(BigFloat(x))

for (F,D) in ((:Float64, :Double64), (:Float32, :Double32), (:Float16, :Double16))
  @eval begin
    function $D(x::BigFloat)
        hi = $F(x)
        lo = $F(x - hi)
        return $D(hi, lo)
    end
    $D(x::BigInt) = $D(BigFloat(x))
  end
end

Double64(x::Int128) = Double64(BigInt(x))
Double32(x::Int128) = Double32(BigInt(x))
Double16(x::Int128) = Double16(BigInt(x))

# constants for BigFloat precision are > 2*significandbits(DoubleT)
Double64(x::Irrational{S}) where {S} = Double64(BigFloat(x; precision=250))
Double32(x::Irrational{S}) where {S} = Double32(BigFloat(x; precision=122))
Double16(x::Irrational{S}) where {S} = Double16(BigFloat(x; precision=60))

Double64(x::Rational{S}) where {S} = Double64(BigFloat(x; precision=250))
Double32(x::Rational{S}) where {S} = Double32(BigFloat(x; precision=122))
Double16(x::Rational{S}) where {S} = Double16(BigFloat(x; precision=60))

Complex{Double64}(x::T) where {T<:AbstractIrrational} = Complex(Double64(x))
Complex{Double32}(x::T) where {T<:AbstractIrrational} = Complex(Double32(x))
Complex{Double16}(x::T) where {T<:AbstractIrrational} = Complex(Double16(x))
