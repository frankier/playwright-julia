# Oxygen.jl

A micro-framework: routes plus a rendered page. This adds a **second surface**
over the [HTTP.jl](@ref) example. A real app is a page plus the JSON endpoints
that page calls, and both need testing.

```console
$ julia --project=examples examples/oxygen_jl.jl
$ PLAYWRIGHT_JL_ENGINE=firefox julia --project=examples examples/oxygen_jl.jl
```

## What to take from it

**Check the JSON through the browser's own `fetch`, not through HTTP.jl on the
Julia side.** That is the point worth copying. An assertion from Julia tells you
what *Julia* can reach. An assertion through the page tells you what the page can
reach, with the same origin, cookies, headers and CORS rules. Those are different
claims, and your users depend on only one of them.

```julia
items = evaluate(page, "() => fetch('/api/inventory').then(r => r.json())")
@test length(items) == 3
```

[`evaluate`](@ref) awaits the promise and converts the body, so it reaches `@test`
as an ordinary Julia value. The status code comes back the same way, and no DOM
assertion could tell you that.

**The DOM starts empty and fills itself in from the route.** So every DOM
assertion on this page holds only if the API works. The two surfaces check each
other rather than standing alone.

## The source

Read from `examples/oxygen_jl.jl` at build time:

```@eval
using Markdown, Playwright
src = read(joinpath(pkgdir(Playwright), "examples", "oxygen_jl.jl"), String)
Markdown.parse("```julia\n" * src * "```")
```
