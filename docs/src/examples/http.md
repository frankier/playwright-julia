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

**The port is not hard-coded.** HTTP.jl picks one itself with `listenany = true`
and returns it. That beats choosing a free port and then binding it, because it
leaves no window for something else to take the port. The other examples use
`free_port()` from `common.jl` only because their frameworks insist on being told
a port first.

**The page mutates itself 300 milliseconds after the click**, deliberately.
`expect`'s retry absorbs that delay, and no `sleep` appears on the Julia side.
That is the whole argument of [Assertions](@ref) in one line of test code.

**Use `expect` to settle, `@test` to check.** `expect` is the assertion that
waits. Once the DOM settles, put a plain read inside `@test`. Give each one its
own job and the temptation to sleep goes away.

## The source

Read from `examples/http_jl.jl` at build time:

```@eval
using Markdown, Playwright
src = read(joinpath(pkgdir(Playwright), "examples", "http_jl.jl"), String)
Markdown.parse("```julia\n" * src * "```")
```
