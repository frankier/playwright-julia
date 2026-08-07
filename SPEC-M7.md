# Spec: Playwright.jl — Milestone 7 (the generator, the sweep, and the files)

Successor to [`SPEC.md`](SPEC.md) (M1), [`SPEC-M2.md`](SPEC-M2.md),
[`SPEC-M3.md`](SPEC-M3.md), [`SPEC-M4.md`](SPEC-M4.md),
[`SPEC-M5.md`](SPEC-M5.md) and [`SPEC-M6.md`](SPEC-M6.md), all six complete.
Tech stack, driver architecture, the codegen/API split, code style, testing
layout and boundaries carry over unchanged unless contradicted here.

M7 has three parts, and the order is the whole argument:

- **Part A — the generator.** Fix the class of bug that makes
  `_api_request_context_fetch` and `_cdp_session_send` fail on every call, and
  regenerate `src/generated/channels.jl`.
- **Part B — the sweep.** Close out
  [`tasks/m5-api-gaps.md`](tasks/m5-api-gaps.md) entirely: four fixed, five
  argued as deliberate and closed. Every one of these is a rename or a
  signature change.
- **Part C — the files.** Downloads, dialogs, and file choosers: the three
  remaining user-interaction surfaces, plus the uploads path.

**A before B before C, and neither ordering is arbitrary.** Part A regenerates
the layer Parts B and C build on, so it goes first or its diff collides with
theirs. Part B changes the shape of `save_as!` and of the artifact family —
which Part C's `Download` wrapper is a new member of. M6 learned this the
expensive way round and wrote it down: *new names should be born with the right
shape rather than renamed a week later.* Part C introduces roughly fifteen of
them.

## Assumptions

Calls this spec makes without being told. Correct any that are wrong.

1. **New spec, not a rewrite.** `SPEC-M7.md` joins its six predecessors; none
   of them are edited.
2. **Breaking changes are allowed and expected.** Nothing is registered in
   General and nothing depends on this package. As in M6, there are no
   deprecation shims — old spellings simply stop existing. Part B breaks four
   things on purpose.
3. **Playwright stays pinned at 1.61.1.** Part A regenerates from the *already
   vendored* `protocol/spec/*.yml`; it does **not** run `gen/fetch_spec.jl` and
   does not move the pinned driver version. This was considered and explicitly
   declined: re-vendoring changes browser downloads and risks behaviour drift
   across the entire smoke suite, which would dominate the milestone.
4. **Every command Part C needs already exists in the generated layer.**
   Verified against `protocol/spec/`:
   - `Dialog` interface with `accept(promptText?)` / `dismiss` and an
     initializer of `page`, `type`, `message`, `defaultValue`
     (`playwright.yml:477`); already emitted as `Dialog` /
     `_dialog_accept` / `_dialog_dismiss` (`channels.jl:59`, `:1811`, `:1822`).
   - `Page.download` event carrying `url`, `suggestedFilename`, `artifact`
     (`page.yml:682`).
   - `Page.fileChooser` event carrying `element`, `isMultiple` (`page.yml`).
   - `Frame.setInputFiles` (`channels.jl:3081`) and
     `ElementHandle.setInputFiles` (`channels.jl:2308`).
   - `Artifact.failure` and `Artifact.cancel` (`artifact.yml:40`, `:49`) —
     which is what makes `Download`'s failure path free.
5. **Sync-only, Julia floor 1.10.** Load-bearing again in D6: the dialog
   handler design exists because there is no async API to fall back on, and
   because a dialog blocks the page until somebody answers it.
6. **Chromium and Firefox both, or it does not ship.** Every success criterion
   involving a browser is verified on both. Downloads and dialogs are exactly
   the sort of surface where the two engines differ, so this is not a formality
   here.
7. **Linux-only remains the claim.** No CI matrix change.
8. **No new package dependency.** Nothing in Parts A–C needs one; `Base64` and
   `JSON` already cover in-memory upload payloads.
9. **WebKit, HAR, WebSocket routing, service workers, persistent contexts and
   the async API all stay out**, exactly as M6 left them. `route_from_har`
   still needs `localUtils` and is still not this milestone.

## Objective

### Part A — a generated function should be callable

`tasks/m6-api-gaps.md` records the finding: `gen/generate.jl:277` emits the
local parameter dictionary under the name `params`, and two protocol commands
have a *parameter* named `params`. The local shadows the keyword, so the
keyword is unreachable and `params === nothing` is never true — the call always
sends the dict serialized into itself, and the driver rejects it:

```
DriverError: params: expected array, got object
```

Both `_api_request_context_fetch` (`APIRequestContext.fetch`) and
`_cdp_session_send` (`CDPSession.send`) therefore **fail on every call
regardless of arguments**. M6 worked around it by hand-building the fetch call
in `src/api/apirequest.jl`; that workaround comes out here.

