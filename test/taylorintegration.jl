
# DoubleFloatsXTaylorIntegrationExt gives TaylorIntegration's internal _exact_step a Double64 method; without it a
# Double64 integration throws "no exact step found". A whole integration of y' = iy, y(0) = 1, in Complex{Double64}
# with Double64 time, against y = exp(it), plain and with @taylorize, forward and backward, so that a rename or a new
# signature of _exact_step upstream fails here. Bound: the steps' count times abstol, the local error the step size is
# chosen for; measured 4.9e-32 forward and 2.5e-32 backward over 13 steps of order 28 at abstol 1e-30 (2026-11-14).
# The last time is tmax exactly when tmax - t0 is exact in Double64; between endpoints with low limbs (1/3 and 10/3) it
# can pass tmax by a unit of the low limb: 1 of 300 random integrations did, by 0.25 * 2^-106 of max(1, |tmax|).

# in a module of its own: @taylorize's code names TaylorSeries' exports, which `using TaylorIntegration` brings in,
# and the later test files must not see them
module TestTaylorIntegration

using DoubleFloatsX, Logging, Test
using TaylorIntegration

ti_rhs(x, p, t) = im * x
@taylorize ti_rhs_parsed(x, p, t) = im * x
ti_stiff(x, p, t) = Double64(1e31) * x  # steps of about 1e-37, below the time's resolution at 1

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
            if isinteger(a) && isinteger(b)  # tmax - t0 exact: the last step lands on tmax exactly
                @test sol.t[end] == b
            else
                @test abs(big2(sol.t[end]) - big2(b)) <= 2.0^-106 * max(1, abs(big2(b)))
            end
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
        alloc(f, a...) = (f(a...); f(a...); @allocated f(a...))
        @test alloc(
            TaylorIntegration._exact_step, Double64(1), Double64(0.5), Double64(3), 1
        ) == 0
    end
end

end
