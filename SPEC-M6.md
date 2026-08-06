# Spec: Playwright.jl — Milestone 6 (a Julia-shaped API, and the network)

Successor to [`SPEC.md`](SPEC.md) (M1), [`SPEC-M2.md`](SPEC-M2.md),
[`SPEC-M3.md`](SPEC-M3.md), [`SPEC-M4.md`](SPEC-M4.md) and
[`SPEC-M5.md`](SPEC-M5.md), all five complete. Tech stack, driver architecture,
the codegen/API split, code style, testing layout and boundaries carry over
unchanged unless contradicted here.

M6 has two parts, and they ship in this order for one reason: **Part B
introduces about twenty new exported names, and they should be born with the
right shape rather than renamed a week later.**

- **Part A — the bang convention.** Every call that changes remote state gets a
  `!`. Twelve renames, package-wide.
- **Part B — the network.** Request/Response accessors, the four network
  events, route interception, and enough of `APIRequestContext` to fulfil a
  route from a real upstream response.

## Assumptions

Calls this spec makes without being told. Correct any that are wrong.

1. **New spec, not a rewrite.** `SPEC-M6.md` joins its five predecessors; none
   of them are edited.
2. **Breaking changes are allowed and expected.** Nothing is registered in
   General and nothing depends on this package. Part A is a package-wide
   breaking rename with no deprecation shims — old spellings simply stop
   existing.
3. **Part A is a naming change, not an API redesign.** No signature changes, no
   argument reordering, no behaviour changes. This matters for reviewability:
   Part A's diff should be almost entirely mechanical, and anything in it that
   is *not* mechanical is a bug in Part A.
4. **The nine items in [`tasks/m5-api-gaps.md`](tasks/m5-api-gaps.md) stay
   unfixed**, except where Part A resolves one as a side effect (D3 says which,
   and there is exactly one). They are a later milestone's subject. In
   particular M6 does not touch gap 5 (`retry_until` argument order), gap 8
   (`evaluate`'s three meanings) or gap 2 (`is_visible`'s missing `timeout`).
5. **Playwright stays pinned at 1.61.1.** No protocol re-vendor, no
   regeneration of `src/generated/channels.jl`. Every command M6 needs already
   exists there — verified: `_route_abort/_route_continue/_route_fulfill`
   (`channels.jl:4257–4305`), `_response_body`,
   `_api_request_context_fetch`, `_api_request_context_fetch_response_body`,
   and both `set_network_interception_patterns`.
6. **Sync-only, Julia floor 1.10.** Load-bearing here: the handler-execution
   design in D5 exists precisely because there is no async API to fall back on.
7. **Chromium and Firefox both, or it does not ship.** Every success criterion
   involving a browser is verified on both.
8. **Linux-only remains the claim.** No CI matrix change.
9. **No new package dependency.** `JSON` and `Base64` are already in `[deps]`,
   which is what makes `fulfill!(...; json = …)`, `json(response)` and binary
   bodies free. `HTTP` stays test-only.
10. **WebSocket routing stays out.** `WebSocketRoute` stays unwrapped and
    `:websocketroute` stays in `DEFERRED_EVENTS`. Same for `route_from_har`
    (needs `localUtils`) and `Worker` / `:serviceworker`.

## Objective

### Part A — the package should read like Julia

`playwright-python` is the right influence for *what* the calls are and *what
they are called*; it is the wrong influence for punctuation. Python has no bang
convention, so `page.goto(url)` and `page.title()` look alike there. Julia has
one, and a package that ignores it reads as a transliteration.

Today `goto`, `click`, `fill` and `close` — every one of which changes the state
of a live browser — are spelled exactly like `title`, `url` and `count`, which
read it. A Julia user cannot tell from a call site which of these is a question
and which is an action. That distinction is the single thing the bang convention
exists to carry, and this package currently throws it away.

After Part A, `!` means *this changes something in the browser*:

```julia
goto!(page, url)                          # acts
title(page)                               # asks
click!(locator(page, "#save"))            # acts
text_content(locator(page, "#status"))    # asks
```

### Part B — the package should be able to see and answer the network

M1–M5 built a package that can drive a page and prove what it shows. It cannot
say anything about **what the page asked the network for**, and it cannot answer
for the network itself.

`src/api/events.jl:288` lists eleven `DEFERRED_EVENTS` and the first four are
`:request`, `:response`, `:requestfailed`, `:requestfinished` — deferred with the
honest reason "Request has no hand-written accessors yet". `Route` is on the
same list. The generated layer has every type and command; what is missing is
the hand-written Julia between them and a user.

**The user** is someone writing an end-to-end test for a Julia web app who hits
one of three walls:

- *The backend is not the thing under test.* They want the page rendered against
  a fixed, fast, deterministic API response. Today their only option is to run
  the real backend.
