# Spec: Playwright.jl — Milestone 2

Successor to [`SPEC.md`](SPEC.md) (milestone 1, complete). Everything in that
document — tech stack, driver architecture, code style, protocol/API layering —
carries over unchanged unless contradicted here.

## Assumptions

These are the calls this spec makes without being told. Correct any that are wrong.

1. **Bonnie.jl is the acceptance test, not a dependency.** Playwright.jl gains no
   knowledge of Bonnie; the criterion is that Bonnie's `test/cdp.jl` surface
   (`with_page` / `evaluate` / `poll_js`) and every assertion in its
   `test/test_e2e.jl` can be expressed with public Playwright.jl API. The port
   itself happens in Bonnie's repo.
2. **Codegen is a build-time tool, not a runtime dependency.** Generated code is
   checked into `src/generated/`; the generator lives in its own environment with
   its own deps (YAML.jl). The package's runtime deps stay as they are today.
3. **Two layers, not one.** Codegen emits a mechanical channel layer only. The
   idiomatic, documented, snake_case user API stays hand-written on top. Full
   codegen of the user surface is explicitly rejected (see Decisions).
4. **Still sync-only, still no event subscriptions.** Playwright 1.61 exposes
   `page.consoleMessages()` and `page.pageErrors()` as pull-based getters, which
   covers the diagnostic need without an event/callback machinery. Task-based
   event delivery is deferred to milestone 3.
5. **The pinned version stays 1.61.1.** `PLAYWRIGHT_VERSION` in `src/driver.jl`
   remains the single source of truth and now also selects the protocol spec.

## Objective

Grow the milestone-1 vertical slice into an API broad enough to write a real
end-to-end browser test suite in Julia, and make future protocol coverage cheap
by generating the channel layer from Playwright's own protocol spec.

**Driving use case.** [`bonnie_needs.md`](tasks/bonnie_needs.md) audits Bonnie.jl's
existing CDP-based e2e suite against Playwright.jl and finds three blockers plus
a comfort list. Milestone 2 closes all of them:

| Gap (from `bonnie_needs.md`) | Milestone 2 |
|---|---|
| 1. `evaluate` — arbitrary JS returning a value | `evaluate`, `evaluate_handle`, `eval_on_selector`, `eval_on_selector_all` + the `SerializedValue` codec |
| 2. Frame access / iframes | `frames`, `main_frame`, `frame_locator`, `content_frame`, frame-scoped `locator` |
| 3. Non-strict locators / `count` | `strict=false`, `count`, `nth`, `first`, `last`, iteration |
| 4. Driving `input[type=range]` | `dispatch_event` (and `evaluate` as the general escape hatch) |
| `inner_text` | `inner_text`, `inner_html`, `get_attribute`, `is_visible`, `is_checked`, `is_enabled` |
| Launch options | `args`, `chromium_sandbox`, `env`, `firefox_user_prefs`, `executable_path`, `channel`, `slow_mo`, `proxy` |
| Console / page errors | `console_messages(page)`, `page_errors(page)` (pull-based getters) |
| `new_context` / `close(context)` | Explicit `BrowserContext` lifecycle; `new_page(browser)` keeps working but no longer leaks |
| `executable_path` / `channel` | Supported, so `CHROME_BIN`-style provisioning still works |

**Target snippet.** This is what must run at the end of the milestone:

