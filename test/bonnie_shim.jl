# A drop-in replacement for Bonnie.jl's test/cdp.jl, written against nothing
# but Playwright.jl's public API. cdp.jl is ~100 lines of hand-rolled CDP —
# launch Chrome, open a tab, Runtime.evaluate, poll — and its whole surface is
# with_page / evaluate / poll_js.
#
# `evaluate` needs no shim at all: it is public API with the same meaning.
# What follows is everything else.

using Playwright

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
            close(ctx)
            close(b)
        end
    end
end

"""
    poll_js(page, expression; timeout=10.0, interval=0.1)

Block until `expression` evaluates truthy in the page, or raise after
`timeout` seconds. Dumps any uncaught page errors on timeout, so a hung app
reports its exception instead of just "timed out".
"""
function poll_js(page, expression; timeout::Real = 10.0, interval::Real = 0.1)
    deadline = time() + timeout
    while time() < deadline
        evaluate(page, expression) === true && return true
        sleep(interval)
    end
    for err in page_errors(page)
        @warn "page error while polling" err.message
    end
    error("poll_js timed out after $(timeout)s: $expression")
end
