# Spec: Playwright.jl — Milestone 8 (the archive, the profile, and the socket)

Successor to [`SPEC.md`](SPEC.md) (M1), [`SPEC-M2.md`](SPEC-M2.md),
[`SPEC-M3.md`](SPEC-M3.md), [`SPEC-M4.md`](SPEC-M4.md),
[`SPEC-M5.md`](SPEC-M5.md), [`SPEC-M6.md`](SPEC-M6.md) and
[`SPEC-M7.md`](SPEC-M7.md), all seven complete. Tech stack, driver
architecture, the codegen/API split, code style, testing layout and boundaries
carry over unchanged unless contradicted here.

M8 clears four of the seven entries on the README's not-covered list, in four
parts:

- **Part A — replay.** `route_from_har`: serve a page's whole network from a
  recorded HAR archive, with no backend running at all.
- **Part B — recording.** `start_har_recording!` / `stop_har_recording!`, and
  the `update = true` leg of Part A that re-records an archive from the live
  network.
- **Part C — the profile.** `launch_persistent_context`: a browser whose
  cookies, `localStorage` and profile survive the process.
- **Part D — the socket.** `route_web_socket!`: intercept a WebSocket, mock it
  entirely or proxy it and rewrite messages in flight.

**This is the largest milestone so far, and the spec says so up front rather
than discovering it at T14.** M6 was network interception alone and ran to
eighteen tasks; M7 was three subjects and ran to twenty-one. M8 is four
subjects, one of which (Part D) shares almost no machinery with anything that
exists. The scope was set deliberately with that understood — see Assumption 10
for what happens if a checkpoint slips, which is *not* silently dropping Part
D.

**Ordering: B's machinery before A's `update` leg; A before D; C is
independent.** Part A's replay path and Part B's recording path meet in exactly
one place — `route_from_har(…; update = true)` **is** a recording, scoped to a
URL pattern and written on context close. That leg therefore lands in Part B,
after `harStart`/`harExport` are wrapped, not in Part A where its name suggests
it lives (D7). Part D copies the registry + dispatcher-task pattern from
`routing.jl` for the third time, and wants Part A's second use of it settled
first so the third is a known quantity rather than an invention.

## Assumptions

Calls this spec makes without being told. Correct any that are wrong.

1. **New spec, not a rewrite.** `SPEC-M8.md` joins its seven predecessors; none
   of them are edited.
2. **Breaking changes are allowed** and follow M6/M7's rule: no deprecation
   shims, old spellings simply stop existing. M8 expects to break very little —
   it is almost entirely additive — with the exception D9 names.
3. **Playwright stays pinned at 1.61.1**, Node at 24.17.0. Every command
   Part A–D needs is already emitted from the *already vendored*
   `protocol/spec/*.yml`; `gen/fetch_spec.jl` does not run and the driver
   version does not move. Verified below.
4. **No generator change and no regeneration.** Unlike M7, this milestone adds
   nothing to `src/generated/channels.jl`. `gen/generate.jl --check` must be
   green at every commit *without* anyone having run `gen/generate.jl`. If a
   task appears to need a regeneration, that is a signal something is wrong
   with the task, not with the pin.
5. **Every command M8 needs already exists in the generated layer.** Verified
   against `protocol/spec/` and `src/generated/channels.jl`:
   - `LocalUtils.harOpen(file) → {harId?, error?}` (`localUtils.yml:69`),
     `harLookup(harId, url, method, headers, postData?, isNavigationRequest)
     → {action ∈ error|redirect|fulfill|noentry, message?, redirectURL?,
     status?, headers?, body?}` (`:77`), `harClose(harId)` (`:104`),
     `harUnzip(zipFile, harFile, resourcesDir?)` (`:109`) — emitted as
     `_local_utils_har_open` (`channels.jl:3411`), `_local_utils_har_lookup`
     (`:3381`), `_local_utils_har_close` (`:3373`), `_local_utils_har_unzip`
     (`:3419`).
   - `Tracing.harStart(page?, options: RecordHarOptions) → {harId}`
     (`tracing.yml:75`) and `Tracing.harExport(harId?, mode ∈ archive|entries)
     → {artifact?, …}` (`:83`) — emitted as `_tracing_har_start`
     (`channels.jl:4421`) and `_tracing_har_export` (`:4405`).
   - `RecordHarOptions` = `content ∈ embed|attach|omit`, `mode ∈ full|minimal`,
     `urlGlob?`, `urlRegexSource?`, `urlRegexFlags?`, `harPath?`,
     `resourcesDir?` (`playwright.yml:362`).
   - `BrowserType.launchPersistentContext(LaunchOptions, ContextOptions,
     userDataDir, slowMo?) → {browser, context}` (`browserType.yml:32`).
   - `WebSocketRoute` interface with initializer `{url, protocols}`, commands
     `connect`, `sendToPage`, `sendToServer`, `closePage`, `closeServer`,
     `ensureOpened`, and events `messageFromPage`, `messageFromServer`,
     `closePage`, `closeServer` (`network.yml:128`).
   - The `webSocketRoute` event on both `Page` (`page.yml:724`) and
     `BrowserContext` (`browserContext.yml:387`).
6. **`Playwright.utils` is optional in the protocol and must be treated as
   optional.** `playwright.yml:36` declares `utils: LocalUtils?`. Nothing in
   `src/` references it today — `PlaywrightAPI` (`src/objects.jl:172`) carries
   only `chromium`, `firefox`, `process` and `connection`. D1 plumbs it
   through *with* the absent case handled, not with a `nothing` that surfaces
   three frames later as a `MethodError`.
7. **Sync-only, Julia floor 1.10.** Load-bearing in Part D: a WebSocket route
   is a long-lived bidirectional conversation with no request/response shape to
   hang a blocking call on, which is why D11 hands it a callback API rather
   than something that reads like `fulfill!`.