- *The assertion is about a request, not about the DOM.* "Clicking Save sends
  exactly one `POST /api/todos` with this body" is a claim about traffic, and
  today it can only be checked by instrumenting the server — which proves the
  server saw something, not that the browser sent it.
- *The backend is real but one field of it is wrong for this test.* They want
  the actual upstream response with `status` flipped to 500, or one key of the
  JSON replaced. This needs the request to be genuinely performed and then
  modified, which is why `APIRequestContext` is in scope (D12).

After this milestone, each is a few lines:

```julia
with_route(ctx, "**/api/todos", r -> fulfill!(r; json = [Dict("id" => 1, "text" => "buy milk")])) do
    goto!(page, base_url)
    expect(locator(page, ".todo"); to_have_count = 1)
end

req = expect_request(ctx, "**/api/todos") do
    click!(locator(page, "#save"))
end
@test method(req) == "POST"
@test json(req)["text"] == "buy milk"

# the real response, with one thing changed
with_route(ctx, "**/api/health", function (r)
    upstream = Playwright.fetch(r)
    fulfill!(r; response = upstream, status = 500)
end) do
    goto!(page, base_url)
    expect(locator(page, "#banner"); to_have_text = "Service unavailable")
end
```

**The second user is the maintainer of the driving use case.**
[`docs/bonnie-parity.md`](docs/bonnie-parity.md) records a hand-rolled CDP
harness being replaced row by row; network interception is the largest remaining
block of raw CDP in it, and the reason that file still has rows.

### What M6 is *not*

Not a HAR recorder or player, not a WebSocket tool, not a proxy, and not a
general-purpose HTTP client — `APIRequestContext` comes in only as far as D12
draws the line. It intercepts and observes the traffic of pages this package is
already driving.

---

# Part A — the bang convention

## D1 — The rule: `!` means it changes remote state

Julia's own convention is "mutates one of its arguments". That reading does not
survive contact with a browser driver: `click!(loc)` does not mutate `loc`, a
client-side selector object — it mutates the DOM three processes away. Taken
literally, almost nothing here would take a bang, which is the wrong answer.

**The rule this package adopts:** a bang means *the call changes state the page
can observe*. A non-bang call asks a question and leaves the world alone.

That gives a clean, defensible split, and — importantly — it is a rule a user
can apply themselves to predict a name they have not seen.

| Renamed | Was | Why |
|---|---|---|
| `goto!` | `goto` | navigates |
| `click!` | `click` | clicks |
| `set_value!` | `fill` (extends `Base.fill`) | types into an input (D3) |
| `dispatch_event!` | `dispatch_event` | fires a DOM event |
| `close!` | `close` (extends `Base.close`) | closes a browser/context/page |
| `dispose!` | `dispose` | releases a remote handle |
| `delete_file!` | `delete` | deletes an artifact's file (D3) |
| `save_as!` | `save_as` | writes a file |
| `start_tracing!` | `start_tracing` | starts recording |
| `stop_tracing!` | `stop_tracing` | stops recording, writes a file |
| `clear_console_messages!` | `clear_console_messages` | empties a buffer |
| `clear_page_errors!` | `clear_page_errors` | empties a buffer |

Already correct and untouched: `set_default_timeout!`,
`set_default_navigation_timeout!`.

## D2 — What deliberately keeps no bang

The interesting half of the rule is what it excludes. Each of these was
considered and rejected, and the reasons are the rule's real definition:

- **`screenshot`, `pdf`** — they write a file, but they change nothing the page
  can see. They are reads with a side effect on *your* disk, not on the browser.
  Under D1's rule, no bang. This is the line most likely to be argued with, and
  the answer to the argument is that `screenshot(page)` with no `path` writes
  nothing at all — a name that changes meaning with a keyword argument would be
  worse than either choice.
- **`launch`, `new_page`, `new_context`** — they *create* rather than mutate.
  Julia does not bang constructors, and `push!`-style banging of a factory would
  be novel punctuation, not convention.
- **`evaluate`, `eval_on_selector`** — they run arbitrary JS that may do
  anything, so under a strict reading they should bang. They do not, because the
  bang would be permanently on and therefore carry no information: every
  `evaluate` would have it. A name that is always banged is a name with no bang.
  The docstring says out loud that `evaluate` can mutate.
- **Everything that reads** — `title`, `url`, `text_content`, `inner_text`,
  `inner_html`, `get_attribute`, `input_value`, `count`, `is_visible`,
  `is_checked`, `is_enabled`, `frames`, `pages`, `contexts`, `console_messages`,
  `page_errors`, `video`, `path`, `selector`, `browser_name`.
- **`expect`, `retry_until`, `wait_for_selector`, `wait_for_function`,
  `expect_event`, `wait_for_event`, `with_events`, `with_page`, `with_tracing`**
  — assertions and scaffolding. They wait and check; they do not act. The
  do-block forms run a body that may well act, but the banging belongs on the
  calls *inside* the block, not on the block form.

