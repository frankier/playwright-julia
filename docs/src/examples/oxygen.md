# Oxygen.jl

A micro-framework: routes plus a rendered page. What this adds over the
[HTTP.jl](@ref) example is a **second surface** — a real app is a page plus the
JSON endpoints that page calls, and both need testing.

```console
$ julia --project=examples examples/oxygen_jl.jl
$ PLAYWRIGHT_JL_ENGINE=firefox julia --project=examples examples/oxygen_jl.jl
```

## What to take from it

**The JSON is checked through the browser's own `fetch`, not through HTTP.jl on
the Julia side.** That is the point worth copying. Asserting from Julia tells
you what *Julia* can reach; asserting through the page tells you what the page
can reach — same origin, same cookies, same headers, same CORS rules. Those are
different claims, and only one of them is the one your users depend on.

```julia
items = evaluate(page, "() => fetch('/api/inventory').then(r => r.json())")
@test length(items) == 3
```

[`evaluate`](@ref) awaits the promise and converts the body, so it is an
ordinary Julia value by the time it reaches `@test`. The status code comes back
the same way, which no DOM assertion could tell you.

**The DOM starts empty and fills itself in from the route.** Every DOM
assertion on this page is therefore only true if the API works — the two
surfaces are not independently checked, they are checked against each other.

## The source

Read from `examples/oxygen_jl.jl` at build time:

```@eval
using Markdown, Playwright
src = read(joinpath(pkgdir(Playwright), "examples", "oxygen_jl.jl"), String)
Markdown.parse("```julia\n" * src * "```")
```
