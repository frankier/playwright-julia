# Implementation Plan: Playwright.jl — Milestone 3 (events, waiting, assertions)

Spec: [`SPEC-M3.md`](../SPEC-M3.md). Earlier plans are archived at
[`tasks/m1/plan.md`](m1/plan.md) and [`tasks/m2/plan.md`](m2/plan.md).

## Context

Milestone 2 made the API broad enough to *write* an e2e suite. Milestone 3 makes
the suite fast, precise and quiet: driver-side waiting instead of hand-rolled
polling, retrying assertions instead of `sleep`, a settable default timeout
instead of a 30 s stall per miss, and errors specific enough to branch on.

Two of the eleven deliverables are cross-cutting and touch every existing API
file — the **error taxonomy** (D2) and the **timeout cascade** (D4). Everything
else builds on them. That dictates the shape of this plan: the cross-cutting
changes land **first**, hermetically, with the milestone-2 smoke suite as the
oracle that nothing regressed. The feature slices then land one at a time on a
stable base. Doing it the other way round would mean rewriting each new slice's
call sites twice.

## Architecture Decisions

Recorded as D1–D5 (plus D1a) in `SPEC-M3.md`. The ones that drive this plan:

- **D1/D1a — unbounded event buffers, scoped handles.** No event is ever dropped,
  so lifetime is load-bearing rather than cosmetic: do-block forms are primary,
  `unsubscribe` detaches *and* empties, and closing an owner closes everything
  beneath it. This is the fiddliest code in the milestone and gets its own task
  (T3) with unit tests written before the user-facing surface (T4) exists.
- **D2 — `PlaywrightError` becomes abstract.** A deliberate breaking change to
  the constructor, confined to internal call sites. It lands first (T1) so no
  later task writes `throw(PlaywrightError(...))` that then has to be rewritten.
- **D3 — `expect` is driver-side** (`frame.expect`, `protocol/spec/frame.yml:749`),
  not a Julia poll loop. The protocol's `expression` strings are not documented in
  the yml, so T6 opens with a probe to pin the mapping.
- **D4 — timeout cascade** resolved client-side; there is no `setDefaultTimeout`
  command in the 1.61 protocol. One resolver, called by every entry point.
- **D5 — gap 5 is a probe, not a design.** T8 finds out what the driver actually
  does with engine-irrelevant launch options before anything is built.

## Dependency Graph

```
T0 fixtures (late element, popup, chatty console, sync-firing event)   [hermetic]
 │
T1 error taxonomy (src/errors.jl)                                     [hermetic]
 ├── T2 timeout mechanism (src/timeouts.jl, set_default_timeout!)      [hermetic]
 │    └── T2b thread resolve_timeout through every api/ call site      [hermetic]
 │          ├── T5 wait_for_selector / wait_for_function      ┐
 │          ├── T6 expect(...) over frame.expect              │ parallel
 │          └── T7 Locator ergonomics (evaluate on Locator)   ┘
 └── T3 event registry + Subscription lifetime (src/api/events.jl)     [hermetic]
      └── T4 expect_event / wait_for_event + event smoke tests

T8 engine metadata + launch-option probe   ─ independent, any time after T1
T9 install ergonomics (bin/install.jl)     ─ independent, no deps at all
T11 TargetClosedError on closed-page calls ─ independent, any time after T1
T10 docs, target-snippet verification, format   ← depends on T4–T9
```

Parallelizable: **T2 ∥ T3** (disjoint files). After T2b, **T5 ∥ T6 ∥ T7** are
disjoint (`waiting.jl` / `expect.jl` / `locators.jl`). **T8** and **T9** are
independent of the whole chain and can be picked up whenever, including first if
a browser-free session is wanted.