## D3 — The bang collides with `Base` twice, and the naive rename is a trap

`tasks/m5-api-gaps.md` gap 1 is that `fill`, `close`, `count`, `first`, `last`
and `length` extend `Base` and so cannot be exported or seen by
`checkdocs = :exports`. Part A is a rename, not a gap fix, but it cannot avoid
touching this — and the naive rename makes things *worse*, which is worth
showing rather than asserting.

**The trap: `Base.fill!` and `Base.delete!` already exist and are exported by
default.** Renaming to `fill!` / `delete!` and exporting them does not extend
Base — it creates two exported bindings of the same name, and Julia refuses to
guess. Verified:

```julia
julia> using Playwright        # a module exporting its own fill! / delete!

julia> fill!([1, 2, 3], 0)
ERROR: UndefVarError: `fill!` not defined in `Main`
Hint: It looks like two or more modules export different bindings with this
name, resulting in ambiguity.
```

That breaks `fill!` on arrays and `delete!` on dictionaries for anyone who
writes `using Playwright` — strictly worse than today, where `fill` quietly
extends `Base.fill` and simply works. The bang is what causes it: `fill`
collides with a *generic* `Base.fill` that this package can extend, while
`fill!` collides with an *exported* `Base.fill!` that it cannot.

So the three renames that would have collided take names of their own:

| Name | Why not the obvious spelling |
|---|---|
| `set_value!` | `fill!` is ambiguous with `Base.fill!` (above). `set_value!` also says what it does to an input element, which `fill` never did. |
| `delete_file!` | `delete!` is ambiguous with `Base.delete!`. And deleting an artifact's file on disk has nothing to do with removing a key from a collection — extending `Base.delete!` would have been a semantic lie, not just a clash. |
| `close!` | No collision: there is no `Base.close!`. This one is simply the rename. |

**All three become first-class exports**, visible to `names(Playwright)` and
covered by `checkdocs = :exports` — which they were not before. **Gap 1 is
resolved outright for `fill` and `close`**, not traded sideways.

Their docstrings name Playwright's own spelling (`fill`, `delete`) in the first
line, so someone translating a Playwright example searches for `fill` and lands
on `set_value!`.

**`count`, `first`, `last`, `length`, `iterate` and `getindex` still extend
`Base`** and still are not exported — they are the iteration and indexing
protocol for `Locator`, extending `Base` is exactly right for them, and they
take no bang because they read. Gap 1 stands for these, unchanged and correctly
so.

## D4 — The rename is mechanical, and proved to be

Assumption 3 says Part A changes no behaviour. The way that claim is made
checkable rather than asserted:

- Each rename is a single commit touching `src/`, `test/`, `docs/`, `examples/`
  and `README.md` together — a repo-wide substitution of one name, nothing else.
- The full hermetic and smoke suites are green *between* renames, not only at
  the end, so a broken rename is attributed to the rename that broke it.
- After the last one, the old names are gone: a grep for each old spelling as a
  call (`\bgoto\(`, `\bclick\(`, …) across `src`, `test`, `docs` and `examples`
  returns nothing. That grep is a test (SC A4), not a habit.

---

# Part B — the network

## D5 — Handlers run on a dispatcher task, one per routed owner

The central decision of Part B; everything else follows it.

`src/api/events.jl:9` states the constraint: *"Nothing here invokes user code.
The transport reader task cannot call closures defined after it started (world
age), so it only ever `put!`s into a channel."* A route handler is user code
that must *also* call back into the driver (`fulfill!` is a protocol command).
Running it on the reader task is doubly impossible: world age forbids it, and
the handler would block the connection it needs for its own call.

So `route` events feed an ordinary `Subscription` buffer like every other event,
and a **dispatcher task** — spawned per owner when its first handler is
registered, stopped when its last is removed — drains that buffer and runs
handlers.

- **One task per owner; handlers run sequentially in arrival order.** Not one
  task per route. Sequential handling makes ordering deterministic, stops a
  handler's `fulfill!` interleaving with the next request's handler, and means a
  user closure touching shared state needs no lock. The cost is that a slow
  handler delays later requests on the same owner — the same cost
  `playwright-python`'s sync API pays, and acceptable in a test.
- **Handlers are tried newest-registration-first**, as Playwright does. The
  first whose matcher matches *and that settles the route* wins.
- The dispatcher holds no lock while running user code.

Rejected: running handlers on the calling task at block exit (cannot work — the
request is blocked *now*, inside `goto!`), and one task per route
(nondeterministic ordering for a marginal win when the request is already
blocked).

## D6 — A route nobody settles is continued, never left hanging

An intercepted request stops dead until someone calls `abort!`, `continue!` or
`fulfill!`. A hung request is the worst failure mode available here: it surfaces
as an unrelated 30-second `goto!` timeout, metres from its cause.