8. **Chromium and Firefox both, or it does not ship.** WebSocket routing and
   persistent contexts are both surfaces where the engines plausibly differ.
   Per M6 SC 16's precedent, an assertion that turns out to be engine-specific
   is weakened to what holds on both and the difference is recorded — it is not
   quietly deleted or quietly skipped on one engine.
9. **Linux-only remains the claim.** No CI matrix change. Part C has an
   obvious Windows/macOS profile-path dimension; it is out of scope with the
   rest of the platform question.
10. **No part is cuttable without being asked.** The maintainer chose all four
    at equal weight over an explicitly-cuttable Part D. So if Checkpoint C or D
    slips, the response is to **ask**, not to trim the part down to a wrapper
    with no smoke coverage. A half-shipped Part D that cannot be exercised on a
    real socket is worse than an honest "D moves to M9", because the first one
    goes on the README as done.
11. **No new package dependency.** Part A needs zip handling, and it does
    **not** need a zip library: `LocalUtils.harUnzip` is the driver doing it
    (D3). Part D needs base64 for binary frames, and `Base64` is already a
    dependency. If any task appears to need a new dependency, that is an
    ask-first (see Boundaries).
12. **WebKit, service workers, `connect_over_cdp`, Android, Electron, a trace
    *viewer* and the async API all stay out**, exactly as M7 left them. After
    M8 the not-covered list is WebKit, service workers, trace parsing and
    async.

## Objective

### Part A — replay

M6 made it possible to test a frontend with no backend by hand-writing the
mock:

```julia
with_route(ctx, "**/api/**", route -> fulfill!(route; json = mock)) do
    goto!(page, url)
end
```

That works and stays. What it cannot do is *scale to a real application*, where
"the backend" is forty endpoints, some of them binary, none of them
interesting to hand-write. A HAR archive is the recording of a real session;
replaying it turns the whole network into a fixture.

```julia
# No server running. Every request the page makes is served from the archive.
route_from_har(ctx, "test/fixtures/api.har"; url = "**/api/**")
goto!(page, "https://app.example.com")
expect(locator(page, "#total"); to_have_text = "42")
```

The interesting half is what happens to a request the archive does not have,
because that is the difference between a fixture and a lie — see D4.

### Part B — recording

The other direction, and where the archive in Part A came from:

```julia
with_har_recording(ctx; path = "api.har", url = "**/api/**") do
    goto!(page, "https://app.example.com")
    click!(locator(page, "#refresh"))
end
```

and the leg that closes the loop, refreshing an existing archive against a
backend that has moved on:

```julia
route_from_har(ctx, "test/fixtures/api.har"; url = "**/api/**", update = true)
```

### Part C — the profile

Every context this package can make today is a fresh incognito profile. That
is the right default and the wrong only option: a test suite for anything with
a login has to either replay the login on every test or reach for
`storage_state`, and neither is what a user's actual browser does.

```julia
ctx = launch_persistent_context(pw.chromium, "/tmp/profile"; headless = true)
page = new_page(ctx)
goto!(page, url)
click!(locator(page, "#accept-cookies"))
close!(ctx)

# Same directory, new process. The cookie is still there.
ctx = launch_persistent_context(pw.chromium, "/tmp/profile"; headless = true)
```

The success criterion is the second launch, not the first (SC 17). Wrapping
the call and asserting a usable context proves nothing about persistence.

### Part D — the socket

The one remaining network surface the package cannot observe at all. A page
that talks over a WebSocket is, to Playwright.jl today, a page that does
something invisible.

```julia
# Mock: the real server is never contacted.
route_web_socket!(page, "**/ws") do wsr
    on_message_from_page!(wsr) do msg
        msg == "ping" && send_to_page!(wsr, "pong")
    end
end

# Proxy: the real server IS contacted, and one message is rewritten.
route_web_socket!(page, "**/ws") do wsr
    connect!(wsr)
    on_message_from_server!(wsr) do msg
        send_to_page!(wsr, replace(msg, "live" => "mocked"))
    end
end
```

Whether `connect!` was called is the entire mode switch, and it is the one
thing about this API that will surprise people (D10).

### What M8 is *not*

- Not a trace or HAR **parser**. `route_from_har` hands the file to the driver;
  Julia never reads a HAR's JSON. `harExport` produces an `Artifact` which
  `save_as!` writes. If a caller wants the entries in Julia, that is `JSON` on
  a file they already have, and it is not this package's job.
- Not `record_har` as a `new_context` keyword. D6 declines it, with an
  argument.
- Not WebSocket *observation* (`page.on("websocket")`). Part D is routing;
  `:websocket` keeps its `DEFERRED_EVENTS` entry, rewritten (D14).
- Not a second engine, and not the async API.

---

# Part A — replay

## D1 — `LocalUtils` is plumbed through, and its absence is an error with a name

`Playwright.utils` is `LocalUtils?` and every HAR-replay call needs it.
`PlaywrightAPI` gains a fifth field, and a single accessor owns the optional
case:

```julia
"""
    local_utils(conn::Connection) -> LocalUtils

The driver's `LocalUtils` object, which owns HAR lookup and zip extraction.

Optional in the protocol (`playwright.yml:36`) and present in every driver
build this package pins, so its absence means the driver is not the one we
think it is — which is worth saying once, here, rather than as a `MethodError`
inside a route handler three frames down (D1).
"""
function local_utils(conn::Connection)
    utils = conn.local_utils
    utils === nothing && throw(
        DriverError(
            "this driver exposes no LocalUtils, so HAR replay is unavailable; " *
            "Playwright $(PLAYWRIGHT_VERSION) is expected to provide one";
            name = "Error",
        ),
    )
    return utils
end
```

It hangs off the `Connection` rather than `PlaywrightAPI` because a `Route`
handler has a `Route`, and from a `Route` the `Connection` is one field away
while the `PlaywrightAPI` is not reachable at all.