The fix is not "rename `params`". The fix is that *no* emitted local may be
spellable as a protocol parameter, so the next command with a parameter called
`result` or `obj` cannot reintroduce the bug silently — which is how this one
survived unnoticed from M1 to M6.

### Part B — close `tasks/m5-api-gaps.md`

Nine gaps were recorded in M5 while writing ~90 docstrings, on the theory that
a docstring which has to apologise for its subject is a design report. M6
resolved two of them incidentally and deferred the rest. They have now been
open for two milestones, and an open list that never shrinks stops being read.

M7 empties it: **four fixed, five closed as deliberate with the reasoning
written down.** Nothing is left "recorded".

### Part C — the browser can hand you a file, and ask you a question

Three things a real e2e suite hits within its first week that this package
currently cannot express at all:

```julia
# The browser hands you a file
dl = expect_download(page) do
    click!(locator(page, "#export-csv"))
end
@test suggested_filename(dl) == "report.csv"
save_as!(dl; path = "artifacts/report.csv")

# The page asks you a question
with_dialog(page) do d
    @test message(d) == "Delete this project?"
    accept!(d)
end do
    click!(locator(page, "#delete"))
end

# You hand the browser a file
set_input_files!(locator(page, "input[type=file]"), "test/fixtures/upload.csv")
```

All three are in `DEFERRED_EVENTS` today, and the entry for `:download` is
actively wrong — it says "Artifact is not wrapped yet", which stopped being
true in M4.

### What M7 is *not*

- Not a protocol re-vendor and not a Playwright version bump (Assumption 3).
- Not HAR, not WebSockets, not service workers, not WebKit.
- Not a trace *viewer* or any trace parsing.
- Not `page.on_download` style persistent listeners beyond what D6's registry
  gives; the block forms are the supported shape.

---

# Part A — the generator

## D1 — Every emitted local is underscore-prefixed, by construction

`gen/generate.jl` emits function bodies that declare locals (`params`, and the
already-safe `_obj`). Protocol parameter names come from the vendored spec and
are outside our control. The rule:

> **An emitted local is spelled with a leading underscore. A protocol parameter
> is spelled exactly as the spec spells it.** The two namespaces cannot
> intersect, because the spec has no parameter with a leading underscore.

Concretely, `params` becomes `_params` throughout the emitter, and the
generated body becomes:

```julia
function _api_request_context_fetch(
    _obj::APIRequestContextChannel;
    timeout::Real,
    url::AbstractString,
    params::Union{AbstractVector,Nothing} = nothing,
    ...
)
    _params = Dict{String,Any}()
    _params["timeout"] = to_wire(timeout)
    _params["url"] = to_wire(url)
    params === nothing || (_params["params"] = to_wire(params))
    ...
end
```

This is a whole-file mechanical change to `src/generated/channels.jl` — every
generated function's body. That is a feature, not a cost: `gen/generate.jl
--check` is the reviewer. The diff is verified by the check passing, not by
reading 4,000 lines.

**Why not just rename the one colliding local:** because the bug was invisible
for six milestones and cost M6 a hand-written workaround plus a written-up
investigation. The instance is cheap to fix; the class is what was expensive.

## D2 — A generator test asserts the collision cannot come back

`test/test_codegen.jl` gains a check that scans the emitted source for any
local binding not matching `^_`, and separately asserts that no generated
function has a keyword argument whose name would shadow a local. This fails
today and passes after D1 — which is the only way to know the fix is real
rather than incidental.

The check runs hermetically against the generated file already in the repo, so
it costs no Node and no browser.

## D3 — `src/api/apirequest.jl`'s hand-built call comes out

M6 built the `APIRequestContext.fetch` message by hand, with a comment pointing
at `tasks/m6-api-gaps.md`. With D1 landed, that function calls
`_api_request_context_fetch` like everything else. The comment goes; the
`tasks/m6-api-gaps.md` entry is marked resolved with the commit that did it.

`Playwright.fetch`'s public behaviour must not change: `test_routing.jl` and
`test_smoke_network.jl` SC 14 already pin fulfil-from-upstream, and they are
the regression test for this swap.

---

# Part B — the sweep

Four fixed (D4–D7), one dropped (D8), five closed as deliberate (D9).

## D4 — `name` → `frame_name`

`name(frame)` returns an iframe's HTML `name` attribute. `name` is far too
generic a word to take from a user's namespace via `using Playwright`, and
`name(browser)` — which any reader would expect to work — is a `MethodError`
next to the existing `browser_name`. `frame_name` collides with nothing.

Mechanically identical to M6's twelve renames: rename the definition, update
`api.md` and the frames guide, grep for survivors. One call site in the repo
(`test/test_frames.jl:25`). No shim.

## D5 — The artifact family splits capture from export

Today the family disagrees with itself:

| Call | Returns | `path` is |
|---|---|---|
| `screenshot(page; path = …)` | bytes | keyword |
| `pdf(page; path = …)` | bytes | keyword |
| `stop_tracing!(ctx; path = …)` | path | keyword |
| `save_as!(artifact, path)` | path | **positional** |

Two return conventions and two calling conventions in a family of four. After
M7 there is one of each:

```julia
screenshot(page; path = "shot.png")   # -> "shot.png"
pdf(page; path = "doc.pdf")           # -> "doc.pdf"
stop_tracing!(ctx; path = "t.zip")    # -> "t.zip"
save_as!(artifact; path = "run.webm") # -> "run.webm"

