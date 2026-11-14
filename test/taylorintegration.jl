
# DoubleFloatsXTaylorIntegrationExt gives TaylorIntegration's internal _exact_step a Double64 method; without it a
# Double64 integration throws "no exact step found". A whole integration of y' = iy, y(0) = 1, in Complex{Double64}
# with Double64 time, against y = exp(it), plain and with @taylorize, forward and backward, so that a rename or a new
# signature of _exact_step upstream fails here. Bound: the steps' count times abstol, the local error the step size is
# chosen for; measured 4.9e-32 forward and 2.5e-32 backward over 13 steps of order 28 at abstol 1e-30 (2026-11-14).
# The last time is tmax exactly, between endpoints with low limbs (1/3 and 10/3) too, where tmax - t0 needs more than
# two limbs and the method stops first at a point from which tmax is reached exactly. Fixed-time output, root-finding,
# a step below the time's resolution and random endpoints are checked against the callers' contract.

# in a module of its own: @taylorize's code names TaylorSeries' exports, which `using TaylorIntegration` brings in,
# and the later test files must not see them
module TestTaylorIntegration

using DoubleFloatsX, Logging, Random, Test
using TaylorIntegration

ti_rhs(x, p, t) = im * x
@taylorize ti_rhs_parsed(x, p, t) = im * x
ti_stiff(x, p, t) = Double64(1e31) * x  # steps of about 1e-37, below the time's resolution at 1
ti_one(x, p, t) = one(x)
function ti_oscillator!(dx, x, p, t)  # x'' = -x
    dx[1] = x[2]
    dx[2] = -x[1]
    return nothing
end
ti_crossing(dx, x, p, t) = (true, x[1])

@testset "TaylorIntegration with Double64 time" begin
    setprecision(BigFloat, 256) do
        big2(d::Double64) = BigFloat(HI(d)) + BigFloat(LO(d))
        big2(z::Complex{Double64}) = Complex(big2(real(z)), big2(imag(z)))
        y(t) = Complex(convert(Double64, cos(big2(t))), convert(Double64, sin(big2(t))))
        t0, T, t1, t2 = Double64(0), Double64(10), Double64(1) / 3, Double64(10) / 3
        abstol = Double64(1e-30)
        for (rhs, parse) in ((ti_rhs, false), (ti_rhs_parsed, true)),
            (a, b) in ((t0, T), (T, t0), (t1, t2), (t2, t1))
            # no warning: the parsed method is the one used
            ya = y(a)
            sol = @test_logs min_level = Logging.Warn taylorinteg(
                rhs, ya, a, b, 28, abstol; maxsteps=1000, parse_eqs=parse
            )
            @test eltype(sol.t) === Double64 && eltype(sol.x) === Complex{Double64}
            @test sol.t[end] == b  # the last step lands on tmax exactly
            exact = big2(ya) * cis(big2(sol.t[end]) - big2(a))
            @test abs(big2(sol.x[end]) - exact) <= length(sol.t) * big2(abstol)
        end
        # a step too small to move t0 is zero, so the callers stop rather than repeat a time
        @test iszero(
            TaylorIntegration._exact_step(
                Double64(1.0, 2.0^-54), Double64(2.0^-200), Double64(3), 1
            ),
        )
        sol = @test_logs (:warn, r"below the resolution") taylorinteg(
            ti_stiff,
            Double64(1),
            Double64(1.0, 2.0^-54),
            Double64(3),
            5,
            abstol;
            maxsteps=20,
        )
        @test allunique(sol.t)
        # fixed-time output: an endpoint step that cannot land at once (b - a needs three limbs) is split, so no
        # output index passes trange's end; and y' = iy at eleven output times against exp(it)
        a, b = Double64(1.0, 2.0^-54), Double64(3.0, -2.0^-108)
        sol = taylorinteg(
            ti_one, Double64(0), [a, b], 10, abstol; minstepsize=Double64(100)
        )
        @test abs(big2(sol.x[end]) - (big2(b) - big2(a))) <= 2.0^-104
        tr = [Double64(k) / 3 for k in 0:10]
        sol = taylorinteg(ti_rhs, y(tr[1]), tr, 28, abstol; maxsteps=1000)
        @test all(
            abs(big2(sol.x[k]) - big2(y(tr[1])) * cis(big2(tr[k]) - big2(tr[1]))) <= 1e-29
            for k in 1:11
        )
        # root-finding: x = sin t from t = 1/2 to 10 crosses zero at π, 2π and 3π
        sol = taylorinteg(
            ti_oscillator!,
            ti_crossing,
            [Double64(sin(big"0.5")), Double64(cos(big"0.5"))],
            Double64(0.5),
            Double64(10),
            28,
            abstol;
            maxsteps=1000,
        )
        @test length(sol.tevents) == 3 &&
            all(abs(big2(sol.tevents[k]) - k * big(π)) <= 1e-29 for k in 1:3)
        @test sol.t[end] == 10
        # random endpoints, each pair walked as the callers walk it with a step past tmax: tmax is reached exactly
        # within three steps and never passed
        rng = Random.Xoshiro(20261114)
        dd(v) = Double64(v) + Double64((rand(rng) - 0.5) * eps(v))
        landed = true
        for _ in 1:20000
            t, tm = dd(20rand(rng) - 10), dd(20rand(rng) - 10)
            s = tm > t ? 1 : -1
            for _ in 1:3
                t == tm && break
                δ = TaylorIntegration._exact_step(t, s * (abs(tm - t) + Double64(1)), tm, s)
                iszero(δ) && break
                t += δ
                s * t > s * tm && break
            end
            landed &= t == tm
        end
        @test landed
        # tmax with a zero low limb, a -0.0 one included (Double64's == tells it from +0.0), from both sides
        landed = true
        for tm in (
                Double64(3),
                -Double64(3),
                -1 * Double64(3),
                Double64(3.0, -0.0),
                Double64(0),
                -Double64(0),
            ),
            _ in 1:500

            t = dd(20rand(rng) - 10)
            s = tm > t ? 1 : -1
            for _ in 1:3
                s * t < s * tm || break
                δ = TaylorIntegration._exact_step(t, s * (abs(tm - t) + Double64(1)), tm, s)
                iszero(δ) && break
                t += δ
            end
            landed &= !(s * t < s * tm) && !(s * t > s * tm)
        end
        @test landed
        alloc(f, a...) = (f(a...); f(a...); @allocated f(a...))
        @test alloc(TaylorIntegration._exact_step, a, Double64(5), b, 1) == 0
        @test alloc(
            TaylorIntegration._exact_step, Double64(1), Double64(0.5), Double64(3), 1
        ) == 0
    end
end

end