Critical path: T1 → T2 → T2b → T6 → T10.

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| **Weak-keyed registry + cascade-close is subtle** — leaks and use-after-close are easy to write and hard to see | T3 is hermetic and test-first; lifetime is asserted directly against the registry, not inferred from behaviour (SC 7) |
| **Unbounded buffers make a leak unbounded too** | Do-block forms are primary and documented as such; bare `subscribe` is the escape hatch; finalizer as last-resort net (D1a) |
| **`frame.expect` expression strings are undocumented** in the vendored yml | T6 opens with a probe against the live driver; the mapping is recorded in the task before the API is written |
| **Breaking `PlaywrightError`** could break user code beyond this repo | Abstract supertype keeps `catch e isa PlaywrightError` and `.message`/`.name`/`.stack` working; only the constructor breaks, and it is internal-only. Noted in README |
| **Threading timeouts through every call site (T2b) is broad and mechanical** — easy to miss one | Grep-driven: the acceptance criterion is that `grep -rn '30_000' src/api/` returns nothing |
| **Firefox diverges** from Chromium on events and waiting | Every smoke test runs on both engines, as in M2; divergence is documented, not papered over |
| **Sync-fired events race** the subscription | Explicit regression fixture (T0) + test (T4): an event fired synchronously inside the do-block body must still be caught |

## Verification Checkpoints

- **Checkpoint A** — after T0–T3: hermetic `Pkg.test()` green with no Node and no
  browser; M2 smoke suite still green (nothing regressed under the taxonomy and
  timeout changes); `gen/generate.jl --check` green. **Human review of the event
  registry and error taxonomy before any feature builds on them.**
- **Checkpoint B** — after T4–T9: every slice's smoke tests green on Chromium
  *and* Firefox; hermetic suite still green.
- **Checkpoint C** — after T10: all twelve `SPEC-M3.md` success criteria verified;
  target snippet runs verbatim.

## Tasks

### T0 — Fixtures for waiting, events and assertions (S)

- **Acceptance:** `test/fixtures/` gains pages exercising: an element that appears
  after a delay; a `window.ready` flag set late; a button that opens a popup; a
  button whose handler fires a console message *synchronously*; a page emitting
  5 000 console messages on demand; two `input[type=range]`s.
- **Verify:** fixtures served by the existing HTTP.jl test server; each loads and
  behaves manually via a one-off script.
- **Files:** `test/fixtures/*.html` (new), `test/runtests.jl` if the server needs
  a new route.

### T1 — Error taxonomy (M) — gap 4, D2

- **Acceptance:** `src/errors.jl` defines abstract `PlaywrightError` with
  `DriverError`, `TimeoutError`, `TargetClosedError`, `AssertionFailure` beneath
  it, all carrying `.message`/`.name`/`.stack`. A driver reply is classified by
  its `name` field (`"TimeoutError"` → `TimeoutError`) and by target-closed
  detection; everything else is `DriverError`. All internal construction sites
  (`connection.jl`, `serializers.jl`) move to concrete types. New types exported.
- **Verify:** `test/test_errors.jl` classifies canned `{message, name, stack}`
  payloads; `catch e isa PlaywrightError` and `e.message` still work on every
  subtype; hermetic suite green; M2 smoke suite green.
- **Files:** `src/errors.jl`, `src/connection.jl`, `src/serializers.jl`,
  `src/Playwright.jl`, `test/test_errors.jl`.

### T2 — Timeout settings and resolver (M) — gap 3, D4

- **Acceptance:** `src/timeouts.jl` defines the settings side table and
  `resolve_timeout(target, kwarg)` implementing `kwarg → page → context →
  package default` (30 s action, 30 s navigation). `set_default_timeout!` and
  `set_default_navigation_timeout!` exported for `Page` and `BrowserContext`.
  Settings are dropped when the owner closes.
- **Verify:** hermetic unit tests for the cascade, including a page inheriting
  from its context and overriding it.
- **Files:** `src/timeouts.jl`, `src/objects.jl`, `src/api/lifecycle.jl`,
  `src/Playwright.jl`, `test/test_timeouts.jl`.

### T2b — Thread the resolver through every call site (M) — deps: T2

- **Acceptance:** every `timeout` keyword in `src/api/` defaults to `nothing` and
  resolves via `resolve_timeout`; no literal timeout default survives outside
  `src/timeouts.jl` (`launch`'s 180 s startup timeout is explicitly exempt and
  documented as such).
- **Verify:** `grep -rn '30_000' src/api/` returns nothing; M2 smoke suite green
  unchanged; a smoke test asserts `set_default_timeout!(ctx, 2_000)` makes a
  missing selector fail in ≈2 s via `@elapsed` (SC 3).
- **Files:** `src/api/navigation.jl`, `src/api/locators.jl`, `src/api/frames.jl`,
  `src/api/evaluate.jl`, `test/test_smoke.jl`.