screenshot_bytes(page)                # -> Vector{UInt8}
pdf_bytes(page)                       # -> Vector{UInt8}
```

**The rule: if you named a destination you get the destination back; if you
want bytes you call the function that says bytes.** Every function is
type-stable, which the alternative — returning `Union{String,Vector{UInt8}}`
depending on whether a keyword was passed — is not.

`path` becomes required on `screenshot` and `pdf`; the in-memory case moves to
the `_bytes` spelling. Two new exports, two new docstrings, two new `api.md`
entries.

Known call sites this breaks, all in-repo:

| Site | Change |
|---|---|
| `examples/wglmakie_jl.jl:126` | `screenshot(page)` → `screenshot_bytes(page)` |
| `test/test_smoke.jl:452` | `bytes = screenshot(page; path)` → two calls, or assert the path |
| `test/test_parity.jl:234`, `test/test_artifacts.jl:676` | `bytes = pdf(…)` → `pdf_bytes` |
| `test/test_closed.jl:262`, `test/test_fixtures.jl:340`, `test/test_smoke.jl:199` | bare `screenshot(page)` in error-path tests → `screenshot_bytes` |
| `docs/src/guide/artifacts.md:106–107` | both lines |

## D6 — `save_as!` takes `path` as a keyword

Folded into D5's table above, but called out separately because it is the one
change that touches a name Part C then extends: `save_as!(dl; path = …)` on a
`Download` must have the same shape as `save_as!(artifact; path = …)`, and it
will only have that shape if this lands first. Call sites:
`test/test_artifacts.jl:106,117,650`, `docs/src/guide/artifacts.md:147`.

## D7 — `set_default_strict!`, following the timeout cascade

`set_default_timeout!` cascades frame → page → context, so a suite sets it once
(`src/timeouts.jl`). Strictness is a per-`locator` keyword with no equivalent,
so a suite that works with lists writes `strict = false` on every call — the
Oxygen and Genie examples say it four times between them.

`set_default_strict!(target, strict::Bool)` follows the pattern that already
exists, resolved at `locator(...)` construction time with the same
frame → page → context precedence, and an explicit `strict =` keyword still
winning over the default. No new concept, and the highest payoff-per-line item
in Part B.

The resolution order must be specified and tested, not assumed: an explicit
keyword beats a frame default beats a page default beats a context default
beats `true`.

## D8 — `sources` leaves `start_tracing!`'s signature

`start_tracing!(ctx; sources = true)` throws `ArgumentError`, because 1.61.1's
`tracingStart` carries no sources flag on the archive path this package uses
(`src/api/artifacts.jl:158`). Raising beats silently ignoring — but a keyword
whose only legal value is `false` should not be in the signature at all.
Removing it turns a runtime `ArgumentError` into a `MethodError`, which is
strictly better feedback and arrives earlier.

`test/test_artifacts.jl:192` inverts: it currently asserts the `ArgumentError`,
and afterwards asserts the `MethodError`. The note in
`docs/src/guide/artifacts.md:72` stays — a reader coming from
`playwright-python` still needs to be told *why* the keyword is absent — but is
rewritten from "raises" to "is not accepted".

## D9 — Five gaps close as deliberate, with the reasoning written down

These are not deferred again. Each gets its rationale recorded in the docstring
or guide page that owns it, and `tasks/m5-api-gaps.md` is deleted at the end of
Part B — its content having become either a commit or a documented decision.

| Gap | Closed because |
|---|---|
| **1** — `count`, `first`, `last`, `length`, `iterate`, `getindex` extend `Base` and are unexported, so `checkdocs = :exports` cannot see them | M6 closed the sharp half by turning `fill`/`close` into real exports. What remains is the iteration and indexing protocol, where extending `Base` *is* the correct Julia design and exporting the names would shadow `Base` for the whole session — M6 D3 proved that concretely with `fill!`. The docs-gate hole is real and accepted; the guide says so. |
| **2** — `is_visible` takes no `timeout`; `is_checked` and `is_enabled` do | The missing `timeout` *is* the signal. `is_visible` returns `false` for a missing element rather than waiting, which is exactly what makes it safe to ask about elements that may not exist; a `timeout` would imply a wait it deliberately does not perform. Documented at the call site rather than papered over with a keyword that would have to be ignored. |
| **5** — `retry_until(f, target)` puts its target second | Forced by do-block syntax: the function must be argument one for `retry_until(target) do … end` to read. Julia's constraint, not the package's. |
| **6** — `element_handle` resolves now, `wait_for_selector` waits | They mirror Playwright's own two calls, and a Playwright user expects both to exist with those meanings. Collapsing them would surprise the people most likely to read this package. Cross-references between the two docstrings carry the distinction. |
| **8** — `evaluate`'s expression arity depends on argument 1's type | Playwright's own design, inherited faithfully by every binding in every language. Diverging would surprise anyone who knows Playwright more than the current behaviour surprises anyone who does not. |

**Closing a gap is a documentation deliverable, not a deletion.** A gap closed
without its reason recorded is a gap that gets re-discovered next milestone.

---

# Part C — downloads, dialogs, file choosers

## D10 — `Download` wraps the `Artifact` and keeps an escape hatch

The `download` event carries three things: `url`, `suggestedFilename` and an
`Artifact`. Only the artifact survives if the event yields a bare `Artifact`,
and `suggestedFilename` is the single most-used download field — it is what the
server named the file.

```julia
struct Download
    artifact::Artifact
    url::String
    suggested_filename::String
    page::Page