## D2 — `route_from_har` is a `route!` handler, not a new mechanism

There is no server-side "replay this HAR" command. The whole feature is:
`harOpen` once, `harLookup` per request, `harClose` at the end — and the thing
that produces the requests is M6's `route!`. So `route_from_har` registers a
route and returns the same `RouteRegistration` that `route!` does, which means
`unroute!` already works on it and needs no new spelling.

```julia
route_from_har(target, har; url = nothing, not_found = :abort, update = false)
    -> RouteRegistration
```

- `target` — a `Page` or `BrowserContext`, exactly as `route!` takes.
- `har` — path to a `.har` or a `.har.zip` (D3).
- `url` — a glob, `Regex` or predicate restricting *which* requests are served
  from the archive. `nothing` means all of them. This is `route!`'s `matcher`
  under a keyword name, because at this call site "which URLs" reads better as
  a keyword than as a positional argument whose meaning you have to recall.
- `not_found` — `:abort` or `:fallback` (D4).
- `update` — delivered in Part B (D7).

A block form `with_har(body, target, har; …)` mirrors `with_route`, and exists
for the same reason: the registration must go away even when the body throws.

The four `harLookup` actions map onto M6's three settle verbs:

| `action` | Response |
|---|---|
| `fulfill` | `fulfill!(route; status, headers, body)` — the archived response |
| `redirect` | `continue!(route; url = redirectURL)` — navigations only (D5) |
| `error` | `DriverError` carrying `message`. The archive is broken, not the request |
| `noentry` | `not_found` decides (D4) |

## D3 — A zipped archive is unzipped by the driver, not by Julia

`harOpen` wants a `.har`. Playwright's own tooling writes `.har.zip` whenever
`content = :attach`, because the response bodies live beside the JSON as
separate files. `LocalUtils.harUnzip(zipFile, harFile, resourcesDir)` is the
driver's own extraction, so a `.zip` path is unzipped into a temp directory
first and `harOpen` is pointed at the result.

This is why Assumption 11 can promise no new dependency: the alternative is a
zip library in `Project.toml` to reimplement a call the driver already exposes.

The temp directory is cleaned when the registration is released — which makes
`unroute!` the owner of the lifetime, and is another reason D2 reuses
`RouteRegistration` rather than inventing a handle.

## D4 — `not_found` defaults to `:abort`, and that is the load-bearing choice

A request the archive has no entry for is the case that decides whether this
feature is trustworthy.

- `:abort` — the request fails. The page sees a network error.
- `:fallback` — `continue!(route)`, so the request goes to the real network.

**`:abort` is the default**, matching Playwright's own default and for the same
reason: `:fallback` makes a HAR test that is *silently incomplete* pass. A
missing entry falls through to a real server, and the test goes green on a
machine where that server happens to be reachable — then goes red in CI, or
worse, stays green in CI against a staging box and tests nothing that the
archive claims to cover. `:abort` makes the gap visible the first time.

`:fallback` is offered anyway, because "archive the API, let the CDN through"
is a real configuration and the alternative is that people stop using the
feature.

## D5 — `redirect` is one branch, because the driver does the rest

**Rewritten after the probe.** The first draft of this decision had the handler
re-issue the lookup at `redirectURL` and follow the chain itself, bounded at 20
hops against a cycle. [`tasks/m8-probe.md`](tasks/m8-probe.md) OQ1 shows that
is wrong in both halves:

- For a **sub-resource**, the driver resolves the redirect chain internally and
  returns `fulfill` with the *final* response already attached. Looking up
  `/a`, which the archive records as a 302 to `/b`, returns `status = 200` and
  `/b`'s body. The client never sees a `redirect` action, so there is nothing
  to follow.
- For a **navigation** (`isNavigationRequest = true`), the same lookup returns
  `redirect` with `redirectURL`. What that asks for is that the navigation be
  pointed at the new URL and re-requested by the browser — one
  `continue!(route; url = redirectURL)`, not a loop.
- **Cycles are the driver's problem and it already solves them.** A `/loop1` ↔
  `/loop2` archive returns `action = "error"` with
  `"HAR error: Found redirect cycle for http://probe.test/loop1"`. A
  client-side hop counter would sit behind a working guard and could only fire
  on input that guard has already rejected.

So D5 is: `redirect` → `continue!` at `redirectURL`. No counter, no re-lookup,
no cycle handling of our own. SC 4 changes accordingly — the criterion is that
a cyclic archive surfaces *the driver's* error message, which is a better
assertion than one about our own bound.

## D5a — `harOpen` succeeds on a file that is not a HAR, so the abort message says which archive

Also from OQ1, and not anticipated: `harOpen` on `{"this": "is not a har"}`
returns a `harId` with no error. A truncated or typo'd archive is therefore
indistinguishable, at open time, from a valid one — and every lookup against it
returns `noentry`, which under D4's `:abort` default is a page whose every
request fails with no clue why.

This does not change D4. It changes the **error text**: an aborted `noentry`
names the archive it consulted and the URL it did not find, so that "your HAR
is not a HAR" and "your HAR lacks this entry" are at least distinguishable from
the failure. Cheap, and it is the difference between a five-minute and a
fifty-minute diagnosis.

Separately: `harOpen` on a *missing* file **raises** `DriverError: ENOENT`
rather than returning the declared `error: string?` field. Code that checks
only the returned field will never see the common failure, so D2's
implementation checks both.

---

# Part B — recording

## D6 — Recording is a `start!`/`stop!` pair, not a `new_context` keyword

There is **no `recordHar` in `ContextOptions`** and none in `Browser.newContext`
— checked against `mixins.yml:98` and `browser.yml:62`. Other bindings offer
`record_har_path` on their context constructor as client-side sugar that calls
`harStart` after the context exists.

M8 declines the sugar. The API is:

