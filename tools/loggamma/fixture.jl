# The reference values of test/loggamma.jl: Arb's acb_lgamma (FLINT, through Arblib.jl) at 320 bits at the exact
# Double64 inputs, and Arb's 2F1 at the exact Double64 parameters of the 2F1 test. Writes the fixture to stdout:
#
#     julia --project=tools/loggamma tools/loggamma/fixture.jl > test/fixtures/loggamma_arb.tsv
#
# One tab-separated line per point: the sample class, the input's limbs as hex floats (re hi, re lo, im hi, im lo),
# the reference's real and imaginary midpoints (36 significant digits) and their ball radii. An input with a -0.0
# imaginary part on the cut is given the conjugate of Arb's value at +0.0 (lg(conj z) = conj(lg(z))), since Arb
# takes an exact real input from above. The 2F1 lines carry the limbs of a, b, c and x and the reference.

using Arblib, DoubleFloatsX, Printf, Random

const PREC = 320
setprecision(BigFloat, PREC)

big(d::Double64) = BigFloat(HI(d)) + BigFloat(LO(d))  # exact: no input spans more than 320 bits
acb(z::Complex{Double64}) = Acb(big(real(z)), big(imag(z)); prec=PREC)
hexs(x::Float64) = @sprintf("%a", x)
limbs(d::Double64) = (hexs(HI(d)), hexs(LO(d)))
mid(x) = BigFloat(Arblib.midref(x))
rad(x) = Float64(Arblib.radref(x))
dec(x::BigFloat) = @sprintf("%.35e", x)

function line(class, z::Complex{Double64})
    conjugated = signbit(imag(z))
    r = Arblib.lgamma!(Acb(; prec=PREC), acb(conjugated ? conj(z) : z))
    re, im = Arblib.realref(r), Arblib.imagref(r)
    isfinite(mid(re)) || error("Arb returned no finite value at $z")
    return join(
        (
            class,
            limbs(real(z))...,
            limbs(imag(z))...,
            dec(mid(re)),
            dec(conjugated ? -mid(im) : mid(im)),
            @sprintf("%.3e", rad(re)),
            @sprintf("%.3e", rad(im)),
        ),
        '\t',
    )
end

function samples(rng)
    dd(x) = Double64(x) + Double64((rand(rng) - 0.5) * eps(x))  # a value with a nonzero low limb near x
    c(x, y) = Complex(dd(x), dd(y))
    unif(a, b) = a + (b - a) * rand(rng)
    pm() = rand(rng, (1, -1))
    S = Pair{String,Complex{Double64}}[]
    add!(class, zs) = append!(S, class .=> zs)
    add!("box", [c(unif(-60, 60), unif(-60, 60)) for _ in 1:300])
    add!("near-real", [c(unif(-50, 50), pm() * 10.0^unif(-30, 0)) for _ in 1:200])
    add!("real-axis", [Complex(dd(unif(-50, 16.5)), Double64(0.0)) for _ in 1:150])
    add!("cut-from-below", [Complex(dd(unif(-30, 0)), -Double64(0.0)) for _ in 1:40])
    add!("strip", [c(unif(-16, 16), pm() * unif(0, 4)) for _ in 1:300])
    add!("upward-band", [c(unif(-16, 16), pm() * unif(4, 8)) for _ in 1:300])
    add!(
        "near-poles",
        [
            c(-k + pm() * 10.0^unif(-12, -3), pm() * 10.0^unif(-12, -3)) for k in 0:39 for
            _ in 1:3
        ],
    )
    add!(
        "near-1-and-2",
        [
            (ρ=10.0^unif(-12, -1.01); θ=unif(0, 2π); c(a + ρ * cos(θ), ρ * sin(θ))) for
            a in (1, 2) for _ in 1:75
        ],
    )
    add!(
        "large",
        [
            (ρ=10.0^unif(2, 300); θ=unif(-0.999π, 0.999π); c(ρ * cos(θ), ρ * sin(θ))) for
            _ in 1:120
        ],
    )
    add!(
        "mst-bands",
        vcat(
            [c(unif(-1.02, 9.6), unif(-0.25, 0.25)) for _ in 1:60],
            [c(unif(3.95, 8.0), pm() * unif(5.27, 5.99)) for _ in 1:60],
        ),
    )
    # the seams between regions, each side, and their reflections 1 - z
    t = (-1e-12, -1e-25, 1e-25, 1e-12)
    seams = Complex{Double64}[]
    for d in t, y in (0.3, 3.7, 9.0)
        push!(
            seams,
            Complex(Double64(16) + d, Double64(y)),
            Complex(Double64(0.5) + d, Double64(y)),
        )
    end
    for d in t, x in (-15.3, -3.7, -0.4, 0.2, 0.7, 1.4, 1.6, 2.9, 5.5, 9.1, 15.9)
        push!(
            seams,
            Complex(Double64(x), Double64(4) + d),
            Complex(Double64(x), Double64(16) + d),
        )
    end
    for d in t, k in 1:15, y in (0.0, 0.3, 2.1, 3.9)
        push!(seams, Complex(Double64(k + 0.5) + d, Double64(y)))
    end
    for k in 0:14  # the corner Re u -> 3/2, Im u -> 4, where |Im lg(u)| comes nearest π
        push!(seams, Complex(Double64(k + 1.5) - 1e-25, Double64(4) - 1e-25))
    end
    for d in t, a in (1, 2), sx in (1, -1), y in (0.0, 0.03, 0.07)  # the diamonds' edges |x - a| + |y| = 1/10
        push!(
            seams,
            Complex(Double64(a) + sx * (Double64(0.1) - Double64(y)) + d, Double64(y)),
        )
    end
    add!("seams", seams)
    add!("seams-reflected", [1 - z for z in seams if real(1 - z) < 0.5])
    return S