end
```

Surface: `url`, `suggested_filename`, `save_as!(dl; path)`, `path(dl)`,
`delete_file!(dl)`, `cancel!(dl)`, `failure(dl)`, and `artifact(dl)`.

- `save_as!`, `path` and `delete_file!` gain a `Download` method each and
  forward to the artifact — which is why D6 lands first, so the keyword shape
  is right on arrival.
- `cancel!` and `failure` map to `Artifact.cancel` and `Artifact.failure`
  (`artifact.yml:40`, `:49`), both already generated. `failure(dl)` returns
  `Union{String,Nothing}` — `nothing` for a download that succeeded.

**The failure path is throwing, and that is the driver's choice, not ours.**
Probed (`tasks/m7-probe.md`): a download refused by `accept_downloads = false`
*still delivers the event*, with a correct `url` and `suggested_filename`. The
refusal surfaces only when the artifact is asked for something — `path` and
`save_as!` raise `DriverError` carrying the driver's own sentence, while
`failure` returns it as a string. So:

> `failure(dl)` is the only non-throwing way to ask whether a download
> succeeded. `path(dl)` and `save_as!(dl; …)` raise on a failed one.

The docstrings for all three say this, because a user who reaches for
`isnothing(path(dl))` as the success check will get an exception instead of a
`nothing`, and nothing in the name warns them.
- `artifact(dl)` is the escape hatch: anything the wrapper does not cover stays
  reachable, so the wrapper is non-lossy by construction rather than by
  promise.

`Artifact`'s blocking semantics are inherited unchanged and are the reason this
works at all: `path(dl)` blocks until the file is completely written, which for
a download is exactly the thing a test needs.

## D11 — `expect_download` is a block form over the existing event machinery

`:download` leaves `DEFERRED_EVENTS` and joins `PAGE_EVENTS` with a payload
mapper that builds the `Download` from the event params — the same shape as
M6's `:requestfailed`, which likewise had to reach into params for a field that
exists nowhere else.

Its `EventSpec` is **not** opt-in, and `:dialog` and `:filechooser` **are**.
`page.yml:592`'s `updateSubscription` enum is
`console, dialog, fileChooser, request, response, requestFinished,
requestFailed` — `download` is absent, so the driver emits it unconditionally,
while the other two need the flag M6 built for the network events. Getting this
backwards costs a 30-second timeout and no error message, so it is stated here
rather than discovered.

`expect_download(f, page; timeout)` is `expect_event(page, :download)` with the
payload typed, mirroring M6's `expect_request` / `expect_response` exactly. The
click that triggers the download goes inside the block, because registering the
listener after the click is a race.

`new_context` gains `accept_downloads::Union{Bool,Nothing}` and
`downloads_path`. The mapping onto the protocol's three-valued enum
(`mixins.yml:174`: `accept` | `deny` | `internal-browser-default`) is where the
probe changed the design:

| Julia | wire |
|---|---|
| `true` | `"accept"` |
| `false` | `"deny"` |
| `nothing` (default) | **parameter omitted entirely** |

`nothing` must *not* map to `"internal-browser-default"`, which is the obvious
reading of the name and is wrong. Probed on both engines: that value hands the
download to the browser's own machinery and **Playwright emits no event at
all** — the page appears to do nothing and the test waits out its full timeout
with no clue why. It is the one value this package never sends, and D10's
docstring says so, because the enum is sitting there waiting for someone to map
it by name.

The probe also settled the question this keyword was raised for: **omitting the
parameter already accepts downloads on both engines.** `accept_downloads` is
therefore a convenience — needed to write the *refusal* test, not to write the
ordinary one — and the guide does not open with it.

## D12 — Dialogs use a handler registry, and auto-dismiss survives

Playwright's rule: **with no listener registered, a dialog is automatically
dismissed; with one registered, it is not.** A dialog that nobody answers
blocks the page until it times out.

That rule is mechanical, not a convention: `dialog` is in `page.yml:592`'s
`updateSubscription` enum, so "a client subscribed" and "the driver now expects
somebody to answer" are the *same event on the wire*. Which means any design
that subscribes speculatively has already disarmed the safety net.

That rule makes the event-only design a footgun. `expect_event(page, :dialog)`
registers a listener, which disables auto-dismiss — so a second dialog firing
outside the block hangs the page for the full 30 seconds. The registry design
avoids it:

```julia
reg = on_dialog!(page) do d
    dialog_type(d) == "confirm" ? accept!(d) : dismiss!(d)