```julia
start_har_recording!(ctx; path, content = :embed, mode = :full, url = nothing)
    -> HarRecording
stop_har_recording!(rec::HarRecording) -> String   # the path written
with_har_recording(body, ctx; path, …)             # the block form
```

Three reasons, in order of weight:

1. **`start_tracing!`/`stop_tracing!` already made this decision** in M4, for
   the identical protocol shape — a `Tracing` command pair producing an
   `Artifact`. A second feature on the same object with the opposite spelling
   would be the package disagreeing with itself.
2. **The keyword form hides where the file is written.** `new_context(…;
   record_har_path = p)` writes `p` at *context close*, which is somewhere else
   entirely in the source. `stop_har_recording!` returns the path it wrote.
3. `new_context` already carries sixteen keywords (`lifecycle.jl:252`) and
   `RecordHarOptions` has five more.

`HarRecording` is a small struct holding the `harId`, the context and the
destination — enough that `stop_har_recording!` needs no arguments beyond it,
and enough that a recording cannot be stopped against the wrong context.

`content` and `mode` are Julia `Symbol`s (`:embed`/`:attach`/`:omit`,
`:full`/`:minimal`) validated at the call site into the wire's string enums, so
a typo is an `ArgumentError` naming the valid set rather than a driver error.

## D7 — `update = true` is a recording, and therefore lands in Part B

`route_from_har(…; update = true)` does not replay. It *records*, into the
same file, replacing it. The name says "route" and the behaviour is "trace",
which is confusing enough to be worth stating twice.

Its implementation is D6's machinery: `harStart` scoped to the same `url`
pattern, and an export written when the owner closes. It therefore lands in
Part B despite living behind Part A's function name, and Part A's task for
`route_from_har` **rejects `update = true` with a clear "not yet" error** until
Part B lands it — rather than accepting the keyword and ignoring it, which is
how a flag ends up silently doing nothing for a release.

Two consequences stated rather than discovered:

- `update = true` needs a real backend to record from. Every other Part A test
  needs the opposite (no backend). The smoke fixture server covers both, but
  they are different tests and do not share a fixture.
- With `update = true` the returned `RouteRegistration` intercepts nothing;
  `unroute!` on it stops the recording and writes the file.

## D8 — `harExport` gives an `Artifact`, so `save_as!` is already the writer

`_tracing_har_export(mode = "archive")` returns an `Artifact?`, exactly as
`_tracing_tracing_stop_chunk` does. `stop_har_recording!` therefore reuses
`stop_tracing!`'s shape (`artifacts.jl:191`) including its `nothing` guard:
an export that produced no artifact is a `DriverError` naming the path that
was not written, not a silent no-op.

`mode = "entries"` is not wrapped. It returns the HAR entries inline for a
client that wants to merge archives; this package does not parse HAR (see
"What M8 is not").

---

# Part C — the profile

## D9 — `launch_persistent_context` returns the context and owns the browser

The wire call returns both a `Browser` and a `BrowserContext`. The function
returns the **context**, because that is what every caller then uses, and the
`Browser` is not independently useful — it has exactly one context and closing
it closes that.

That makes ownership the only real decision, and it follows M7's precedent
(`close!(page)` disposing the context `new_page(browser)` created):

**`close!(ctx)` on a persistent context closes the browser too.** Otherwise
every use leaks a browser process, and the leak is invisible because the
context — the thing the caller is holding — did close.

The context needs to know it owns a browser, which is a piece of state that
does not exist today. It goes in the same connection-side table the other
per-object state uses rather than in a new global, and `close!(::BrowserContext)`
consults it.

`user_data_dir` is **positional**, not a keyword: it is the entire reason the
function exists and there is no sensible default. Playwright allows an empty
string (meaning a temp profile); this package does not — an empty
`user_data_dir` is an `ArgumentError`, because a *persistent* context with a
profile that evaporates is a call the caller did not mean to make.

**A persistent context arrives with one page already open.** Probed on both
engines ([`tasks/m8-probe.md`](tasks/m8-probe.md) OQ3), and it is the one thing
about this function that will trip people, because every other context in this
package starts empty and teaches the `new_page` habit. `new_page(ctx)` here
opens a *second* page and leaves the first one blank and in the way.

So the docstring's worked example uses `first(pages(ctx))`, says why in one
line, and the guide does the same. This is documentation rather than a code
decision — wrapping it in a `persistent_page(ctx)` helper was considered and
declined, because it would hide a difference the caller genuinely needs to know
about the moment they call `pages(ctx)` for any other reason.

## D10 — The option explosion is shared, not copy-pasted

`launchPersistentContext` takes `LaunchOptions` **and** `ContextOptions`.
`launch` (`lifecycle.jl:173`) already spells out twelve keywords and
`new_context` (`:252`) sixteen. Writing a third function with the union of
both, by hand, guarantees the three drift.

So `lifecycle.jl` grows two internal helpers that build the wire option
`NamedTuple`s — `launch_options(…)` and `context_options(…)` — and all three
entry points call them. This is a **refactor of code that currently works**,
which normally this spec would refuse; it is in scope because the alternative
is 28 copy-pasted keyword defaults, and because the existing hermetic
`test_connection.jl` asserts the exact wire params for `launch` and so pins the
refactor's behaviour before it starts.

This is Assumption 2's exception: the helpers are internal and unexported, so
no public name changes, but `test_connection.jl` will need to grow rather than
merely pass.

---

# Part D — the socket

## D11 — `route_web_socket!` mirrors `route!`, and copies its registry

Third use of the pattern, after `routing.jl` (M6) and `dialogs.jl` (M7 D12):
a per-owner registry, a dispatcher task that runs user code off the transport
reader task, sequential dispatch, exceptions collected and rethrown at
unregistration.

