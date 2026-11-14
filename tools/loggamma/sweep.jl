# The measured error of the complex loggamma of Double64 against Arb (acb_lgamma at 320 bits), per region and per
# band, the basis of test/loggamma.jl's tolerances. Each error is a component's, |Re| or |Im| of lg - Arb, in units of
# u = 2^-106 of max(1, |lg|); in the Taylor diamonds, normwise relative to |lg|. Run with the number of points per band:
#
#     julia --project=tools/loggamma tools/loggamma/sweep.jl 20000

using Arblib, DoubleFloatsX, Printf, Random

const PREC = 320
setprecision(BigFloat, PREC)
const U = BigFloat(2)^-106
big(d::Double64) = BigFloat(HI(d)) + BigFloat(LO(d))

function arb(z::Complex{Double64})
    r = Arblib.lgamma!(Acb(; prec=PREC), Acb(big(real(z)), big(imag(z)); prec=PREC))
    return Complex(
        BigFloat(Arblib.midref(Arblib.realref(r))),
        BigFloat(Arblib.midref(Arblib.imagref(r))),
    )
end

# the kernel's region of z, by its own tests in its own order
function region(z)
    x, y = real(z), abs(imag(z))
    return if x >= 16 || y >= 16
        "stirling"
    elseif abs(x - 1) + y < 0.1
        "taylor1"
    elseif abs(x - 2) + y < 0.1
        "taylor2"
    elseif x < 0.5
        "reflection"
    elseif y < 4
        "strip"
    else
        "upward"
    end
end

function main(n)
    rng = Xoshiro(20261115)
    dd(x) = Double64(x) + Double64((rand(rng) - 0.5) * eps(x))
    unif(a, b) = a + (b - a) * rand(rng)
    bands = [
        ("strip", () -> Complex(dd(unif(0.5, 16)), dd(unif(0, 4)))),
        ("upward 4 <= y < 5", () -> Complex(dd(unif(0.5, 16)), dd(unif(4, 5)))),
        ("upward 5 <= y < 16", () -> Complex(dd(unif(0.5, 16)), dd(unif(5, 16)))),
        # the corner where the shared 1/ζ weighs most, sum_j |j/(ζ - j)| up to 22, and its reflection
        ("upward corner", () -> Complex(dd(unif(0.5, 2)), dd(unif(4, 4.3)))),
        ("reflected corner", () -> Complex(dd(unif(-1, 0.5)), dd(unif(4, 4.3)))),
        (
            "reflection pi|y| in [0.5, 4]",
            () -> Complex(dd(unif(-16, 0.5)), dd(unif(0.5, 4) / π)),
        ),
        ("reflection y < 4", () -> Complex(dd(unif(-16, 0.5)), dd(unif(0, 4)))),
        ("reflection 4 <= y < 16", () -> Complex(dd(unif(-16, 0.5)), dd(unif(4, 16)))),
        ("near real", () -> Complex(dd(unif(-16, 16)), dd(10.0^unif(-30, -1)))),
        (
            "stirling",
            () -> (
                ρ=10.0^unif(1.2, 4);
                θ=unif(-0.999π, 0.999π);
                Complex(dd(ρ * cos(θ)), dd(ρ * sin(θ)))
            ),
        ),
        (
            "diamonds",
            () -> (
                ρ=0.1rand(rng);
                θ=unif(0, 2π);
                Complex(dd(rand(rng, (1, 2)) + ρ * cos(θ)), dd(ρ * sin(θ)))
            ),
        ),
    ]
    byregion = Dict{String,Float64}()
    for (name, gen) in bands
        m = 0.0
        worst = nothing
        for _ in 1:n
            z = gen()
            ref = arb(z)
            v = DoubleFloatsX.SpecialFunctions.loggamma(z)
            d = Complex(big(real(v)), big(imag(v))) - ref
            r = region(z)
            e = Float64(
                if r in ("taylor1", "taylor2")
                    abs(d) / abs(ref) / U
                else
                    max(abs(real(d)), abs(imag(d))) / max(1, abs(ref)) / U
                end,
            )
            byregion[r] = max(get(byregion, r, 0.0), e)
            e > m && (m=e; worst=z)
        end
        @printf("%-30s n = %d: max %6.2f u at %s\n", name, n, m, worst)
    end
    println("by region:")
    for (r, e) in sort(collect(byregion))
        @printf("  %-11s max %6.2f u\n", r, e)
    end
end

main(parse(Int, get(ARGS, 1, "2000")))