```julia
using Playwright

playwright() do pw
    browser = launch(pw.chromium; headless=true, chromium_sandbox=false,
                     args=["--disable-dev-shm-usage"])
    ctx = new_context(browser)
    page = new_page(ctx)
    goto(page, url)

    # 1. evaluate: values in and out
    @assert evaluate(page, "1 + 1") == 2
    @assert evaluate(page, "x => x.a * 2", Dict("a" => 21)) == 42
    @assert occursin("7", inner_text(locator(page, "body")))

    # 2. frames
    inner = frame_locator(page, "iframe")
    @assert evaluate(content_frame(inner), "document.title") isa String

    # 3. non-strict locators — indexable and iterable
    sliders = locator(page, "input[type=range]"; strict=false)
    @assert count(sliders) == 2
    for slider in sliders
        @assert input_value(slider) isa String
    end

    # 4. dispatch_event to drive a range input precisely
    fill_range!(first(sliders), 7)   # user-side helper built on dispatch_event
    # Milestone 3 note: this helper originally had to reach into `slider.frame`
    # and `slider.selector`. It is now `evaluate(slider, …)` plus
    # `dispatch_event(slider, "input")` — exported API only (SPEC-M3 SC 5).

    # scoped JSHandle
    evaluate_handle(page, "() => window.app") do app
        @assert evaluate(app, "a => a.ready") === true
    end

    # diagnostics on failure
    for err in page_errors(page)
        @warn "page error" err.message
    end

    close(ctx)
    close(browser)
end
```

Success looks like: a Bonnie.jl e2e suite written against this API, with the
iframe test — the one that proves same-origin embedding — expressible for the
first time.

## Tech Stack

Unchanged from `SPEC.md`. Additions:

- **Generator environment** (`gen/`, not part of the package): `YAML.jl` to parse
  the protocol spec, plus stdlib `Downloads`. Never loaded at runtime.