```julia
route_web_socket!(handler, target, matcher) -> WebSocketRouteRegistration
with_web_socket_route(body, target, matcher, handler)
unroute_web_socket!(target[, reg])
```

The handler takes the `WebSocketRoute` and is expected to *set up* the
conversation — register callbacks, maybe `connect!` — and return. It is not a
loop and it does not block; the messages arrive afterwards, on the dispatcher.

The one thing not copied from `route!`: there is no unsettled-route warning,
because a WebSocket route has no settle. A handler that registers nothing is a
socket that mocks everything and answers nothing, which is a legitimate thing
to want (proving a page survives a dead socket).

## D12 — `connect!` is the mode switch, and the docstring leads with it

A `WebSocketRoute` is in **mock** mode until `connect!(wsr)` is called, and in
**proxy** mode after. In mock mode the real server is never contacted and
`send_to_server!` is an error. In proxy mode both directions flow, and any
callback you register *replaces* the default forwarding for that direction.

That last clause is the sharp edge: registering
`on_message_from_server!` in proxy mode and *not* calling `send_to_page!`
silently swallows every server message. It is Playwright's semantics, it will
not be changed, and it gets stated in the docstring, in the guide, and in a
test that asserts the swallowing happens (SC 24) — so that the behaviour is
pinned as intended rather than rediscovered as a bug.

The surface:

```julia
connect!(wsr)                              # proxy mode
send_to_page!(wsr, message)                # String or Vector{UInt8}
send_to_server!(wsr, message)              # proxy mode only
on_message_from_page!(f, wsr)
on_message_from_server!(f, wsr)
on_close!(f, wsr)
close_ws!(wsr; code = nothing, reason = nothing)
url(wsr)
```

`String` messages go over the wire with `isBase64 = false`; `Vector{UInt8}`
gets base64 and `isBase64 = true`, and comes back out as a `Vector{UInt8}`. The
caller never sees the flag — a binary frame sent as bytes arrives as bytes.

`close_ws!` rather than `close!`: the existing `close!` family closes
*owners* (page, context, browser), and a route is not an owner. The name is
deliberately not the pretty one.

## D13 — Per-object events are new, and `events.jl` says so

Every event in the package today belongs to a `Page` or a `BrowserContext`.
`WebSocketRoute`'s four (`messageFromPage`, `messageFromServer`, `closePage`,
`closeServer`) belong to the route object itself, which arrives mid-flight and
is disposed when the socket closes.

They are **not** added to `PAGE_EVENTS` or `CONTEXT_EVENTS` and are **not**
reachable through `expect_event`. They are consumed only by the callbacks D12
lists, exactly as `Dialog`'s subscription is owned by the dialog registry —
and for a related reason: the driver holds the socket open waiting for the
client, so an `expect_event` form would hand a caller a live socket with no
obligation to answer it.

The `Subscription`/`deliver_event` machinery in `events.jl` is keyed by owner
guid and works unchanged for a route's guid; what is new is that the owner is
short-lived, so the registry must drop its subscriptions when the route object
is disposed or the dispatcher accumulates dead entries for the process
lifetime.

## D14 — `:websocket` keeps its deferred entry, with the message corrected

`DEFERRED_EVENTS[:websocket]` currently reads *"WebSocket has no accessors yet,
so the event would yield nothing usable"* (`events.jl:365`). After Part D that
is half wrong in the way M7 spent two entries learning to catch: `WebSocket`
the *observation* type still has no accessors, but a reader who has just used
`route_web_socket!` will read "no accessors yet" as "WebSockets are
unsupported".

So the entry stays — `:websocket` genuinely is not an event you can subscribe
to — and its message is rewritten to point at the API that does exist, exactly
as `:route`'s was in M7 T18 and `:dialog`'s was in the fix that closed
`tasks/m7-api-gaps.md` gap 2:

> `WebSocket observation has no accessors yet; to intercept a socket use
> route_web_socket!`

`deferred_table_is_honest` covers this unchanged, because `:websocket` remains
absent from every owner's event table. The M7 lesson this encodes: **a deferred
entry is deleted only when the event becomes reachable, and its message is
re-read every time the surrounding capability changes.**

---

## Tech Stack

Unchanged from M7. Pieces this milestone leans on:

- `src/api/routing.jl` — `route!`, `RouteRegistration`, `fulfill!`,
  `continue!`, `abort!`, and the registry + dispatcher-task pattern Parts A
  and D both build on.
- `src/api/globs.jl` — `glob_to_regex`, so `url =` accepts the same matcher
  vocabulary as `route!`.
- `src/api/artifacts.jl` — `Artifact`, `save_as!`, and `stop_tracing!`'s
  no-artifact guard, which D8 reuses verbatim.
- `src/api/events.jl` — `Subscription`/`deliver_event`, extended to
  short-lived owners (D13), and `DEFERRED_EVENTS` (D14).
- `src/api/lifecycle.jl` — `launch`/`new_context`, refactored into shared
  option builders (D10).
- `src/objects.jl`, `src/connection.jl` — `PlaywrightAPI` and the guid
  registry, which gain `LocalUtils` (D1).
- `Base64` for binary WebSocket frames. No new dependency (Assumption 11).

## Commands

Unchanged from M5/M6/M7; repeated so the spec stands alone.

```console
$ julia --project=. -e 'using Pkg; Pkg.test()'                        # hermetic
$ PLAYWRIGHT_JL_SMOKE=1 julia --project=. -e 'using Pkg; Pkg.test()'  # + browsers
$ julia --project=gen -e 'using JuliaFormatter; format(["src","test"])'
$ julia --project=gen gen/generate.jl --check                         # codegen in sync
$ julia --project=docs docs/make.jl                                   # docs, no browser
$ julia --project=examples examples/runexamples.jl                    # both engines
```

`gen/generate.jl` itself does **not** run this milestone (Assumption 4); only
`--check` does, as a gate.

