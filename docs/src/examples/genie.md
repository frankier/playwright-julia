# Genie.jl

The full framework, and the slowest to start — which is exactly why it is here.

```console
$ julia --project=examples examples/genie_jl.jl
$ PLAYWRIGHT_JL_ENGINE=firefox julia --project=examples examples/genie_jl.jl
```

## The number this example exists for

**Genie answered its first request 25.0 seconds after `up()` returned**, on an
idle workstation with a warm depot. The browser work that follows takes two
seconds. A cold CI runner is slower.

That gap is the whole argument for
[`retry_until`](@ref)`(…; on_error = :retry)`. During warm-up a request does
not return a bad status — it throws *connection refused*. Treating that
exception as "not yet" rather than as a failure is the difference between a
wait that works and one that crashes on its first attempt:

```julia
retry_until(; timeout, interval = 200, on_error = :retry, on_timeout = :false) do
    HTTP.get(url; retry = false, status_exception = true)
    true
end
```

A `sleep` long enough to cover 25 seconds is 25 seconds paid on every run
forever, including the runs where Genie was ready in five. A shorter one is a
flake waiting for a loaded runner. The example measures and prints the wait on
every run, so the claim above stays checkable rather than becoming folklore.

See [Waiting](@ref).

## What else to take from it

**Routing is the thing under test.** The example follows a link, asserts on the
URL it landed on and on the rendered article, then comes back — because routing
is what Genie brings that the previous two examples do not.

## The source

Read from `examples/genie_jl.jl` at build time:

```@eval
using Markdown, Playwright
src = read(joinpath(pkgdir(Playwright), "examples", "genie_jl.jl"), String)
Markdown.parse("```julia\n" * src * "```")
```