- **Protocol spec source**: `packages/protocol/spec/*.yml` from the
  `microsoft/playwright` repo at tag `v$PLAYWRIGHT_VERSION`. Note these are *not*
  shipped in the `playwright-core` npm tarball (only CDP's `protocol.d.ts` is),
  and the spec is split across ~19 files — there is no single `protocol.yml`.
  Vendored into `protocol/spec/` in this repo so builds and CI never hit GitHub.

## Commands

Milestone-1 commands unchanged. New:

```
Fetch spec:  julia --project=gen gen/fetch_spec.jl          # refresh protocol/spec/*.yml at the pinned tag
Generate:    julia --project=gen gen/generate.jl            # protocol/spec/*.yml → src/generated/channels.jl
Check gen:   julia --project=gen gen/generate.jl --check    # non-zero exit if generated output is stale
```

## Project Structure

Additions to the milestone-1 layout:

```
protocol/spec/*.yml        → Vendored Playwright protocol spec, pinned to PLAYWRIGHT_VERSION
gen/Project.toml           → Generator-only environment (YAML.jl)
gen/fetch_spec.jl          → Download the spec at the pinned tag
gen/generate.jl            → Emit src/generated/channels.jl; --check verifies freshness
src/generated/channels.jl  → GENERATED. Channel-layer commands + object registry. Do not edit.
src/serializers.jl         → SerializedValue/SerializedArgument codec (hand-written)
src/api/                   → Hand-written user API, split by area:
src/api/lifecycle.jl         playwright(), launch, contexts, shutdown
src/api/navigation.jl        goto, title, url, wait_for_load_state, screenshot
src/api/frames.jl            frames, frame_locator, content_frame, owner_frame
src/api/locators.jl          locator, count, nth, first/last, iteration, actions, state queries
src/api/evaluate.jl          evaluate, evaluate_handle (+ scoped form), eval_on_selector(_all), JSHandle, dispose
src/api/diagnostics.jl       console_messages, page_errors
test/test_serializers.jl   → Codec round-trips (hermetic)
test/test_codegen.jl       → Generated output is in sync with the vendored spec
test/test_evaluate.jl      → evaluate/handle smoke tests
test/test_frames.jl        → iframe smoke tests
test/fixtures/iframe.html  → Page embedding a same-origin child
test/fixtures/sliders.html → Two input[type=range] elements (mirrors Bonnie's embed_raw)
```

`src/api.jl` is replaced by `src/api/` and its includes; no user-visible names move.

## Decisions

Recorded here because they are the load-bearing choices; challenge them at review
rather than during implementation. D4a and D4b were settled in review; the
remaining open questions are at the end.

**D1. Codegen produces a channel layer only.** Generated functions are mechanical
one-to-one wrappers of protocol commands — build the params `Dict`, send, resolve
channel refs in the result:

```julia
# GENERATED — do not edit. Source: protocol/spec/frame.yml
function _frame_dispatch_event(
    _obj::Frame;
    selector::AbstractString,
    type::AbstractString,
    eventInit,
    timeout::Real,
    strict::Union{Bool,Nothing} = nothing,
)
    params = Dict{String,Any}(
        "selector" => selector, "type" => type,
        "eventInit" => eventInit, "timeout" => timeout,
    )
    strict === nothing || (params["strict"] = strict)
    send_message(_obj, "dispatchEvent", params)
    return nothing
end
```

The hand-written layer supplies the docstring, the snake_case name, the Julia
argument order, the defaults, and the `Locator` ergonomics. Rationale: the spec
carries no docs and no notion of "the nice way to call this"; a fully generated
user API would be a transliteration of TypeScript, not idiomatic Julia. This is
the same split `playwright-python` and the .NET client use.

**D2. Generated code is checked in.** No generation at package build or load
time, no YAML dependency for users, and code review sees protocol changes as a
diff. `gen/generate.jl --check` in CI keeps it honest.

**D3. The `SerializedValue` codec is hand-written.** It is recursive, has a
handles side-channel, and needs circular-reference `id`/`ref` bookkeeping — the
generator would only produce a struct definition, not the interesting part. The
Julia mapping:

| Julia | wire | back |
|---|---|---|
| `Float64`/`Int`/`Rational`… | `{n:…}` | `Float64` (JS numbers are doubles) |
| `String`/`Symbol` | `{s:…}` | `String` |
| `Bool` | `{b:…}` | `Bool` |
| `nothing` | `{v:"null"}` | `nothing` |
| `missing` | `{v:"undefined"}` | `missing` |
| `NaN`/`±Inf` | `{v:"NaN"}` / `{v:"Infinity"}` | same |
| `AbstractVector`/`Tuple` | `{a:[…]}` | `Vector{Any}` |
| `AbstractDict`/`NamedTuple` | `{o:[{k,v}…]}` | `Dict{String,Any}` |
| `Regex` | `{r:{p,f}}` | `Regex` |
| `DateTime` | `{d:…}` | `DateTime` |
| `JSHandle` | `{h:i}` + handles array | `JSHandle` |

Numbers always return `Float64`: JS has one number type, and silently narrowing
`7.0` to `7` would be a lie about what the page returned. `evaluate(p, "7") == 7`
still holds in Julia.

**D4. Strict stays the default.** `locator(page, sel)` remains strict, matching
upstream. Non-strict is opt-in via `strict=false`, and `count`/`nth`/`first`/
`last` are the supported way to work with multiple matches. `nth` is 1-based on
the Julia side and converted to 0-based on the wire.

**D4a. A `Locator` is iterable.** `Base.iterate`, `Base.length`, `Base.getindex`,
`Base.firstindex`/`Base.lastindex` and `Base.eltype` are all defined, yielding
one single-element `Locator` per match:

```julia
for slider in locator(page, "input[type=range]"; strict=false)
    fill_range!(slider, 7)
end
sliders[2] === nth(sliders, 2)
```

Semantics and their costs, which callers need to know:

- `length` is `count`, i.e. **a protocol round-trip**, and `iterate` calls it once
  up front. The element set is sampled at that moment; a page mutating the DOM
  mid-loop can leave later `nth` handles resolving to different elements or to
  nothing. This is inherent to Playwright's lazy-selector model, not a defect —
  it is documented on `iterate`.
- Iteration yields `nth(loc, i)` locators, each of which is itself strict (it
  matches exactly one element by construction), regardless of the parent's
  `strict` setting. Iterating a strict locator is allowed and simply yields at
  most one element rather than erroring — the strictness check happens on *action*,
  and `nth` has already resolved the ambiguity.
- `Base.first(loc)` / `Base.last(loc)` are `nth(loc, 1)` / `nth(loc, count(loc))`
  and, unlike upstream's `.first()`/`.last()`, `last` therefore costs a round-trip.
- `first(loc, n)` (the `Base` method returning a collection) is **not** defined;
  it would read as "first n matches" but cannot return a `Locator`. Use
  `collect(loc)[1:n]`.
- `SubArray`-style views, `map`/`filter` and friends come free via the iteration
  protocol; no `AbstractArray` subtyping, because indexing is a network call and
  the length is not stable.

**D4b. `JSHandle` disposal is explicit, with a scoped form.** Handles hold
browser-side references. `dispose(handle)` releases one; the closure form
releases it on the way out, exception or not, and is what the docs lead with:

```julia
evaluate_handle(page, "() => window.app") do app
    evaluate(app, "a => a.ready")
end   # disposed here, even if the body throws
```

The closure takes the first positional argument so `do ... end` works, matching
`Base.open`/`Base.lock` and this package's own `playwright(f)`. No finalizer:
running protocol I/O from a GC finalizer risks deadlocking against the
connection lock. Handles left undisposed are still reclaimed when their
page/context is closed, so leaking one is a resource cost, not a correctness bug.

**D5. `is_function` is detected, with an override.** `evaluate(page, expr, arg)`
applies upstream's heuristic (does the expression parse as a function or arrow
function?) and passes `isFunction` accordingly; `is_function=true/false`
overrides it. Rationale: matching upstream behaviour matters more than purity —
users will paste JS from Playwright docs.