Never format from `@pw-probe` — `gen/Project.toml` pins JuliaFormatter
`=1.0.62`, and 2.x silently reformats unrelated files.

## Project Structure

New and changed files only.

```
Part A — replay
  src/objects.jl             → CHANGED. PlaywrightAPI gains utils (D1)
  src/connection.jl          → CHANGED. local_utils accessor (D1)
  src/api/har.jl             → NEW. route_from_har, with_har, the four
                               actions, zip handling, redirect guard
                               (D2, D3, D4, D5)
  src/api/routing.jl         → CHANGED. RouteRegistration carries an
                               optional release hook, for harClose and the
                               temp dir (D3)
  test/test_har.jl           → NEW, hermetic
  test/fixtures/api.har      → NEW. a hand-written archive: two endpoints,
                               one redirect chain, one binary body
  test/fixtures/api.har.zip  → NEW. the same archive, content = attach

Part B — recording
  src/api/har.jl             → CHANGED. start/stop/with_har_recording,
                               HarRecording, update = true (D6, D7, D8)
  test/test_har.jl           → CHANGED
  test/test_smoke_har.jl     → NEW, smoke, both engines. record → replay
                               round trip, and the update leg

Part C — the profile
  src/api/lifecycle.jl       → CHANGED. launch_persistent_context, and the
                               shared option builders (D9, D10)
  src/connection.jl          → CHANGED. the context-owns-browser flag (D9)
  test/test_connection.jl    → CHANGED. wire params for the third entry
                               point; the refactor's pin
  test/test_smoke_persistent.jl → NEW, smoke, both engines. close, relaunch,
                               state survived

Part D — the socket
  src/api/websockets.jl      → NEW. WebSocketRoute, the registry, the
                               callbacks, connect!/send_to_*!/close_ws!
                               (D11, D12, D13)
  src/api/events.jl          → CHANGED. short-lived owners; :websocket's
                               message rewritten (D13, D14)
  test/test_websockets.jl    → NEW, hermetic
  test/test_smoke_websockets.jl → NEW, smoke, both engines
  test/fixtures/m8.html      → NEW. a page that opens a socket, echoes and
                               displays what it receives

All parts
  src/Playwright.jl          → CHANGED. exports
  docs/src/guide/har.md      → NEW guide page
  docs/src/guide/network.md  → CHANGED. route_from_har and the socket
  docs/src/guide/events.md   → CHANGED. :websocket's row
  docs/src/api.md            → CHANGED
  README.md                  → CHANGED. Status; the not-covered list loses
                               four entries
  docs/bonnie-parity.md      → CHANGED. re-scored, or explicitly not
  tasks/m8-probe.md          → NEW, spec phase. harLookup's redirect
                               semantics, whether utils is present, and the
                               engines' WebSocket agreement
  tasks/m8-api-gaps.md       → NEW, opened empty before Part A's first line
```

`har.jl` holds both replay and recording rather than splitting, because
`update = true` straddles them and a two-file split would put one function's
two halves in two files. `websockets.jl` is separate from `routing.jl` despite
copying its pattern, because `routing.jl` is already 762 lines.

## Code Style

Unchanged. The house style, as `src/api/routing.jl` and `src/api/dialogs.jl`
establish it:

```julia
"""
    route_from_har(target, har; url = nothing, not_found = :abort)

Serve `target`'s matching requests from the HAR archive at `har`, so a page can
be driven with no backend running at all.

`target` is a [`Page`](@ref) or [`BrowserContext`](@ref); `har` is a path to a
`.har` or `.har.zip`. `url` restricts which requests are served — a glob,
`Regex` or predicate, exactly as [`route!`](@ref) takes — and `nothing` serves
all of them.

```julia
route_from_har(ctx, "test/fixtures/api.har"; url = "**/api/**")
goto!(page, "https://app.example.com")
```

`not_found` decides what happens to a request the archive has no entry for:
`:abort` (the default) fails it, `:fallback` lets it reach the real network.
The default is `:abort` on purpose (D4) — `:fallback` makes an incomplete
archive pass on a machine where the real server happens to be up, which is the
failure this feature exists to prevent.

Returns the [`RouteRegistration`](@ref) that [`unroute!`](@ref) takes. Prefer
[`with_har`](@ref), which releases the archive even when the body throws.
"""
function route_from_har(target::Union{Page,BrowserContext}, har::AbstractString; …)
    # harOpen is per-registration, not per-request: the driver parses the
    # archive once and hands back an id. Releasing it is unroute!'s job,
    # which is why the registration carries a release hook (D3).
    ...
end
```

Docstrings carry the signature, a worked example, and — where a decision
surprises — its reason, referenced to the `D` number in this spec. Comments
explain *why*. `snake_case`, four spaces, formatter-clean at the pinned
version.

## Testing Strategy

Three tiers, as M2–M7 established.

**Hermetic** (`Pkg.test()`, no Node, no browser) — must stay the majority:

- `test_har.jl` — the action table (D2) against a fake connection: each of
  `fulfill`/`redirect`/`error`/`noentry` driven as a canned `harLookup` reply
  and the resulting settle verb asserted. `not_found = :abort` vs `:fallback`
  on the same `noentry` reply. The redirect loop guard (D5) fed a cycle and
  asserted to raise, not hang — with a test timeout, because "asserted not to
  hang" is only true if the test can fail. `harOpen` returning `error` surfaces
  as a `DriverError` naming the file. `update = true` before Part B lands
  raises the "not yet" error (D7). Symbol validation for `content`/`mode`.
- `test_connection.jl` — the exact wire params for `launch_persistent_context`,
  and `launch`/`new_context` unchanged across D10's refactor. This is the
  refactor's pin and it grows before the refactor, not after.