- **Finding (implementation):** T2's cascade was walking the `__create__` tree,
  which does **not** contain a frame → page link for the frame that matters. The
  driver parents a page's *main* frame to the **browser context** and sends it
  *before* the page; only child frames (iframes) are parented to the page.
  Verified on Chromium and Firefox alike. The effect was that
  `set_default_timeout!(page, …)` was silently ignored by every
  `locator(page, …)`, since page-level locators always resolve through the main
  frame — the context's setting won instead. `test_timeouts.jl`'s fixture had
  parented the main frame to the page and so hid this. Fixed with
  `Connection.settings_parents`, a frame → page hop consulted before
  `conn.parents`, kept separate from the protocol tree so the dispose cascade is
  untouched, and pruned from both ends in `dispose_locked`.

### T3 — Event registry and subscription lifetime (L) — deps: T1, D1/D1a

- **Acceptance:** `src/api/events.jl` provides an internal `Subscription`
  (unbounded `Channel`) and a registry weakly keyed by owner. `dispatch` in
  `connection.jl` routes named events to subscribers, leaving `__create__`,
  `__dispose__`, `navigated`, `frameDetached` handling intact and still never
  dying on an unknown guid. `unsubscribe`/`close(sub)` detaches **and** empties;
  `close` is idempotent; closing a `Page`/`BrowserContext`/`Browser` closes
  subscriptions beneath it; dispatch to a closed subscription is a no-op;
  `playwright()` teardown clears the registry. Finalizer as last-resort net.
- **Verify:** `test/test_events.jl` drives canned protocol traces — routing to the
  right subscriber, unknown guid ignored, no event dropped across 5 000 messages,
  registry empty after unsubscribe / after owner close / after a block that threw,
  buffer emptied not merely detached, double close fine. No browser needed.
- **Files:** `src/api/events.jl`, `src/connection.jl`, `src/objects.jl`,
  `src/Playwright.jl`, `test/test_events.jl`.

### T4 — `expect_event` / `wait_for_event` user surface (M) — deps: T0, T2b, T3

- **Acceptance:** `expect_event(f, target, event; timeout, predicate)` (do-block,
  subscribes before running `f`), `wait_for_event(target, event; …)` and
  `with_events(f, target, event)` exported. Event names are `Symbol`s, wire
  spelling accepted.

  **Supported set — events whose payload is useful with the types this milestone
  ships**, and only those:

  | Owner | Event | Payload |
  |---|---|---|
  | `Page` | `:close`, `:crash` | the `Page` itself |
  | `Page` | `:frameattached`, `:framedetached` | `Frame` |
  | `BrowserContext` | `:page` | `Page` (popups) |
  | `BrowserContext` | `:close` | the context |
  | `BrowserContext` | `:console` | `ConsoleMessage` (M2 type) |
  | `BrowserContext` | `:pageerror` | `PageError` (M2 type) |

  Everything else is **not supported**. That includes `:download` (`Artifact`),
  `:dialog` (`Dialog`), `:filechooser`, `:worker`, `:websocket`, `:route` and
  `:bindingcall`, whose wrapper types are non-goals — and also the network family
  `:request` / `:response` / `:requestfailed` / `:requestfinished`: `Request` and
  `Response` exist as generated channel-owner structs
  (`src/generated/channels.jl:172`) but have **no hand-written accessors**, so the
  payload would be an object you cannot read a URL or status off without dropping
  to the generated layer. Lifting them is a payload-mapping entry plus a small
  accessor set (`url`, `method`, `status`, `ok`) — deferred, not designed away. Asking for one raises `ArgumentError` naming the event and saying
  it is deferred, rather than silently handing back a `RemoteObject`. The registry
  and dispatch layer stay generic, so adding one later is a payload-mapping entry
  and nothing else.

  Payload channel objects resolve through the existing registry; a popup arrives
  as a `Page`, returned immediately without waiting for its first navigation
  (OQ 4). Timeout raises `TimeoutError`.
- **Verify:** smoke on both engines — popup via `expect_event(ctx, :page)`;
  `close`; `:console` payload arrives as a `ConsoleMessage`; the **sync-fired
  regression fixture** is caught (SC 6); a timed-out wait raises `TimeoutError`;
  an unsupported event name raises `ArgumentError`; registry empty after each
  block.
