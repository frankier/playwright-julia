# HTTP.jl

The thinnest possible Julia web server, driven end to end. This example is
first on purpose: HTTP.jl brings no conventions of its own, so what is left on
the page is **the pattern** every browser test follows rather than a
framework's idioms.

```console
$ julia --project=examples examples/http_jl.jl
$ PLAYWRIGHT_JL_ENGINE=firefox julia --project=examples examples/http_jl.jl
```

## What to take from it

**The lifecycle is a `try`/`finally` around everything that was started.** The
server is closed in one, the browser in another. A test that fails still tears
down what it created, which matters more in CI than anywhere else — a leaked
browser outlives the job.

**The port is not hard-coded.** HTTP.jl can pick one itself with
`listenany = true` and hand it back, which is better than choosing a free port
and then binding it: there is no window in between for something else to take
it. The other examples use `free_port()` from `common.jl` only because their
frameworks insist on being told a port up front.

**The page mutates itself 300 milliseconds after the click**, deliberately.
That delay is handled by `expect`'s retry and not by a `sleep` on the Julia
side — which is the entire argument of [Assertions](@ref) in one line of test
code.

**`expect` to settle, `@test` to check.** The assertions that wait are
`expect`; once the DOM has settled, a plain read is the natural thing to put
inside `@test`. Using each for its own job is what removes the temptation to
sleep.

## The source

Read from `examples/http_jl.jl` at build time, so this page cannot drift from
what CI actually ran:

```@eval
using Markdown, Playwright
src = read(joinpath(pkgdir(Playwright), "examples", "http_jl.jl"), String)
Markdown.parse("```julia\n" * src * "```")
```