- `test_websockets.jl` — the registry's lifetime rules against a fake
  connection, mirroring `test_dialogs.jl`: registration/removal, dispatcher
  task never running user code on the reader task, exceptions collected and
  rethrown at unregistration, subscriptions dropped when the route object is
  disposed (D13). `send_to_server!` in mock mode is an error. Binary round trip
  through the base64 flag, asserted as `Vector{UInt8}` in and out.
- `test_events.jl` — `:websocket`'s rewritten message (D14), asserted on the
  message a user sees and not only on table membership. That distinction is
  the lesson `tasks/m7-api-gaps.md` gap 2 paid for.
- `test_exports.jl` — the new names.

**Smoke** (`PLAYWRIGHT_JL_SMOKE=1`, both engines, in-process HTTP.jl fixture
server per `test/test_smoke.jl:7`):

- `test_smoke_har.jl` — the round trip, which is the only test that proves both
  parts at once: record a session against the fixture server with
  `with_har_recording`, **stop the server**, replay the archive with
  `route_from_har`, and assert the page renders the same. A replay test against
  a server that is still running proves nothing, so the server going down is
  part of the test, not an afterthought.
- a `noentry` request under `:abort` fails the page's fetch; under `:fallback`
  it reaches the server — asserted server-side, by the fixture server recording
  that it was hit.
- `content = :attach` producing a `.har.zip`, replayed through D3's unzip path.
- `update = true` refreshing an archive whose recorded body the server has since
  changed, asserted by replaying the updated file and seeing the new body.
- `test_smoke_persistent.jl` — launch on a temp `user_data_dir`, set a cookie
  and a `localStorage` key, `close!(ctx)`, assert the browser process is gone,
  relaunch on the same directory and assert both survived (SC 17).
- `test_smoke_websockets.jl` — against a real WebSocket endpoint on the fixture
  server: mock mode with the server never contacted (asserted server-side),
  proxy mode with a server message rewritten, a binary frame each way, the page
  observing a `close_ws!`, and D12's swallowing behaviour pinned.

**Docs** — guide examples are doctested where they run without a browser; the
rest are plain `julia` blocks.

The bar, unchanged: every exported name has a docstring (`checkdocs = :exports`
is a gate), and **every `D` decision has at least one test that would fail if
the decision were reversed.**

## Boundaries

**Always**

- Hermetic suite before every commit; smoke before every push.
- `gen/generate.jl --check` green at every commit, *without* anyone having run
  the generator (Assumption 4).
- Every new exported name gets a docstring and an `api.md` entry in the commit
  that introduces it.
- Every registration is released on every path — `harClose`, the temp
  directory, the WebSocket dispatcher. A test that can hang is not a test.
- Record anything noticed and out of scope in `tasks/m8-api-gaps.md`, opened
  empty before Part A's first line. Fourth turn of the instrument; M5 learned
  it must be opened early, M6 and M7 confirmed it.
- `format(".")` clean before every push.

**Ask first**

- Adding any package dependency. Assumption 11 says none is needed, and names
  the two places the temptation will come from.
- Running `gen/fetch_spec.jl` or moving the pinned Playwright/Node versions.
- Cutting, deferring or thinning any part (Assumption 10). Specifically: a
  Part D that ships without smoke coverage on both engines is a cut, whatever
  it is called.
- Any refactor of existing code beyond D10's option builders.
- Extending Part D to WebSocket *observation*, which looks adjacent and is a
  separate feature.

**Never**

- Call user code from the transport reader task (`events.jl:9`; the world-age
  trap). Parts A and D both add dispatchers; this is the rule they exist for.
- Parse a HAR file in Julia (see "What M8 is not").
- Weaken a docs or CI gate to make something green.
- Format from the `@pw-probe` environment.
- Hand-edit `src/generated/`.
- Let a smoke test depend on a server the replay tests just stopped, or on
  ordering between engines.

## Success Criteria

Each is a thing to run, not a thing to believe. Both engines wherever a browser
is involved, recorded in a table in [`tasks/todo.md`](tasks/todo.md) in the
M5/M6/M7 style — archived to `tasks/m8/` when the milestone closes, as its
seven predecessors were.

**Part A — replay**

1. `local_utils(conn)` returns a `LocalUtils` against the real driver, and
   raises a `DriverError` naming HAR replay when the field is absent —
   asserted hermetically by a connection built without it.
2. All four `harLookup` actions are driven hermetically and each produces the
   settle verb D2's table names. A test that reverses any row fails.
3. `not_found = :abort` and `:fallback` produce different observable outcomes
   on the *same* `noentry` reply — hermetically, and in smoke asserted
   server-side by whether the fixture server was hit.
4. A navigation whose archive entry is a redirect is continued at
   `redirectURL`, and a sub-resource with the same entry is fulfilled with the
   final response directly (D5) — the two paths asserted separately, because
   the probe found they are different actions. A cyclic archive surfaces the
   driver's own `HAR error: Found redirect cycle` message, within the test's
   timeout.
5. An aborted `noentry` names both the archive and the URL (D5a), asserted on
   the message text — the trap being that a non-HAR file opens successfully and
   then misses everything.
6. A `.har.zip` recorded with `content = :attach` replays, proving D3's unzip
   path; the temp directory does not exist after `unroute!`.
7. `route_from_har(…; update = true)` raises a clear "not yet" error at every
   commit in Part A, and stops doing so only in the Part B commit that
   implements it.
8. `unroute!` on a `route_from_har` registration calls `harClose` — asserted on
   the wire, hermetically.

**Part B — recording**

9. `with_har_recording` writes a file at the path it was given, and
   `stop_har_recording!` returns that path.
10. `content` and `mode` reject an invalid `Symbol` with an `ArgumentError`
   naming the valid set, before anything reaches the wire.
11. An export that produces no artifact raises a `DriverError` naming the path
    that was not written — the guard `stop_tracing!` already has (D8).
12. **The round trip**, both engines: record against the fixture server, stop
    the server, replay, and the page renders the same. The server being down is
    asserted, not assumed.