- **Files:** `src/api/events.jl`, `src/Playwright.jl`, `test/test_events.jl`,
  `test/fixtures/` (from T0).
- **Findings (probed against the 1.61 driver, both engines):**
  1. **`console` is opt-in.** The driver stays silent until the client sends
     `updateSubscription` (`browserContext.yml:264`); subscribing to the buffer
     alone buys a 30 s wait and nothing else. The opt-in set on a
     `BrowserContext` is console/dialog/request/response/requestFinished/
     requestFailed, of which only `console` is supported here. `page`, `close`,
     `crash`, `pageError` and the frame events fire unconditionally. The
     enable/disable pair is ref-counted per owner+event so nested blocks do not
     switch each other off.
  2. **`pageError` nests its payload one level deeper** than the buffered
     `page_errors` getter: params are
     `{error: {error: {message, name, stack}}, page, location}`.
  3. **`frameDetached` was being swallowed.** `dispatch` intercepted it to prune
     the frame and never forwarded it, so `:framedetached` could not fire. It
     now delivers *before* pruning. Related: payload mapping moved to delivery
     time rather than take time, because the frame is disposed moments after
     the event and a later registry lookup finds nothing.
  4. **D1a amended (agreed with the human reviewer).** The driver sends `close`
     and then `__dispose__` back to back for the same page, so draining buffers
     in `close_subscriptions_locked` destroyed the very event
     `expect_event(page, :close)` was waiting for. Owner-dispose now **detaches
     without draining**: the connection dropping its reference is what bounds
     the buffer, anything still buffered lives only as long as the waiter's
     handle, and the finalizer drains a leaked one. Explicit
     `close(sub)`/`unsubscribe` still empties, and connection teardown
     (`close_all_subscriptions`) still drains.
  5. A wait on a closed-and-empty subscription raises `TargetClosedError` at
     once rather than sitting out the timeout — the answer is already settled.

### T5 — `wait_for_selector` / `wait_for_function` (M) — deps: T2b — gap 1

- **Acceptance:** both exported and working on `Page`, `Frame` and `Locator`,
  over the already-generated `_frame_wait_for_selector` /
  `_frame_wait_for_function`. `state` (`:attached`/`:detached`/`:visible`/
  `:hidden`), `polling` and `arg` supported; results come back as
  `ElementHandle`/`JSHandle` through the M2 handle machinery; timeouts resolve via
  T2 and raise `TimeoutError`.
- **Verify:** smoke on both engines against the late-element and `window.ready`
  fixtures; a missing selector raises `TimeoutError` (not `DriverError`), and a
  JS exception inside `wait_for_function` raises `DriverError` (not
  `TimeoutError`) — SC 4.
- **Files:** `src/api/waiting.jl`, `src/Playwright.jl`, `test/test_smoke.jl`.

### T6 — Retrying assertions over `frame.expect` (L) — deps: T2b — D3

- **Acceptance:** *Probe first* — pin the `expression` strings and the shape of
  the `received`/`timedOut` error details against the live driver, and record the
  mapping in this task before writing the API. Then `expect(loc; to_have_text,
  to_have_count, to_be_visible, to_have_value, to_have_attribute, …)` exported,
  with `isNot` support (`to_have_text = Not("x")` or a `negate` keyword — decide
  at probe time), timeouts via T2, and failures raising `AssertionFailure` whose
  message carries expected **and** received. `retry_until(f; timeout, interval)`
  ships as the Julia-side escape hatch.
- **Verify:** smoke on both engines, pass *and* fail paths; a failing assertion's
  message contains both values (SC 7); a passing assertion against a late-arriving
  element proves retrying actually happens (no `sleep` in the test).
- **Files:** `src/api/expect.jl`, `src/Playwright.jl`, `test/test_expect.jl`,
  `test/fixtures/` (from T0).