**D6. Console/errors are pull-based.** `console_messages(page)` and
`page_errors(page)` call the 1.61 getters and return plain Julia structs
(`ConsoleMessage`, `PageError`). No subscription, no background task, no
ordering guarantees beyond the driver's. `clear_console_messages(page)` /
`clear_page_errors(page)` are exposed so per-test isolation is possible.

**D7. `new_page(browser)` keeps its implicit context but tracks it**, so
`close(page)` disposes the context it created. Explicit `new_context(browser)` /
`new_page(context)` / `close(context)` are the recommended path and are what the
docs show. This fixes the per-test context leak `bonnie_needs.md` flags.

## Code Style

Unchanged from `SPEC.md`. Two additions:

- Generated files start with a `# GENERATED …` banner naming the source yml and
  the pinned version, and are excluded from JuliaFormatter's input (the generator
  emits already-formatted code by calling JuliaFormatter itself).
- Hand-written wrappers name the generated function they call in a comment when
  the mapping is not obvious.

```julia
"""
    evaluate(target, expression, arg=missing; is_function=nothing) -> Any

Evaluate `expression` in `target` (a `Page`, `Frame` or `JSHandle`) and return
the result converted to Julia. `arg` is passed to the expression when it is a
function; it is serialized with the same mapping as the return value.

```julia
evaluate(page, "1 + 1")                      # 2.0
evaluate(page, "x => x.a * 2", (a = 21,))    # 42.0
evaluate(page, "document.title")             # "Example Domain"
```
"""
function evaluate(page::Page, expression::AbstractString, arg = missing;
                  is_function::Union{Bool,Nothing} = nothing)
    return evaluate(main_frame(page), expression, arg; is_function)
end
```

## Testing Strategy

Framework and gating unchanged (`Test`, smoke suite behind `PLAYWRIGHT_JL_SMOKE=1`).

- **Hermetic (no browser, no Node):**
  - `test_serializers.jl` — round-trip every row of the D3 table; nested
    structures; circular references (`id`/`ref`); handle placement in the
    `handles` array; unknown tag → informative error. This is the largest new
    unit-test surface and it is where correctness is actually decided.
  - `test_codegen.jl` — `gen/generate.jl --check` reports in-sync output, and the
    generator produces the expected shape for a small hand-written fixture yml.
    Skipped with a clear message if the `gen` environment is not instantiated.
  - `test_connection.jl` — extended for the getters' reply shapes.