end

# the 2F1 of an MST-type expansion (Sasaki and Tagoshi, Living Rev. Relativ. 6 (2003) 6): s = -2, a = 0.7,
# omega = 1e-4 (M = 1), m = 2, nu = 1.99999 a representative non-integer; 2F1(nu + 1 - i tau, -nu - i tau;
# 1 - s - i eps - i tau; x), eps = 2 omega, kappa = sqrt(1 - a^2), tau = (eps - m a)/kappa, at three arguments
function hyp2f1_lines()
    s, a, ω, m, ν = -2, Double64(7) / 10, Double64(1) / 10^4, 2, Double64(199999) / 10^5
    ε = 2ω
    κ = sqrt(1 - a^2)
    τ = (ε - m * a) / κ
    A, B, C = Complex(ν + 1, -τ), Complex(-ν, -τ), Complex(Double64(1 - s), -ε - τ)
    out = String[]
    for x in (Double64(-58) / 10, Double64(-688) / 10, Double64(-1000))
        X = Complex(x, Double64(0))
        r = Arblib.hypgeom_2f1!(Acb(; prec=PREC), acb(A), acb(B), acb(C), acb(X), 0, PREC)
        re, im = Arblib.realref(r), Arblib.imagref(r)
        push!(
            out,
            join(
                (
                    "2F1",
                    (l for w in (A, B, C, X) for p in reim(w) for l in limbs(p))...,
                    dec(mid(re)),
                    dec(mid(im)),
                    @sprintf("%.3e", rad(re)),
                    @sprintf("%.3e", rad(im)),
                ),
                '\t',
            ),
        )
    end
    return out
end

function main()
    println(
        "# Arb (FLINT) references for test/loggamma.jl, written by tools/loggamma/fixture.jl at $PREC bits; Arblib ",
        pkgversion(Arblib),
        ", Julia ",
        VERSION,
    )
    println("# class\tre hi\tre lo\tim hi\tim lo\tlg re\tlg im\tradius re\tradius im")
    for (class, z) in samples(Xoshiro(20261114))
        println(line(class, z))
    end
    println(
        "# 2F1\ta re hi\ta re lo\ta im hi\ta im lo\tb (4 limbs)\tc (4 limbs)\tx (4 limbs)\tre\tim\tradius re\tradius im",
    )
    return foreach(println, hyp2f1_lines())
end

main()
