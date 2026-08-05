# Shared by every example. Deliberately tiny: two helpers, both of which exist
# because a real Julia web server needs them, not because Playwright does.
#
# Everything else an example does goes through the public API, so that copying
# an example into your own test suite means copying the part you can read.

using HTTP
using Sockets
using Playwright

"""
    free_port() -> Int

An unused TCP port, obtained by binding port 0 and reading back what the
kernel assigned.

Examples run one after another in the same CI job, and a hard-coded port turns
that into a collision the day two of them overlap. Nothing here is
Playwright-specific — it is the ordinary way to start a server in a test.
"""
function free_port()
    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    close(server)
    return port
end

"""
    engine(pw) -> BrowserType

The browser to drive, from `PLAYWRIGHT_JL_ENGINE`, defaulting to Chromium.

Each example is written against one engine at a time — that is how you would
write it in your own suite — and CI runs the set twice, once per engine, by
setting this variable. `runexamples.jl` does the same locally.
"""
function engine(pw)
    name = get(ENV, "PLAYWRIGHT_JL_ENGINE", "chromium")
    name in ("chromium", "firefox", "webkit") ||
        error("PLAYWRIGHT_JL_ENGINE must be chromium, firefox or webkit; got $name")
    return getproperty(pw, Symbol(name))
end

"""
    wait_for_server(url; timeout = 60_000)

Block until `url` serves something, then return it.

Julia web frameworks start asynchronously and warm up slowly — Genie's first
request can be tens of seconds after `up()` returns. The wait is
`retry_until(…; on_error = :retry)`: connection refused is the *expected*
state while the server is coming up, so it is retried rather than raised, and
the moment a request succeeds the wait ends. A `sleep` long enough to be safe
here would be a `sleep` wasted on every run.
"""
function wait_for_server(url::AbstractString; timeout::Real = 60_000)
    ok = retry_until(; timeout, interval = 200, on_error = :retry, on_timeout = :false) do
        HTTP.get(url; retry = false, status_exception = true)
        true
    end
    ok || error("server at $url did not come up within $(timeout)ms")
    return url
end