end
...
off_dialog!(page, reg)

# or, scoped:
with_dialog(page; handler) do
    click!(locator(page, "#delete"))
end
```

The scoped form takes the handler as a **keyword** and the triggering action as
the do-block. The alternative — `with_dialog(handler, page) do … end`, handler
positional — is the shape `with_route` uses, but two functions in one call with
only argument position to tell them apart reads badly at the call site. The
keyword names the unusual one.

This is deliberately the same shape as M6's `route!` / `unroute!` /
`with_route` trio, and inherits its three hard-won decisions:

- **A dialog nobody settles is dismissed, never left hanging** (M6 D6's rule,
  restated for dialogs). If a handler returns without calling `accept!` or
  `dismiss!`, the package dismisses it and warns once per registration.
- **A handler that throws does not vanish and kills nothing** (M6 D7). The
  exception is collected and rethrown out of `with_dialog` / `off_dialog!`; the
  dialog is still dismissed so the page proceeds.
- **Handlers run on a dispatcher task, one per registered owner** (M6 D5), for
  the same reason: user code must never run on the transport reader task
  (`events.jl:9`, the world-age trap).

`Dialog` surface: `dialog_type(d)` (`"alert"` | `"beforeunload"` | `"confirm"`
| `"prompt"` — not `type`, which is unusable), `message(d)`,
`default_value(d)`, `accept!(d; prompt_text = nothing)`, `dismiss!(d)`.

`:dialog` also leaves `DEFERRED_EVENTS`, but the registry is the documented
path and the guide says why.

## D13 — Uploads: the direct setter *and* the chooser

Two mechanisms, because two things happen in the wild.

**The direct setter** covers a plain `<input type=file>`, which is the
overwhelming majority:

```julia
set_input_files!(loc, "test/fixtures/upload.csv")
set_input_files!(loc, ["a.csv", "b.csv"])
set_input_files!(loc; name = "x.csv", mime_type = "text/csv", buffer = data)
set_input_files!(loc)                    # clears the selection
```

It dispatches on `Locator` (→ `Frame.setInputFiles` with the locator's selector
and strictness) and on `ElementHandle` (→ `ElementHandle.setInputFiles`), both
already generated. Paths and the in-memory `(name, mime_type, buffer)` form are
mutually exclusive and validated at the call site with an `ArgumentError` — the
same treatment M6 D15 gave `fulfill!`'s body sources.

**The chooser** covers a button that opens a file dialog via JS with no
reachable input:

```julia
fc = expect_file_chooser(page) do
    click!(locator(page, "#attach"))
end
set_files!(fc, "test/fixtures/upload.csv")
```

`FileChooser` wraps the event's `element` (an `ElementHandle`) and
`isMultiple`: `element(fc)`, `is_multiple(fc)`, `set_files!(fc, …)` — where
`set_files!` is `set_input_files!` on the element, so the payload validation
lives in exactly one place. `:filechooser` leaves `DEFERRED_EVENTS`.

## D14 — `DEFERRED_EVENTS` is audited against reality, and stays audited

`DEFERRED_EVENTS[:download]` currently reads *"Artifact is not wrapped yet"*.
`Artifact` has been wrapped since M4, so the error tells a user something false
about why their event is unsupported. That entry disappears in Part C along
with `:dialog` and `:filechooser` — but the drift is the finding, not the
entry.

Every remaining entry (`:worker`, `:websocket`, `:route`, `:bindingcall`) is
re-read against the current source in the same commit, and
`test/test_events.jl` gains a check that the table names only events which are
genuinely absent from `events_for` on every owner — so a supported event can
never sit in the deferred table again.

Note that `:route` is already stale in a subtler way: `Route` *is* wrapped
(M6), it simply is not exposed as an event because `route!` is the supported
path. That message needs rewriting to say so, not deleting.

---

## Tech Stack

Unchanged from M6. Pieces this milestone leans on:

- `gen/generate.jl` — the emitter, and `--check` as Part A's reviewer.
- `src/api/events.jl` — the `Subscription` / `EventSpec` / `deliver_event`
  machinery Part C extends, and `DEFERRED_EVENTS` (D14).
- `src/api/routing.jl` — the registry + dispatcher-task pattern D12 copies.
- `src/api/artifacts.jl` — `Artifact` and its three verbs, which `Download`
  wraps rather than reimplements.
- `src/timeouts.jl` — the cascade `set_default_strict!` follows (D7).
- `Base64` for in-memory upload buffers. No new dependency.

## Commands

Unchanged from M5/M6; repeated so the spec stands alone.

```console
$ julia --project=. -e 'using Pkg; Pkg.test()'                        # hermetic
$ PLAYWRIGHT_JL_SMOKE=1 julia --project=. -e 'using Pkg; Pkg.test()'  # + browsers
$ julia --project=gen -e 'using JuliaFormatter; format(["src","test"])'
$ julia --project=gen gen/generate.jl                                 # regenerate
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
  gen/generate.jl            → CHANGED. every emitted local gains `_` (D1)
  src/generated/channels.jl  → REGENERATED, whole file, mechanically
  src/api/apirequest.jl      → CHANGED. hand-built fetch call removed (D3)
  test/test_codegen.jl       → CHANGED. the no-shadow check (D2)
  tasks/m6-api-gaps.md       → CHANGED. entry 1 marked resolved

