using DoubleFloatsX, Test
using Gamma: Gamma
using HypergeometricFunctions: HypergeometricFunctions
using SpecialFunctions: SpecialFunctions

const SF = SpecialFunctions

# The complex loggamma of Double64 against Arb's acb_lgamma (test/fixtures/loggamma_arb.tsv, written by
# tools/loggamma/fixture.jl), two identities that need no reference, 2F1 through Gamma.jl against Arb's 2F1, the
# special values and the allocation. Errors are in u = 2^-106: per component, of max(1, |lg|); in the Taylor diamonds
# at 1 and 2, normwise relative to |lg|.

# The bound per region, in u. Basis: the largest error against Arb (2026-11-14), over 1100000 points of
# tools/loggamma/sweep.jl (100000 per band) and 1000000 more in each corner band, where the upward shift meets the strip
# at Im z = 4: Stirling 4.05, strip 6.36, upward shift 14.52, reflection 14.46; relative in the diamonds 4.00 at 1 and
# 4.03 at 2; the fixture's tiny arguments and pole offsets at most 1.8 and its near-overflow points 0.7.
const LG_BOUND = (stirling=8, taylor1=5, taylor2=5, reflection=24, strip=8, upward=24)

# the kernel's region of z, by its own tests in its own order
function lg_region(z::Complex{Double64})
    x, y = real(z), abs(imag(z))
    return if x >= 16 || y >= 16
        :stirling
    elseif abs(x - 1) + y < 0.1
        :taylor1
    elseif abs(x - 2) + y < 0.1
        :taylor2
    elseif x < 0.5
        :reflection
    elseif y < 4
        :strip
    else
        :upward
    end
end

lg_big(d::Double64) = BigFloat(HI(d)) + BigFloat(LO(d))
lg_big(z::Complex{Double64}) = Complex(lg_big(real(z)), lg_big(imag(z)))
lg_limbs(h, l) = Double64(parse(Float64, h), parse(Float64, l))  # stored as given: keeps a -0.0

function lg_fixture()
    points, hyp = [], []
    for line in eachline(joinpath(@__DIR__, "fixtures", "loggamma_arb.tsv"))
        startswith(line, '#') && continue
        f = split(line, '\t')
        if f[1] == "2F1"
            p = [
                Complex(lg_limbs(f[i], f[i + 1]), lg_limbs(f[i + 2], f[i + 3])) for
                i in 2:4:14
            ]
            push!(
                hyp,
                (
                    p...,
                    Complex(parse(BigFloat, f[18]), parse(BigFloat, f[19])),
                    parse.(Float64, f[20:21]),
                ),
            )
        else
            z = Complex(lg_limbs(f[2], f[3]), lg_limbs(f[4], f[5]))
            push!(
                points,
                (
                    f[1],
                    z,
                    Complex(parse(BigFloat, f[6]), parse(BigFloat, f[7])),
                    parse.(Float64, f[8:9]),
                ),
            )
        end
    end
    return points, hyp
end