| Case | What happens |
|---|---|
| No matcher matched | `continue!` immediately, silently — the normal case for the catch-all pattern the driver is given |
| A handler ran and returned without settling | `continue!`, plus one `@warn` per registration naming the URL |
| A handler threw | `continue!`, exception recorded (D7) |

One warning per registration, not per request: the failure it catches is a
handler that is wrong for every request, and a per-request warning on a page
loading fifty assets is noise that buries its own signal.

## D7 — A handler that throws does not vanish and kills nothing

The dispatcher catches everything a handler throws. It must not kill the
dispatcher task (later requests would hang), must not be swallowed (a silently
broken mock produces a failure somewhere unrelated), and cannot be rethrown at
the throw site — there is no user task there.

So it is **recorded on the registration and rethrown on the caller's task** when
the registration is released: the end of `with_route`, or the `unroute!` call.
Several become a `CompositeException`. The route itself is continued so the page
proceeds.

This makes `with_route(...) do ... end` behave as a Julia user expects — a broken
handler surfaces out of the block that installed it.

## D8 — Registration is explicit; `with_route` is the block form

Mirrors the shape `with_tracing` / `with_events` already established.

```julia
reg = route!(target, matcher, handler)     # target :: Page or BrowserContext
unroute!(target, reg)
unroute_all!(target)

with_route(body, target, matcher, handler) # body is the do-block
```

The block form takes the *handler* as an argument and the *body* as the
do-block — the opposite of `with_events`, deliberately. There are two functions
to pass and only one can be the do-block; the body is the one with statements in
it, the handler is usually a one-liner.

```julia
with_route(ctx, "**/api/**", r -> fulfill!(r; json = mock)) do
    goto!(page, url)
    click!(locator(page, "#refresh"))
end
```

## D9 — Matchers are evaluated client-side; the driver gets the union

`setNetworkInterceptionPatterns` replaces the *whole* pattern set, so
per-handler filtering cannot live in the driver once there are two handlers. The
registry therefore sends the union of every live registration's glob, re-sending
on each register and unregister; sends the catch-all `**/*` whenever any
registration uses a `Regex` or a predicate, since neither is expressible as a
driver glob; and matches each handler client-side against the request URL.

| Matcher type | Meaning |
|---|---|
| `AbstractString` | a glob in Playwright's dialect (`*`, `**`, `?`, `{a,b}`) |
| `Regex` | `occursin` against the full URL |
| `Function` | `url -> Bool`, called with the full URL string |

Glob→regex conversion is ours to write (`src/api/globs.jl`) and is the most
test-worthy pure function in the milestone — hermetic, no driver, no browser.
It follows Playwright's `globToRegex`: `*` does not cross `/`, `**` does, `?` is
one non-`/` character, `{a,b}` alternates, everything else is escaped. A glob
with no scheme resolves against the context's `base_url` when one is set, as
Playwright does.

## D10 — `Request` and `Response` read from initializers

Both carry nearly everything in their `initializer`
(`protocol/spec/network.yml:54` and `:210`), already in memory when the event
arrives. Accessors read it directly; only `body(response)`,
`response(request)` and the raw-header variants need the wire.

**Headers.** The wire is a `NameValue` array. Three functions, because there are
genuinely three questions:

| Call | Answers |
|---|---|
| `headers(req_or_resp)` | `Dict{String,String}`, keys lower-cased, duplicates joined by `", "` — the common case |
| `headers_array(req_or_resp)` | `Vector{Pair{String,String}}` in wire order, duplicates preserved |
| `raw_headers(req_or_resp)` | as sent/received on the wire, via `rawRequestHeaders` / `rawResponseHeaders` — one round trip |