Part B
  src/api/frames.jl          → CHANGED. name → frame_name (D4)
  src/api/navigation.jl      → CHANGED. screenshot / screenshot_bytes (D5)
  src/api/artifacts.jl       → CHANGED. pdf/pdf_bytes, save_as! keyword,
                               sources dropped (D5, D6, D8)
  src/timeouts.jl            → CHANGED. set_default_strict! cascade (D7)
  src/api/locators.jl        → CHANGED. locator() consults the cascade (D7)
  src/Playwright.jl          → CHANGED. exports
  test/**, docs/**, examples/**, README.md → CHANGED at the call sites D5 lists
  tasks/m5-api-gaps.md       → DELETED at the end of Part B (D9)

Part C
  src/api/downloads.jl       → NEW. Download, expect_download (D10, D11)
  src/api/dialogs.jl         → NEW. Dialog, the registry, with_dialog (D12)
  src/api/uploads.jl         → NEW. set_input_files!, FileChooser (D13)
  src/api/lifecycle.jl       → CHANGED. accept_downloads / downloads_path (D11)
  src/api/events.jl          → CHANGED. three events leave DEFERRED_EVENTS;
                               the table is audited and gated (D14)
  test/test_downloads.jl     → NEW, hermetic
  test/test_dialogs.jl       → NEW, hermetic
  test/test_uploads.jl       → NEW, hermetic
  test/test_smoke_files.jl   → NEW, smoke, both engines
  test/fixtures/m7.html      → NEW. a download link, an alert/confirm/prompt
                               trio, a file input, a JS-opened chooser
  test/fixtures/upload.csv   → NEW. a small fixture file to upload
  docs/src/guide/files.md    → NEW guide page
  docs/src/guide/events.md   → CHANGED. the supported-events table grows
  docs/src/api.md            → CHANGED
  README.md                  → CHANGED. Status section
  docs/bonnie-parity.md      → CHANGED. re-scored where uploads/downloads apply

Spec phase (already landed)
  tasks/m7-probe.md          → NEW. the acceptDownloads / isMultiple findings
```

Part C splits across three files from the start for the same reason M6's Part B
split across four: the seams are obvious, and pre-committing to them costs
nothing.

## Code Style

Unchanged. The house style, from `src/api/routing.jl`:

```julia
"""
    with_dialog(page::Page; handler) do
        click!(locator(page, "#delete"))
    end

Run the block with `handler` installed as `page`'s dialog handler, removing it
afterwards even if the block throws.

A dialog the handler neither accepts nor dismisses is dismissed by the package
and warned about once per registration (D12) — Playwright leaves such a dialog
blocking the page, and a test that hangs for thirty seconds is worse than a
test that tells you what you forgot.
"""
function with_dialog(f, page::Page; handler)
    # Registration before the block, removal in the `finally`: a dialog raised
    # by the block's very first statement must already find a handler.
    ...
end
```

Docstrings carry the signature, a worked example, and — where a decision
surprises — its reason, referenced to the `D` number in this spec. Comments
explain *why*. `snake_case`, four spaces, formatter-clean at the pinned
version.

## Testing Strategy

Three tiers, as M2–M6 established.

**Hermetic** (`Pkg.test()`, no Node, no browser) — must stay the majority:

- `test_codegen.jl` — D2's no-shadow check, plus the existing `--check`
  staleness gate. This is the test that must fail before Part A and pass after;
  writing it first is not optional.
- `test_downloads.jl` — `Download` construction from a synthetic event payload
  against the fake connection, the forwarding of all three artifact verbs,
  `failure` returning `nothing` vs. a string, and `accept_downloads` mapping
  `true`/`false`/`nothing` onto the three-valued wire enum.
- `test_dialogs.jl` — the registry's lifetime rules against a fake connection:
  registration/removal, the unsettled-dialog auto-dismiss and its
  once-per-registration warning, a throwing handler's exception surfacing out
  of `with_dialog` while the dialog is still dismissed, and the dispatcher task
  never running user code on the reader task.
- `test_uploads.jl` — payload validation: paths vs. in-memory buffer are
  mutually exclusive (`ArgumentError` at the call site), the empty call clears,
  `Locator` and `ElementHandle` dispatch reach the right generated command with
  the right selector and strictness.
- `test_exports.jl` — grows the new names; Part B's old-name grep lives here
  and, per M6 T17's lesson, walks **all** of `docs/`, not just `docs/src`.
- `test_artifacts.jl` — rewritten for D5/D6/D8: the `_bytes` split, the keyword
  `path`, and the `sources` `MethodError`.
- `test_timeouts.jl` / a new strictness block — D7's full precedence chain:
  explicit keyword > frame > page > context > `true`.

**Smoke** (`PLAYWRIGHT_JL_SMOKE=1`, both engines, in-process HTTP.jl fixture
server per `test/test_smoke.jl:7`):

- a link with `download` triggers `:download`; `suggested_filename` matches what
  the server set, `save_as!` writes a file with the right bytes;
- a download from a context with `accept_downloads = false` fails, and
  `failure(dl)` says so;
- `alert`, `confirm` and `prompt` each answered by a handler; the page observes
  the answer (a `confirm` accepted and dismissed produce different DOM);
- no handler registered → the dialog is auto-dismissed and the page proceeds,
  proving the Playwright default survived D12;
- a handler that settles nothing → warned once, page proceeds;
- a handler that throws → exception out of `with_dialog`, page still proceeds;
- `set_input_files!` on a real `<input type=file>`, asserted **server-side** by
  the fixture server echoing the uploaded filename and bytes back;
- multiple files, and the in-memory buffer form;
- `expect_file_chooser` around a JS-opened chooser, `is_multiple` correct on
  both engines.

Downloads and dialogs are the surfaces where Chromium and Firefox most often
differ. Any assertion that turns out to be engine-specific gets weakened to
what holds on both and the difference recorded — M6 SC 16 is the precedent.

**Docs** — guide examples are doctested where they run without a browser; the
rest are plain `julia` blocks.

The bar, unchanged: every exported name has a docstring (`checkdocs = :exports`
is a gate), and **every `D` decision has at least one test that would fail if
the decision were reversed.**

## Boundaries

**Always**

- Hermetic suite before every commit; smoke before every push.
- Part A's regeneration is one commit, and `gen/generate.jl --check` is green in
  it. The generated file is never hand-edited.
- Part B's renames land one name per commit, green between each — M6 D4's rule.
- Every new exported name gets a docstring and an `api.md` entry in the commit
  that introduces it.
- Settle every dialog on every path (D12). A test that can hang is not a test.
- `format(".")` and `gen/generate.jl --check` clean before every push.

**Ask first**

- Adding any package dependency. The design says none is needed.
- Running `gen/fetch_spec.jl` or moving the pinned Playwright version
  (Assumption 3 says no).
- Any API change beyond D4–D9. Part B's scope is exactly the nine recorded
  gaps and nothing else — this milestone is precisely when unrelated fixes look
  cheap and reviewable, and M6's Assumption 4 explains why they are neither.
- Adding HAR, WebSockets, service workers or WebKit.

**Never**

- Leave a dialog unanswered with no path to being settled.
- Call user code from the transport reader task (`events.jl:9`; the world-age
  trap).
- Weaken a docs or CI gate to make something green.
- Format from the `@pw-probe` environment.
- Close a `tasks/m5-api-gaps.md` entry without recording why in the docs (D9).

## Success Criteria

Each is a thing to run, not a thing to believe. Both engines wherever a browser
is involved, recorded in a table in [`tasks/todo.md`](tasks/todo.md) in the M5/M6
style — archived to `tasks/m7/` when the milestone closes, as its predecessors
were.

**Part A — the generator**

1. `test_codegen.jl`'s no-shadow check **fails on the pre-D1 generator** and
   passes after. Demonstrated by running it at both commits, not asserted.
2. `_api_request_context_fetch` is callable with a real `params` argument and
   the driver accepts it — the exact call that produced
   `DriverError: params: expected array, got object` now succeeds.
3. `gen/generate.jl --check` reports in sync after regeneration.
4. `git diff` on `src/generated/channels.jl` contains no change other than
   local renames — verified by a scripted diff filter, since the file is too
   large to read.
5. `src/api/apirequest.jl` contains no hand-built message dict; full hermetic
   and smoke suites green, with `test_smoke_network.jl` SC 14
   (fulfil-from-upstream) unchanged and passing.

**Part B — the sweep**

6. `frame_name` in `names(Playwright)`; `name` absent; the old-name grep in
   `test_exports.jl` finds no survivor anywhere under `src/`, `test/`, `docs/`,
   `examples/` or `README.md`.
7. `screenshot(page; path)` returns the path; `screenshot_bytes(page)` returns
   `Vector{UInt8}`; `screenshot(page)` is a `MethodError`. Same three for `pdf`.
8. All four artifact-family calls take `path` as a keyword and return it. Proved
   by a test that chains `save_as!(a; path = p) |> isfile`.
9. `start_tracing!(ctx; sources = false)` is a `MethodError`;
   `docs/src/guide/artifacts.md` explains the absence without claiming it
   raises.
10. `set_default_strict!` precedence verified across all five levels of D7's
    chain, each level proved to be reached by overriding exactly one.
11. At least one example loses a redundant `strict = false` because of D7 — the
    feature is justified by a real call site getting shorter, not by argument.
12. `tasks/m5-api-gaps.md` is deleted, and each of the five closed gaps has its
    rationale findable in a docstring or guide page. Verified by grepping for
    each gap's key phrase in `src/` and `docs/`.

**Part C — the files**

13. A real download on both engines: `suggested_filename` matches the server's
    `Content-Disposition`, and `save_as!` writes bytes identical to what the
    server sent.
14. `path(dl)` blocks until the file is complete — proved by asserting
    `isfile` immediately after it returns, with no `sleep` anywhere in the test.
15. `failure(dl)` returns `nothing` for a good download and a non-empty string
    for one refused by `accept_downloads = false`, on both engines — and on
    that same refused download, `path(dl)` **raises** rather than returning
    `nothing` (D10). Both halves asserted; the second is the one a user gets
    wrong. Additionally, hermetically: `accept_downloads = nothing` omits the
    wire parameter rather than sending `"internal-browser-default"`, asserted
    against the fake connection in `test_downloads.jl` — hermetic on purpose,
    because the smoke symptom of getting it wrong is an unexplained timeout
    with no error to grep for.
16. `artifact(dl)` returns the underlying `Artifact` and its verbs work directly
    on it — the escape hatch is exercised, not just exported.
17. `alert`, `confirm` (accepted), `confirm` (dismissed) and `prompt` (with
    `prompt_text`) each produce the correct observable effect in the page, both
    engines.
18. **With no handler registered, a dialog is auto-dismissed and the page
    proceeds** — the Playwright default, proved to have survived D12, on both
    engines. This is the criterion that would catch the event-only design's
    footgun if the design ever drifted.
19. A handler that settles nothing warns exactly once per registration and the
    page proceeds; a handler that throws surfaces its exception out of
    `with_dialog` and the page still proceeds. Both engines.
20. `set_input_files!` on a real file input, asserted **server-side**: the
    fixture server echoes back the filename and the bytes it received. Both
    engines, and for the multi-file and in-memory-buffer forms.
21. `set_input_files!` with both a path and a buffer raises `ArgumentError` at
    the call site, before any message reaches the driver.
22. `expect_file_chooser` yields a `FileChooser` whose `is_multiple` is `false`
    for a plain input, `true` for `multiple`, and **`false` for
    `webkitdirectory`** — probed identical on both engines, so no narrowing is
    needed and the `webkitdirectory` case asserts `false` on purpose, not by
    omission. `set_files!` on the chooser uploads successfully, both engines.
23. `:download`, `:dialog` and `:filechooser` are absent from `DEFERRED_EVENTS`
    and present in `events_for(::Page)`; `test_events.jl`'s new gate fails if a
    supported event is left in the deferred table.
24. The `:route` deferred message no longer claims `Route` is unwrapped.

**Whole-milestone**

25. Hermetic `Pkg.test()` green; `PLAYWRIGHT_JL_SMOKE=1` green on Chromium and
    Firefox; pass counts recorded.
26. `julia --project=docs docs/make.jl` — zero errors, zero warnings, with
    `checkdocs = :exports`, `warnonly = false` and `doctest = true` all still on
    and none weakened.
27. `gen/generate.jl --check` in sync; `format(".")` true; `Project.toml`
    unchanged since M6 (no new dependency).
28. `examples/runexamples.jl` passes on both engines after D5's call-site
    changes.
29. README Status rewritten: milestones 1–7; downloads, file choosers and
    dialogs removed from the not-covered list.
30. A `tasks/m7-api-gaps.md` is **opened empty before Part B starts**, per M6's
    lesson that a gap record opened late is a gap record half written.

## Resolved during review

- **`with_dialog`'s signature** — settled as `with_dialog(page; handler) do … end`
  (D12). Handler as a keyword, triggering action as the do-block; two functions
  distinguished by position would read badly.
- **`screenshot_bytes` naming** — kept. Explicit beats short here, and the
  suffix is what makes the family's rule legible at a call site.

- **`acceptDownloads` and `is_multiple`** — both probed against the live 1.61.1
  driver on Chromium and Firefox before implementation began. Findings in
  [`tasks/m7-probe.md`](tasks/m7-probe.md); the two engines agreed exactly on
  every case, so M7 carries no engine-specific carve-out. Three of the findings
  changed the design (D10's throwing failure path, D11's `nothing` → *omit*
  mapping, and D11's opt-in flags) and one corrected a success criterion
  (`webkitdirectory` is `is_multiple = false`).

## Open Questions

None outstanding. The two that were open at first review were probed rather
than guessed; see above.
