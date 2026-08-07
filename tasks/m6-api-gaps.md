# API gaps found while building M6

The same instrument as [`tasks/m5-api-gaps.md`](m5-api-gaps.md), pointed at a
different milestone. M5's version was written *after* its docstrings, and its
lesson was that a gap record opened late is a gap record half written — by then
the surprises have been absorbed and no longer read as surprises. So this file
exists before Part B has a line of code in it, and is empty on purpose.

**Nothing here is fixed by M6.** That is the point of writing it down instead.
`SPEC-M6.md` Assumption 4 and R6 both say so: Part A puts every export in the
package under the eye at once, and Part B adds about twenty more, so the
milestone is exactly when unrelated fixes look cheap and reviewable. They are
neither. Anything noticed goes here; the diff stays about the bang convention
and the network.

The one exception, recorded so it is not mistaken for scope creep:
`tasks/m5-api-gaps.md` gap 1 is **resolved for `fill` and `close`** as a side
effect of D3 — they became `set_value!` and `close!`, which are real exports
covered by `checkdocs = :exports` rather than `Base` extensions invisible to
it. `count`, `first`, `last`, `length`, `iterate` and `getindex` still extend
`Base` and still are not exported, which for the iteration and indexing
protocol is correct rather than a gap. Gap 1 stands for those.

Recorded 2026-08-06, at the start of Part B.

---

## 1. The code generator shadows any protocol parameter named `params`

> **RESOLVED in M7 (D1–D3), commits `377834c`, `6be2ea9` and this one.** The
> generator now underscores every local it emits, so the two namespaces cannot
> intersect; `test/test_codegen.jl` gates it, having first been seen to fail
> naming both functions below; and `src/api/apirequest.jl` calls
> `_api_request_context_fetch` like everything else. The class was fixed, not
> the instance — which is what the last paragraph here asked for.

Found while wiring `Playwright.fetch` (T13). `gen/generate.jl` emits

```julia
function _api_request_context_fetch(_obj; …, params::Union{AbstractVector,Nothing} = nothing, …)
    params = Dict{String,Any}()          # shadows the keyword argument
    …
    params === nothing || (params["params"] = to_wire(params))
```

The local parameter dict is called `params`, and two protocol commands have a
parameter of that name. The local shadows the keyword, so:

- the keyword is unreachable — you cannot pass `params` at all; and
- `params === nothing` is never true, so the call **always** sends
  `params: {…}`, the dict serialized into itself.

The driver rejects that with `DriverError: params: expected array, got object`,
so **both affected functions fail on every call regardless of arguments**:

| Function | Command |
|---|---|
| `_api_request_context_fetch` | `APIRequestContext.fetch` (`api.yml`) |
| `_cdp_session_send` | `CDPSession.send` (`playwright.yml`) |

Not fixed here. `SPEC-M6.md` assumption 5 says this milestone does not
regenerate `src/generated/channels.jl`, and the fix belongs in the generator —
rename the local to something that cannot collide (`_params`, say) and
regenerate, which touches every generated function. `src/api/apirequest.jl`
therefore builds this one call by hand, with a comment pointing here.

Worth doing early in whichever milestone next touches `gen/`: nothing else in
the package calls either function today, so the bug is invisible until someone
needs `params` — as M6 just did.