`raw_headers` ships (reversing M5's open question 5) because it is the only way
to see what the browser actually sent versus what it was asked to send, which is
exactly the question a routing test asks. Its docstring says it costs a round
trip and that the other two do not.

`lifecycle.jl:98`'s `name_value_array` already goes the other way and gains its
counterparts beside it.

**Bodies.** `post_data(request)` returns `Union{Nothing,Vector{UInt8}}` — the
bytes, because that is what they are. `post_data_string` decodes UTF-8 and
`json(request)` parses. Three names, three return types, per gap 3's lesson:
one function, one return type.

## D11 — Network events live on the context; the `Page` forms filter

`page.yml` has no `request`/`response` events — only `browserContext.yml:46–68`
does, and each carries an optional `page` field. So:

- `expect_event(ctx, :request)` subscribes to the context event directly;
- `expect_event(page, :request)` subscribes to **the page's context**, with a
  built-in predicate dropping payloads whose `page` is not this page.

This is the first event whose subscription owner differs from the owner the user
named, and `subscribe_spec` grows a hook for it. Stated out loud because it is
invisible at the call site and will otherwise confuse the next reader of
`events.jl`.

All four are opt-in (`EventSpec.opt_in = true`); the existing ref-counted
enable/disable already handles overlapping blocks.

| Event | Payload |
|---|---|
| `:request` | `Request` |
| `:response` | `Response` |
| `:requestfinished` | `Request` |
| `:requestfailed` | `RequestFailure` — a struct of `request` and `failure_text` |

`:requestfailed` is the odd one: its failure text lives in the event params and
nowhere else, so a bare `Request` would silently lose the only interesting thing
about it.

`expect_request` / `expect_response` are sugar over `expect_event` with a
matcher-derived predicate (same matcher union as D9). They exist because the
predicate spelling is the part users get wrong, and because these two are most
of real network-event use.

## D12 — `APIRequestContext`, exactly as far as fulfil-from-upstream needs

Reversing the first draft's non-goal. The cost was mis-estimated: this is not "a
whole HTTP client", it is three commands and a struct, because
`BrowserContext`'s initializer *already carries* `requestContext:
APIRequestContext` (`browserContext.yml:20`). Every context has one, free, with
no launch-time plumbing.

What ships:

- `APIResponse` — a plain immutable struct, **not** a `ChannelOwner`: the
  protocol models it as an object with a `fetchUid` (`api.yml:88`), not as a
  channel. Fields: `url`, `status`, `status_text`, `headers`, `fetch_uid`.
- `Playwright.fetch(target, url; method, headers, data/json/form, timeout, …) -> APIResponse`
  where `target` is a `BrowserContext` (uses its request context) or a `Route`.
  `Playwright.fetch(route)` with no URL is Playwright's `route.fetch()`: perform
  *this* request upstream, unmodified, and hand back the response.
  **Unexported and called qualified** — see D14.
- `body(::APIResponse)` / `text` / `json` via `fetchResponseBody`.
- `fulfill!(route; response = api_response, …)` passes `fetchResponseUid`
  (`network.yml:126`), with `status`, `headers` and `body` overriding fields of
  it. This is the whole point of the sub-feature: intercept, forward, modify.

What does not ship: `storageState`, multipart/`FormField` uploads,
`APIRequestContext` as a standalone user-facing entry point (`playwright.request`
in Playwright), and `fetchLog`. The line is drawn at *routing needs it*; a
general HTTP client for Julia is not this package's job when `HTTP.jl` exists.

**Lifetime.** An `APIResponse` holds a `fetch_uid` the driver keeps buffered
until `disposeAPIResponse`. Unfetched bodies are a leak. `fetch` inside a
`with_route` handler disposes at handler exit; the standalone form disposes on
finalization and offers `dispose!(::APIResponse)` for the explicit case. This is
the one lifetime in Part B not already handled by the subscription machinery,
and it gets its own test.

## D13 — `continue!`, because Part A's bang dissolves the keyword clash

`continue` is a Julia keyword, which is why `playwright-python` reaches for
`continue_` — Python has the same clash and no better escape. Julia does have a
better escape, and Part A already requires it: **`continue!` is a distinct
identifier, not the keyword.** Julia's lexer reads an identifier greedily, so
`continue!` never becomes `continue` followed by `!`.

Verified rather than assumed, because the whole decision rests on it —
definition, call, keyword arguments, and use inside a lambda in a do-block all
parse and run:

```julia
julia> continue!(x) = x + 1;  continue!(41)
42

julia> Meta.parse("continue!(route; headers = h)")
:(continue!(route; headers = h))
```

This is the happiest possible outcome: settling a route keeps Playwright's own
vocabulary (`abort!` / `continue!` / `fulfill!`, the three settle verbs a reader
already knows) *and* reads as Julia, with no borrowed Python workaround and no
invented synonym. The earlier draft's `resume!` was solving a problem that Part
A had already solved.

The docstring names `continue_` explicitly, so someone arriving from
`playwright-python` searching for it lands in the right place.

## D14 — `fetch` is unexported and called `Playwright.fetch`

It keeps Playwright's name, and it does **not** extend `Base.fetch`, and it is
**not** exported. Users write `Playwright.fetch(route)`.

Three consequences, stated because two of them are costs:

- **No ambiguity to worry about.** `Base.fetch` (on `Task`) and
  `Distributed.fetch` both exist; not exporting means `using Playwright`
  alongside either is quiet, and not extending `Base.fetch` means this package's
  `fetch` and theirs are unrelated functions that never need reconciling.
- **It is invisible to `names(Playwright)`**, so `checkdocs = :exports` cannot
  see its docstring — the same shape as gap 1 in `tasks/m5-api-gaps.md`, arrived
  at deliberately this time rather than by accident. Mitigated, not ignored: the
  `api.md` entry is written as an explicit `Playwright.fetch` `@docs` block, and
  `test_exports.jl` asserts that `Playwright.fetch` has a docstring, so the gate
  the export list would have given is replaced by a test rather than dropped.
- **The qualification is a feature at the call site.** `Playwright.fetch(r)`
  inside a route handler says which network this is going over, next to a
  `fulfill!` that does not go over any network at all.

This is the one place M6 knowingly accepts gap 1's pattern. It is the right
trade because the alternative — inventing `api_fetch` — costs the Playwright
name, which is the thing a user arriving from Playwright's docs searches for.

## D15 — `fulfill!` takes the conveniences; `abort!` validates its code

```julia
fulfill!(route;
         status = 200,
         headers = Dict(...),   # merged over the content-type default
         body = nothing,        # String → as-is, Vector{UInt8} → base64
         json = nothing,        # JSON.json(x), content-type application/json
         content_type = nothing,
         path = nothing,        # read the file, infer content-type by extension
         response = nothing)    # an APIResponse (D12); the others override it
```

`body`, `json`, `path` and `response` are mutually exclusive as *body sources*
— passing two is an `ArgumentError` at the call site, not a driver error later
— except that `status`, `headers` and `content_type` may accompany `response`,
which is what makes "the real response with one thing changed" work.

`abort!`'s `error_code` is validated against Playwright's known set
client-side, for the same reason: a typo'd `"failled"` should not become
mysterious browser-side behaviour.

---

## Tech Stack

Unchanged from M5. Pieces this milestone leans on:

- `src/generated/channels.jl` — `Request`, `Response`, `Route`,
  `APIRequestContext` channel types and their commands (Assumption 5 lists
  them).
- `src/api/events.jl` — the `Subscription` / `EventSpec` / `deliver_event`
  machinery Part B extends rather than replaces.
- `JSON.jl` for `json =` and `json(...)`; `Base64` for binary bodies and
  `post_data`.

## Commands

Unchanged from M5; repeated so the spec stands alone.

```console
$ julia --project=. -e 'using Pkg; Pkg.test()'                        # hermetic
$ PLAYWRIGHT_JL_SMOKE=1 julia --project=. -e 'using Pkg; Pkg.test()'  # + browsers
$ julia --project=gen -e 'using JuliaFormatter; format(["src","test"])'
$ julia --project=gen gen/generate.jl --check                         # codegen in sync
$ julia --project=docs docs/make.jl                                   # docs, no browser
$ julia --project=examples examples/runexamples.jl                    # both engines
```

Never format from `@pw-probe` — `gen/Project.toml` pins JuliaFormatter
`=1.0.62`, and 2.x silently reformats unrelated files.

## Project Structure

New and changed files only.

```
Part A
  src/**, test/**, docs/**, examples/**, README.md
                          → CHANGED, mechanically: twelve renames (D1)

Part B
  src/api/network.jl      → NEW. Request/Response accessors, the four events
  src/api/routing.jl      → NEW. Route, registry, dispatcher task, with_route
  src/api/apirequest.jl   → NEW. APIResponse, fetch, fulfil-from-response (D12)
  src/api/globs.jl        → NEW. glob → Regex, and the matcher union
  src/api/events.jl       → CHANGED. four events leave DEFERRED_EVENTS;
                            page-scoped filtering of context-level events (D11)
  src/Playwright.jl       → CHANGED. includes + exports
  test/test_globs.jl      → NEW, hermetic
  test/test_network.jl    → NEW, hermetic
  test/test_smoke_network.jl → NEW, smoke, both engines
  test/fixtures/m6.html   → NEW. fetch/XHR against relative URLs, an image
  docs/src/guide/network.md  → NEW guide page
  docs/src/guide/events.md   → CHANGED. the supported-events table grows
  docs/src/api.md            → CHANGED
  examples/oxygen_jl.jl      → CHANGED. gains a mocked-backend section (D16)
  README.md                  → CHANGED. Status section
  docs/bonnie-parity.md      → CHANGED. network rows re-scored
```

Part B splits across four files from the start rather than growing one
`network.jl` past 700 lines — the seams (protocol objects / routing machinery /
API requests / pure glob code) are obvious enough that pre-committing to them
costs nothing.

## D16 — The mocked backend goes in the existing Oxygen example

`examples/oxygen_jl.jl` already drives a page against a JSON API and is one
`with_route` away from demonstrating the feature. It gains a second section
rather than the repo gaining a fifth script: CI time is unchanged, and the
example gets *better* by showing the same page tested twice — once against the
real route, once against a mock — which is the actual argument for the feature.
The example's docs page gains the same section, via the existing literate
include (M5 SC 9 proved that pipeline).

## Code Style

Unchanged. The house style, from `src/api/events.jl`:

```julia
"""
    unroute!(target, reg::RouteRegistration)

Remove `reg` from `target`'s routing table.

Rethrows anything the handler threw while it was installed (D7) — one exception
directly, several as a `CompositeException`. In-flight routes are still settled
before this returns, so a request the browser is already blocked on cannot be
orphaned by an unroute.

Idempotent: unrouting twice is a no-op the second time.
"""
function unroute!(target::RouteTarget, reg::RouteRegistration)
    # Deliberately drops the registration before draining, not after: a route
    # arriving between the two must find no handler and be continued (D6), rather
    # than find a handler whose exceptions nobody will ever collect.
    ...
end
```

Docstrings carry the signature, a worked example, and — where a decision
surprises — its reason, referenced to the `D` number in this spec. Comments
explain *why*; the ones worth writing here are about ordering and lifetime.
`snake_case`, four spaces, formatter-clean at the pinned version.

## Testing Strategy

Three tiers, as M2–M5 established. The split matters more here than usual: most
of what can go wrong is a pure function or a lifetime bug, and neither needs a
browser.

**Hermetic** (`Pkg.test()`, no Node, no browser) — must stay the majority:

- `test_globs.jl` — the glob dialect, table-driven: `*` vs `**` at a `/`, brace
  alternation, regex metacharacters inside literal segments, base-URL
  resolution. This file earns its keep at review time.
- `test_network.jl` — header normalisation (case folding, duplicate joining,
  wire order preserved by `headers_array`), `fulfill!` parameter building
  including every mutual-exclusion `ArgumentError`, `abort!` code validation,
  matcher dispatch across all three types, and the registry's driver-pattern
  union (does adding a `Regex` registration switch the driver to `**/*`?) — all
  against a fake connection, as `test_events.jl` already does.
- `test_exports.jl` / `test_parity.jl` — grow the new names, and Part A's
  old-name grep (SC A4) lives here.

**Smoke** (`PLAYWRIGHT_JL_SMOKE=1`, both engines, in-process HTTP.jl fixture
server per `test/test_smoke.jl:7`):

- fulfil a mocked JSON API; assert the DOM rendered from the mock;
- abort image requests; assert the page still loads;
- `continue!` with modified headers, asserted by a fixture route that echoes what
  it received;
- fulfil from a real upstream response with `status` overridden (D12), and
  assert the `APIResponse` was disposed;
- two overlapping registrations: newest-first, and unrouting the inner restores
  the outer;
- a handler that throws — the exception surfaces out of `with_route` *and* the
  page still finished loading (D7);
- a handler that settles nothing — the warning fires once and the page loads
  (D6);
- `expect_request` / `expect_response` round trips, and `:requestfailed` against
  a deliberately unreachable URL;
- page-scoped vs context-scoped events with two pages open (D11);
- `raw_headers` differing from `headers` on a request the browser augmented.

**Docs** — guide examples are doctested where they run without a browser (glob
matching, header dicts); the rest are plain `julia` blocks, as existing guide
pages do.

The bar: every exported name has a docstring (`checkdocs = :exports` is already
a gate), and **every `D` decision has at least one test that would fail if the
decision were reversed.**

## Boundaries

**Always**

- Hermetic suite before every commit; smoke before every push.
- Part A's renames land one name per commit, green between each (D4).
- `gen/generate.jl --check` and `format` clean. The generated layer is not
  edited by hand and M6 has no reason to touch it.
- Every new exported name gets a docstring and an `api.md` entry in the commit
  that introduces it.
- Settle every route on every path (D6). A test that can hang is not a test.

**Ask first**

- Adding any package dependency. The design says none is needed.
- Re-vendoring the protocol or regenerating `src/generated/`.
- Any rename beyond D1's twelve, or any signature change during Part A
  (Assumption 3).
- Fixing anything in `tasks/m5-api-gaps.md` beyond D3's incidental resolution.
- Widening `APIRequestContext` past D12's line, or adding WebSockets / HAR /
  service workers.

**Never**

- Leave a request intercepted with no path to being settled.
- Call user code from the transport reader task (`events.jl:9`; the world-age
  trap).
- Weaken a docs or CI gate to make something green.
- Format from the `@pw-probe` environment.

## Success Criteria

Each is a thing to run, not a thing to believe. Both engines wherever a browser
is involved, recorded in a table in `tasks/m6/todo.md` in the M5 style.

**Part A**

- **A1** — All twelve renames applied; `names(Playwright)` contains every new
  name and none of the old.
- **A2** — Hermetic and smoke suites green after *each* rename commit, not only
  the last (D4).
- **A3** — `close!`, `set_value!` and `delete_file!` appear in `names(Playwright)` and are covered by
  `checkdocs = :exports`, which they were not before (D3).
- **A4** — A grep for each old spelling as a call across `src`, `test`, `docs`,
  `examples` and `README.md` returns nothing. Implemented as a test.
- **A5** — Part A's diff contains no signature change and no behaviour change:
  reviewed commit by commit against Assumption 3.
- **A6** — `using Playwright` shadows nothing in `Base`: a test does
  `using Playwright` and then calls `fill!`, `delete!`, `close`, `count` and
  `first` on ordinary Julia data, asserting each still resolves to `Base`. This
  is the regression test for D3's trap, and it would have caught the first
  draft of this spec.

**Part B**

1. `with_route(ctx, "**/api/todos", r -> fulfill!(r; json = …))` renders mocked
   data with no server serving `/api/todos` at all.
2. `route!` on a `Page` intercepts only that page's requests; on a
   `BrowserContext`, every page's.
3. Unmatched requests are continued and the page loads normally with a
   registration installed — proved by `m6.html`, whose image and CSS match
   nothing.
4. A throwing handler surfaces its exception out of `with_route`, and the page
   under it still completed navigation (D7).
5. A handler that settles nothing warns exactly once per registration and does
   not hang (D6).
6. Two overlapping registrations resolve newest-first; unrouting the newer makes
   the older take over, in the same test.
7. `abort!` prevents the request: a counting fixture route records zero hits and
   the page's error handler fires.
8. `continue!(route; headers = …)` reaches the server modified, proved by an echo
   route.
9. `expect_request(ctx, "**/api/todos") do click!(...) end` returns a `Request`
   whose `method`, `url`, `headers` and `post_data` are correct.
10. `expect_response` returns a `Response` whose `status`, `ok`, `headers`,
    `body` and `json` are correct, including a non-200.
11. `:requestfailed` fires for an unreachable URL with non-empty
    `failure_text`.
12. Page-scoped network events see only their own page's traffic, with two pages
    open in one context (D11).
13. The four network events are gone from `DEFERRED_EVENTS`;
    `expect_event(ctx, :request)` no longer raises.
14. `Playwright.fetch(route)` returns the genuine upstream response, and
    `fulfill!(r; response = it, status = 500)` reaches the page as a 500 with
    the upstream body (D12).
15. An `APIResponse` is disposed after its handler returns; a leaked one is
    disposed on finalization — asserted, not assumed.
16. `raw_headers` differs from `headers` on a request the browser augmented,
    demonstrating the round trip is real (D10).
17. `test_globs.jl` passes hermetically, covering every row of the guide's glob
    table — guide and test read the same list, or neither is trusted.
18. Hermetic `Pkg.test()` green with no Node and no browser present; smoke green
    on both engines.
19. `docs/make.jl` builds warning-free with `checkdocs = :exports` and
    `warnonly = false` still on, `doctest = true` passing.
20. `gen/generate.jl --check` in sync, `format(".")` returns `true`, and the
    `[deps]` section of `Project.toml` is byte-identical to `main`.
21. `examples/oxygen_jl.jl` passes on both engines with its new mocked-backend
    section, and that section appears in the built docs page (D16).
22. README's Status section no longer lists network interception under
    not-covered; `docs/bonnie-parity.md` has its network rows re-scored.

## Resolved during review

The first draft's three open questions were answered before Phase 2, and two
further decisions were forced by things found while checking it. All five are
recorded here rather than folded silently into the decisions above — a spec that
hides where it changed its mind is a worse record than one that shows it, and
items 4 and 5 in particular are the two places this spec was wrong.

1. **Does Part A ship as its own tag?** No. One milestone, no intermediate tag —
   nothing is registered, so nobody is tracking `main` closely enough for the
   tag to serve anyone. But Part A lands **completely** — green on both suites,
   formatted, docs rebuilt — before the first line of Part B, which is what
   Boundaries and SC A2 enforce.

2. **How is `fetch` spelled?** `Playwright.fetch`, unexported, not extending
   `Base.fetch` — D14, which also records what that costs and how the docs gate
   is replaced by a test.

3. **Does `screenshot` keep no bang?** Yes — D2 stands as written. `screenshot`
   and `pdf` write to your disk and change nothing the page can observe, and a
   `screenshot(page)` with no `path` writes nothing at all, so a bang would be
   a name that changes meaning with a keyword argument.

4. **`fill!` and `delete!` are unusable as exports.** Found while checking the
   rename table rather than while implementing it: `Base.fill!` and
   `Base.delete!` are exported by default, so exporting our own would break
   `fill!` on arrays and `delete!` on dictionaries for every user of the
   package. `set_value!` and `delete_file!` instead — D3 has the evidence and
   SC A6 is the regression test.

5. **`continue!` versus `resume!`.** The first draft chose `resume!` on the
   grounds that `continue` is a keyword. It is — but `continue!` is a different
   identifier, verified in D13. Playwright's own verb survives intact, and the
   invented synonym is gone.

## Open Questions

None outstanding. Phase 2 (Plan) is unblocked.

The first thing Phase 2 has to decide, which is a planning question rather than
a design one: whether Part B's four new files land in dependency order
(`globs.jl` → `network.jl` → `routing.jl` → `apirequest.jl`, each with its tests
green before the next starts) or whether `globs.jl` and `network.jl` land
together because neither is demonstrable alone. That belongs in `tasks/plan.md`,
not here.