- **Probe results (1.61.1 driver, Chromium; recorded before the API was written):**

  | Matcher | `expression` | Payload |
  |---|---|---|
  | text | `to.have.text` | `expectedText: [{string: "…"}]` |
  | count | `to.have.count` | `expectedNumber: 3` |
  | visible / hidden | `to.be.visible` / `to.be.hidden` | — |
  | value | `to.have.value` | `expectedText: [{string: "…"}]` |
  | attribute | `to.have.attribute.value` | `expressionArg: "href"` + `expectedText` |

  `isNot: true` inverts as expected. Decisions taken from this:
  1. **A failure is an error reply, not a result.** There is no `matches: false`
     to inspect — the driver raises `ExpectError` with the message
     `"Expect failed"`. The generated `_frame_expect` also ends in
     `return nothing` (the yml has `errorDetails` but no `returns:`), so the
     binding discards the reply. The API is therefore built around catching,
     not around reading a result.
  2. **`received` is available but was being thrown away.** The error frame
     carries a top-level `errorDetails` that `connection.jl` never read:
     `{"received":{"value":{"s":"Hello"},"ariaSnapshot":…},"timedOut":true}`,
     plus `customErrorMessage` (`"element(s) not found"`) when the selector
     misses. `received.value` is a plain SerializedValue, so `from_serialized`
     decodes it. Threading `errorDetails` through `driver_error` is what makes
     SC 7 structural rather than a scrape of the call-log wording. Agreed with
     the reviewer; other error types are unaffected, having no `errorDetails`.
  3. **A bogus expression fails identically** to a real mismatch (`to.be.bogus`
     → the same generic `"Expect failed"`), so the matcher set stays closed on
     the Julia side — a typo has to be caught here or not at all.
  4. **Negation is `Not(x)` per matcher**, not a call-wide `negate` keyword:
     each matcher is its own protocol call, so one flag for a call carrying
     several would be ambiguous.

### T7 — Locator ergonomics (M) — deps: T2b — gap 2

- **Acceptance:** `evaluate(loc, expr, arg)`, `evaluate_all(loc, expr, arg)`,
  `element_handle(loc)` exported, routed through `frame.evalOnSelector` /
  `evalOnSelectorAll` with the locator's `strict` flag honoured. `frame(loc)`,
  `selector(loc)`, `is_strict(loc)` blessed as public accessors with docstrings.
- **Verify:** smoke on both engines: set a range input's value through
  `evaluate(loc, …)`; the `fill_range!` example from `SPEC-M2.md` is rewritten
  using exported API only — no `loc.frame`, no `loc.selector` (SC 5).
- **Files:** `src/api/locators.jl`, `src/api/evaluate.jl`, `src/Playwright.jl`,
  `test/test_smoke.jl`, `SPEC-M2.md` (example only).

### T8 — Engine metadata and launch-option partitioning (M) — gaps 5, 6, D5

- **Acceptance:** `browser_name` gains a `Browser` method and is **exported**. It
  already exists for `BrowserType` (`src/objects.jl:10`, unexported, returns
  `String`) and is asserted in `test/test_smoke.jl:48`, so the new method returns
  a `String` too rather than the `Symbol` first sketched — one name, one return
  type, no breakage. Read from the initializer (`browser.yml` carries both `name`
  and `browserName`; confirm which is the engine name during implementation). *Probe first:* launch Firefox with
  `args`/`chromium_sandbox` and Chromium with `firefox_user_prefs` against the
  real driver. If irrelevant options are ignored, the deliverable is a docstring
  sentence stating so, with the probe recorded as evidence; if they error, ship
  `launch_options(kind; kwargs...)` that filters per engine.
- **Verify:** smoke asserts `browser_name` on both engines; whichever branch the
  probe selects is exercised by a test or, for the docstring branch, by a smoke
  test passing one shared option set to both engines (SC 9, 11).
- **Files:** `src/api/lifecycle.jl`, `src/Playwright.jl`, `test/test_smoke.jl`.
- **Probe results (both engines):** engine-irrelevant launch options are
  **silently ignored, never errors**. Firefox with `args` and
  `chromium_sandbox`, Chromium with `firefox_user_prefs`, and one shared option
  set passed to both engines all launched *and* rendered a page. D5 therefore
  selects the **docstring branch**: no `launch_options(kind; …)` filter ships,
  because the probe shows it would guard against nothing.
  Also confirmed: `name` and `browserName` are identical in the Browser
  initializer on both engines, so `browser_name(::Browser)` reads
  `initializer["name"]` and returns a `String`, matching the existing
  `BrowserType` method.

### T9 — Install ergonomics (S) — gap 7 — no deps