@testset "complex loggamma" begin
    setprecision(BigFloat, 320) do
        u = BigFloat(2)^-106
        points, hyp = lg_fixture()

        @testset "against Arb, per region" begin
            @test length(points) > 2500
            worst = Dict{Symbol,Float64}()
            for (class, z, ref, (rre, rim)) in points
                r = lg_region(z)
                d = lg_big(SF.loggamma(z)) - ref
                if r in (:taylor1, :taylor2)
                    e = abs(d) / abs(ref)
                    ok = e <= LG_BOUND[r] * u + (rre + rim) / abs(ref)
                else
                    s = max(1, abs(ref))
                    e = max(abs(real(d)), abs(imag(d))) / s
                    ok =
                        abs(real(d)) <= LG_BOUND[r] * u * s + rre &&
                        abs(imag(d)) <= LG_BOUND[r] * u * s + rim
                end
                worst[r] = max(get(worst, r, 0.0), Float64(e / u))
                ok || @error "loggamma beyond its bound" class z r Float64(e / u)
                @test ok
            end
            @test Set(keys(worst)) == Set(keys(LG_BOUND))  # every region sampled
        end

        @testset "lg(z + 1) - lg(z) = log z" begin
            # z with Float64 parts, so that z + 1 is exact; the pairs cross every seam
            for x in -15.75:0.37:16.5,
                y in (0.0, 1e-9, 0.3, 2.2, 3.999, 4.0, 4.001, 7.5, 15.6, 16.2)

                z = Complex(Double64(x), Double64(y))
                (iszero(y) && x <= 0 && isinteger(x)) && continue
                a, b = SF.loggamma(z), SF.loggamma(z + 1)
                tol =
                    (
                        LG_BOUND[lg_region(z)] * max(1, abs(lg_big(a))) +
                        LG_BOUND[lg_region(z + 1)] * max(1, abs(lg_big(b)))
                    ) * u
                @test abs(lg_big(b) - lg_big(a) - log(lg_big(z))) <= tol
            end
        end

        @testset "reflection: lg(z) + lg(1 - z) = log π - log sin(πz) + 2πi floor(x/2 + 1/4), Im z > 0" begin
            for x in -15.9:0.43:16.3, y in (1e-7, 0.4, 3.3, 4.2, 9.0, 15.5, 17.0)
                z = Complex(Double64(x), Double64(y))
                a, b = SF.loggamma(z), SF.loggamma(1 - z)
                w = Complex(BigFloat(x), BigFloat(y))
                rhs =
                    log(BigFloat(π)) - log(sinpi(w)) +
                    2 * BigFloat(π) * im * floor(BigFloat(x) / 2 + 1 // 4)
                tol =
                    (
                        LG_BOUND[lg_region(z)] * max(1, abs(lg_big(a))) +
                        LG_BOUND[lg_region(1 - z)] * max(1, abs(lg_big(b)))
                    ) * u
                @test abs(lg_big(a) + lg_big(b) - rhs) <= tol
            end
        end

        @testset "lg(conj z) = conj(lg(z)) exactly" begin
            for (_, z, _, _) in points[1:7:end]
                @test isequal(SF.loggamma(conj(z)), conj(SF.loggamma(z)))
            end
        end

        @testset "2F1 through Gamma.jl against Arb's 2F1" begin
            # an MST-type 2F1 at three arguments, x = -5.8, -68.8, -1000 (tools/loggamma/fixture.jl); its
            # transformations call Gamma.gamma on Complex{Double64}. Bound: the measured relative errors, 1.1, 2.3 and
            # 45.0 u (2026-11-14), rounded up to a power of two; with exact gamma values (through BigFloat) 2F1's own
            # errors are 0.5, 3.4 and 41.0 u, so the third bound's margin is HypergeometricFunctions' rather than ours
            @test length(hyp) == 3
            for ((a, b, c, x, ref, (rre, rim)), bound) in zip(hyp, (16, 16, 64))
                v = HypergeometricFunctions._₂F₁(a, b, c, x)
                @test abs(lg_big(v) - ref) <= bound * u * abs(ref) + rre + rim
            end
        end
    end

    @testset "special values" begin
        D(x) = Double64(x)
        lg(x, y) = SF.loggamma(Complex(D(x), D(y)))
        # SpecialFunctions' table for Complex{Float64}, and its z = ±0 ± 0i
        for (x, y) in (
            (Inf, 0.0),
            (Inf, -0.0),
            (Inf, 1.0),
            (-Inf, 1.0),
            (-Inf, -1.0),
            (1.0, Inf),
            (1.0, -Inf),
            (NaN, 0.0),
            (0.0, NaN),
            (Inf, Inf),
            (0.0, 0.0),
            (-0.0, 0.0),
            (0.0, -0.0),
            (-0.0, -0.0),
            (-1.0, 0.0),
            (-1.0, -0.0),
        )
            @test isequal(ComplexF64(lg(x, y)), SF.loggamma(Complex(x, y)))
        end
        u = BigFloat(2)^-106
        nearπ(v, n) = abs(lg_big(v) - n * BigFloat(π)) <= 4u * abs(n) * BigFloat(π)
        # the cut: from above for +0.0 and from below for -0.0, Im lg = ∓π ceil(-x)
        for x in (-0.3, -0.5, -1.5, -2.5, -7.25, -30.6)
            @test nearπ(imag(lg(x, 0.0)), -ceil(-x))
            @test nearπ(imag(lg(x, -0.0)), ceil(-x))
        end
        # two departures from SpecialFunctions' Complex{Float64} method, both deliberate:
        # - at a pole -k, k >= 1, Im is the upper side's value just right of the pole, -kπ (SpecialFunctions gives -π at
        #   -1 and -3π at -2, from the signs of zeros in its sinpi and log);
        # - on the positive axis a -0.0 imaginary part gives -0.0, as lg(conj z) = conj(lg(z)) (SpecialFunctions: +0.0)
        for k in 1:5
            v = lg(-k, 0.0)
            @test real(v) == Inf && nearπ(imag(v), -k)
        end
        # the positive axis: a zero imaginary part keeps its sign, in every region the axis crosses
        for x in (0.3, 0.7, 1.02, 1.3, 2.03, 2.5, 5.5, 20.0)
            @test iszero(imag(lg(x, 0.0))) && !signbit(imag(lg(x, 0.0)))
            @test iszero(imag(lg(x, -0.0))) && signbit(imag(lg(x, -0.0)))
        end
        # large |z|: finite while lg is (the fixture's near-overflow class), Inf past it
        @test all(isfinite, reim(lg(1e300, 1e300)))
        @test all(isfinite, reim(lg(-1e300, 0.5)))
        @test isfinite(real(lg(2.559e305, 0.0)))
        @test real(lg(2.6e305, 0.0)) == Inf
    end

    @testset "Gamma.jl's methods" begin
        z = Complex(Double64(0.3), Double64(0.2))
        @test Gamma.loggamma(z) === SF.loggamma(z)
        x = Double64(2.5)
        @test Gamma.gamma(x) === SF.gamma(x)
        @test Gamma.loggamma(x) === SF.loggamma(x)
        @test Gamma.logabsgamma(-x) === SF.logabsgamma(-x)
        @test Gamma.gamma(Complex(x, Double64(0))) === Complex(SF.gamma(x))
        @test Gamma.gamma(z) === exp(SF.loggamma(z)) === SF.gamma(z)
    end

    @testset "allocation-free" begin
        alloc(f, a) = (f(a); f(a); @allocated f(a))
        D(x) = Double64(x)
        # a point in each region: Stirling, the two diamonds, the reflection (and its cut), the strip, the upward shift
        for z in (
            Complex(D(30.5), D(-2.0)),
            Complex(D(1.03), D(0.02)),
            Complex(D(2.04), D(-0.01)),
            Complex(D(-3.3), D(0.5)),
            Complex(D(-3.3), D(0.0)),
            Complex(D(5.7), D(1.3)),
            Complex(D(5.7), D(-6.1)),
        )
            for f in (SF.loggamma, Gamma.loggamma, SF.gamma, Gamma.gamma)
                @test alloc(f, z) == 0
            end
        end
        for f in (Gamma.gamma, Gamma.loggamma, Gamma.logabsgamma)
            @test alloc(f, D(2.5)) == 0
        end
    end
end
