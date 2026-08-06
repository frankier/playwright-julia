# A drop-in replacement for Bonnie.jl's test/cdp.jl, written against nothing
# but Playwright.jl's public API. cdp.jl is ~100 lines of hand-rolled CDP —
# launch Chrome, open a tab, Runtime.evaluate, poll — and its whole surface is
# with_page / evaluate / poll_js.
#
# `evaluate` needs no shim at all: it is public API with the same meaning.
# What follows is everything else.

using Playwright

# Milestone 4 gave the package its own `with_page` (B4), which takes a browser
# or context to open the page in. cdp.jl's takes none and launches its own
# browser, so the two do not overlap and this is an added *method* rather than
# a second function — otherwise the shim would shadow the export and every
# caller in the suite would silently get whichever was defined last.
import Playwright: with_page

"""
    with_page(f; browser=:chromium, headless=true)

Run `f(page)` against a fresh page in its own context, tearing everything down
afterwards even if `f` throws. `chromium_sandbox=false` and
`--disable-dev-shm-usage` are what containerised CI running as root needs.
"""
function with_page(f; browser::Symbol = :chromium, headless::Bool = true)
    playwright() do pw
        b = launch(
            getfield(pw, browser);
            headless,
            chromium_sandbox = false,
            args = ["--disable-dev-shm-usage"],
        )
        ctx = new_context(b)
        try
            f(new_page(ctx))
        finally
            close!(ctx)
            close!(b)
        end
    end
end

"""
    poll_js(page, expression; timeout=10.0, interval=0.1)

Block until `expression` evaluates truthy in the page, or raise after
`timeout` seconds. Dumps any uncaught page errors on timeout, so a hung app
reports its exception instead of just "timed out".

Keeps cdp.jl's signature (seconds, and an `error` on timeout) because that is
what callers of the old harness expect, but the waiting itself is now
[`wait_for_function`](@ref) — the driver re-checks the predicate in the
browser. `interval` is passed through as the polling interval; the original
Julia-side `sleep` loop is gone, which is the whole point of milestone 3
(SC 2: no test sleeps for the DOM).
"""
function poll_js(page, expression; timeout::Real = 10.0, interval::Real = 0.1)
    try
        wait_for_function(
            page,
            expression;
            timeout = round(Int, timeout * 1_000),
            polling = round(Int, interval * 1_000),
        )
        return true
    catch e
        e isa PlaywrightError || rethrow()
        for err in page_errors(page)
            @warn "page error while polling" err.message
        end
        # cdp.jl raised a plain ErrorException here and its callers catch that.
        error("poll_js timed out after $(timeout)s: $expression")
    end
end