13. `url = "**/api/**"` on a recording produces an archive containing the API
    calls and not the page's own document request — asserted by replaying with
    `not_found = :abort` and observing the document request fail.
14. `update = true` against a server whose response has changed rewrites the
    archive; replaying the rewritten file serves the new body. Both engines.

**Part C — the profile**

15. `launch_persistent_context` sends `userDataDir` plus the union of launch
    and context options, asserted on the wire hermetically.
16. `launch`'s and `new_context`'s wire params are byte-identical across D10's
    refactor — the pre-existing `test_connection.jl` assertions pass unchanged.
17. An empty `user_data_dir` raises an `ArgumentError` before the wire.
18. **The reopen**, both engines: set a cookie and a `localStorage` key, close
    the context, relaunch on the same directory, both survive. This is the
    criterion; SC 14 without SC 17 is a wrapper, not a feature.
19. `length(pages(ctx)) == 1` immediately after `launch_persistent_context`,
    both engines, and the docstring's example uses `first(pages(ctx))` (D9).
    Asserted so that a future driver change to this behaviour is caught here
    rather than in a user's confusing blank second page.
20. `close!(ctx)` on a persistent context leaves no browser process behind —
    asserted on the process, not inferred from the context being closed.

**Part D — the socket**

21. `route_web_socket!` never runs a handler on the transport reader task —
    the same assertion `test_dialogs.jl` makes, by the same means.
22. Mock mode: the fixture server records that no connection was made, and the
    page still receives what the handler sent. Both engines.
23. Proxy mode: `connect!`, a server message rewritten in flight, the page
    receives the rewritten one. Both engines.
24. A binary frame survives each direction as `Vector{UInt8}`, with the caller
    never naming base64. Both engines.
25. `close_ws!` is observed by the page's `onclose`, with the code and reason
    it was given. Both engines.
26. D12's edge is **pinned as intended**: a proxy-mode
    `on_message_from_server!` that does not forward swallows the message, and a
    test asserts the swallow. If that ever changes upstream, this test tells us.
27. `send_to_server!` in mock mode raises before the wire.
28. Route subscriptions are gone after the socket closes — asserted on the
    subscription table, hermetically, so the leak D13 warns about cannot creep
    back.

**All parts**

29. Full hermetic suite green; full smoke suite green on both engines. Counts
    recorded, as M7 recorded 1933 hermetic / 2776 smoke.
30. `julia --project=docs docs/make.jl` — zero errors, zero warnings, with
    `checkdocs = :exports`, `warnonly = false` and `doctest = true` all still
    on and none weakened.
31. `gen/generate.jl --check` in sync, with `git diff` on `src/generated/`
    empty for the whole milestone (Assumption 4). `format(".")` clean.
32. `git diff` on `Project.toml` shows no new dependency (Assumption 11).
33. README Status rewritten for M8, and the not-covered list checked item by
    item against `names(Playwright)` — four entries removed, the rest
    justified individually rather than as a group.
34. `docs/bonnie-parity.md` re-scored, **or** a line stating explicitly that
    M8 adds no row and why. M6 and M7 both did this; a parity doc that goes
    quiet for a milestone is a parity doc nobody trusts.
35. `tasks/m8-api-gaps.md` exists, was opened empty before Part A's first line
    of code, and every entry in it is either fixed-on-instruction or left with
    its reasoning written down.

## Checkpoints

- **Checkpoint A** — end of Part A. SC 1–8. Replay works against the
  hand-written fixture archive; no browser needed for any of it.
- **Checkpoint B** — end of Part B. SC 9–14. The round trip passes on both
  engines, which is the first point at which the HAR feature is real.
- **Checkpoint C** — end of Part C. SC 15–20. **The budget checkpoint**: it is
  the smallest part and the last one before Part D, so its landing date is what
  Assumption 10's conversation is triggered by.
- **Checkpoint D** — end of Part D. SC 21–28.
- **Checkpoint E** — the milestone. SC 29–35.

A checkpoint that cannot be met is reported and asked about (Assumption 10),
not worked around.

## Resolved by the probe

Three of the four questions this spec opened with are answered in
[`tasks/m8-probe.md`](tasks/m8-probe.md), probed on both engines before any
code was written. Recorded here rather than deleted, because a question that
turned out to have a surprising answer is worth being able to find again.

1. **`harLookup`'s `redirect` contract** — answered, and the spec's guess was
   wrong. The driver follows sub-resource redirect chains itself and guards its
   own cycles; `redirect` is a navigation-only action. **D5 is rewritten** and
   is now one branch instead of a bounded loop. Two `harOpen` behaviours came
   with it and produced **D5a**.
2. **Firefox and `ContextOptions` on a persistent context** — answered, no
   divergence. Both engines honour `userAgent`, `locale` and `viewport`
   identically, and `localStorage` survives a relaunch on both. Assumption 8's
   weaken-and-record clause is not needed for Part C. The probe did find that a
   persistent context **arrives with one page already open**, which **D9 now
   covers**.
3. **`webSocketRoute`'s owner** — answered: delivered on the **`Page`** guid
   when armed on the page, on both engines. **D11's registry can key on the
   target the caller named.** The symmetric context-scoped case was not probed;
   Part D's first task asserts it rather than assuming it.

## Open Questions

1. **Whether `docs/bonnie-parity.md` gains a row.** Bonnie's suite drives a
   real server; HAR replay and persistent contexts may simply not apply to it.
   SC 32 requires an answer either way, not silence.
2. **Whether arming WebSocket interception on a `BrowserContext` delivers on
   the context** for a socket opened by one of its pages. `route!` works that
   way and the symmetric answer is expected, but it is unprobed — Part D's
   first task asserts it, and if it comes back page-scoped, D11's registry
   grows a filtering step and this becomes a spec edit rather than a surprise.