- **Smoke (real browser, Chromium *and* Firefox):**
  - `test_evaluate.jl` — values both directions, function vs expression, throwing
    JS surfaces a `PlaywrightError`, `JSHandle` round-trip, and the scoped
    `evaluate_handle(f, …)` form disposing on both the normal and the throwing
    path (asserted by a subsequent use of the handle failing).
  - `test_frames.jl` — `iframe.html`: enumerate `frames`, drive an element inside
    the child via `frame_locator`, read back via `content_frame` + `evaluate`.
  - `test_smoke.jl` — extended: `count`/`nth`/`first`/`last`, `for`-iteration and
    `collect` over a multi-match locator against `sliders.html`,
    `dispatch_event` setting a range input to an exact value, `inner_text`,
    launch options (`args`, `chromium_sandbox=false`), `firefox_user_prefs` on the
    Firefox leg, explicit context lifecycle, `console_messages`/`page_errors`
    against a fixture that logs and throws.
- **Coverage expectation** unchanged: every exported function exercised by at
  least one test; every generated command reachable from at least one hand-written
  wrapper *or* explicitly listed as unwrapped.

## Boundaries

Milestone-1 boundaries still apply. Amendments:

- **Always:** regenerate (`gen/generate.jl`) and re-run the suite after touching
  `protocol/spec/`; keep `PLAYWRIGHT_VERSION` the only place a version is written;
  keep wire-protocol details out of `src/api/`.
- **Ask first:** adding runtime dependencies (generator-only deps in `gen/` are
  fine); bumping `PLAYWRIGHT_VERSION`; changing the D1 codegen boundary; exposing
  an async/task-based API; registering the package.
- **Never:** hand-edit `src/generated/`; generate code at build or load time;
  commit driver/browser binaries; take a runtime dependency on YAML; scrape real
  external sites in tests.

## Success Criteria

1. `gen/generate.jl --check` passes on a clean tree, and deleting
   `src/generated/channels.jl` then regenerating reproduces it byte-for-byte.
2. Hermetic `Pkg.test()` passes with no Node, no browser, and no `gen`
   environment instantiated.
3. With `PLAYWRIGHT_JL_SMOKE=1`, the full suite passes on Chromium **and**
   Firefox, including the iframe and slider fixtures.
4. The target snippet in this spec runs verbatim against
   `test/fixtures/sliders.html` + `test/fixtures/iframe.html`.
5. Every row of the `bonnie_needs.md` table above is satisfied by public,
   documented, exported API.
6. A `with_page` / `evaluate` / `poll_js` shim equivalent to Bonnie's
   `test/cdp.jl` is expressible in under 40 lines using only Playwright.jl's
   public API, and is demonstrated in `README.md` or `docs/`.
7. No orphan node/browser processes after any test run (milestone-1 criterion,
   re-verified with explicit contexts in play).
8. README's API table and "Status" section updated to milestone 2.

## Non-Goals

Deferred to a later milestone, and explicitly not built here: WebKit; event
subscription / `expect_*` / `wait_for_event`; auto-retrying assertions (`expect`);
network interception and routing; downloads, file chooser, dialogs; PDF; video and
tracing; persistent contexts; Android/Electron; an async API; codegen of the
user-facing API surface (see D1).

## Open Questions

1. **Vendoring the spec** — ~19 yml files, a few thousand lines, Apache-2.0.
   Vendoring is proposed (hermetic, reviewable diffs) but it does put Microsoft's
   files in this repo under a `protocol/` directory with its own LICENSE note.
   Alternative: fetch on demand in `gen/` and check in only the generated output.
   *Default if unanswered: vendor.*
2. **`count` vs `Base.length`** — `count(loc)` shadows `Base.count`'s meaning
   ("count matching a predicate"). Options: export `count` as a new method on
   `Locator` (reads best, mild piracy of intent), define `Base.length(loc)`
   instead, or name it `element_count`. *Default if unanswered: extend
   `Base.count` with a `Locator` method, mirroring `Base.fill`/`Base.close`
   precedent from milestone 1.*
3. **Julia version floor** — still 1.10, or is bumping acceptable? Nothing here
   needs it. *Default: stay on 1.10.*