- **Acceptance:** `bin/install.jl` installs driver and browsers standalone;
  `PLAYWRIGHT_BROWSERS_PATH` is honoured for the browser cache location; README
  documents the recipe for a project with Playwright.jl in `[targets] test` rather
  than `[deps]`.
- **Verify:** run from a clean checkout with the package absent from `[deps]`;
  run with `PLAYWRIGHT_BROWSERS_PATH` set to a temp dir and confirm the browsers
  land there (SC 10).
- **Files:** `bin/install.jl`, `src/driver.jl`, `README.md`.
- **Finding (implementation):** `PLAYWRIGHT_BROWSERS_PATH` needed no code at all —
  the driver reads it itself, and both `install()` and the `run-driver`
  subprocess inherit Julia's environment, so installing and launching already
  agree on the location. Verified rather than assumed: installing Chromium with
  the variable set put 646 MB under the named directory, and a subsequent
  `launch` + `goto` against that same directory worked (SC 10). The real gap was
  reachability — `install()` is only callable once Playwright.jl is loadable,
  which a project carrying it in `[targets] test` cannot do outside
  `Pkg.test()`. `bin/install.jl` closes that: run from `/tmp` with no project
  active, it activates the checkout itself and installs. Browser names are
  validated before any download starts.

### T10 — Docs, target snippet, polish (M) — deps: T4–T9

- **Acceptance:** the `SPEC-M3.md` target snippet runs verbatim against the
  fixtures on both engines and is committed as a test; README gains sections on
  events, waiting, assertions and default timeouts, plus a note on the
  `PlaywrightError` change; every new export has a docstring;
  `JuliaFormatter.format(".")` is clean.
- **Verify:** all twelve success criteria walked and ticked; hermetic suite green;
  full smoke green on both engines; `gen/generate.jl --check` green.
- **Files:** `README.md`, `test/test_smoke.jl`, docstrings across `src/api/`.

### T11 — Uniform `TargetClosedError` for calls on a closed page (S) — deps: T1

- **Context:** found during T1. `title(page)` on a closed page does not raise
  `TargetClosedError`; it raises a Julia `TypeError` from
  `main_frame` (`src/objects.jl:13`), because the frame's guid is already gone
  from the connection registry by the time the call runs, so `from_channel`
  returns something the `::Frame` assertion rejects. Every `Page` method that
  hops through `main_frame` — `goto!`, `title`, `evaluate`, `locator`,
  `frames`, `frame_locator` — has the same hole. Pre-existing, and outside T1's
  scope, so left alone there.
- **Acceptance:** resolving a channel object that has been disposed because its
  target closed raises `TargetClosedError` rather than `TypeError` or
  `KeyError`. Whether that lands in `from_channel`, in `main_frame`, or as a
  guard on the `Page` entry points is an implementation call; the invariant is
  that no user-facing call on a closed page escapes with a non-`PlaywrightError`
  exception.
- **Verify:** smoke test on both engines — close a page, then call `title`,
  `evaluate` and `locator` on it; each raises `TargetClosedError`. Hermetic
  coverage where a canned `__dispose__` trace can stand in for the browser.
- **Files:** `src/objects.jl`, `src/connection.jl`, `src/api/navigation.jl`,
  `test/test_smoke.jl`.
- **Finding (implementation):** the guard has to key on the **page**, not on the
  frame. Probed on both engines: closing a page disposes the page but leaves its
  main frame registered, because the driver parents a main frame to the browser
  context rather than to the page (the same protocol shape that bit T2b).
  Guarding on the frame therefore catches nothing on a page close and only fires
  when the whole context goes. Guarding on the page catches both, since
  disposing a context cascades to its pages. This also closed a second hole the
  task had not anticipated: `title`/`evaluate` were already raising
  `TargetClosedError` from the driver, but `locator` does no round-trip, so it
  returned an ordinary `Locator` for a page that no longer existed and failed
  confusingly later. Caught by smoke — the first hermetic fixture disposed the
  context rather than the page and hid it.

## Sizing

S = under an hour, M = a focused session, L = a long session with review.
T0 (S), T1 (M), T2 (M), T2b (M), T3 (L), T4 (M), T5 (M), T6 (L), T7 (M),
T8 (M), T9 (S), T10 (M), T11 (S).
