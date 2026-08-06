# Hand-written companions to the generated channel-owner types.
#
# The protocol object types themselves (Browser, Page, Frame, …) and the
# CHANNEL_TYPES registry now come from src/generated/channels.jl. What stays
# here is what the protocol has no notion of: Locator, which is a client-side
# construct, PlaywrightAPI, which is this package's entry handle, and small
# accessors over channel-owner initializers.

"""
    browser_name(bt::BrowserType) -> String
    browser_name(browser::Browser) -> String

Engine behind a [`BrowserType`](@ref) or a running [`Browser`](@ref):
`"chromium"` or `"firefox"`.

Useful for the cases where the engines genuinely differ and a test has to say
so out loud rather than paper over it:

```julia
if browser_name(browser) == "firefox"
    # ...the one thing Firefox does differently
end
```

A `String` from both methods, not a `Symbol` — one name, one return type. The
`Browser` initializer carries both `name` and `browserName`; they are identical
on both engines (probed — see T8 in `tasks/plan.md`), and `name` is read
because that is what the `BrowserType` method already used.
"""
browser_name(bt::BrowserType) = bt.initializer["name"]::String
browser_name(browser::Browser) = browser.initializer["name"]::String

"""
The [`Browser`](@ref) `obj` ultimately belongs to, or `nothing` if the chain is
broken — which in practice means something on it has been disposed.

A walk up `conn.parents` rather than a stored back-reference: the generated
channel-owner structs have a fixed field layout, and the registry already knows
the tree.
"""
function owning_browser(obj::ChannelOwner)
    conn = obj.connection
    return lock(conn.lock) do
        guid = obj.guid
        while true
            candidate = get(conn.objects, guid, nothing)
            candidate isa Browser && return candidate
            parent = get(conn.parents, guid, nothing)
            (parent === nothing || isempty(parent)) && return nothing
            guid = parent
        end
    end
end

"""
    owning_context(obj::ChannelOwner) -> Union{BrowserContext,Nothing}

The `BrowserContext` an object belongs to, found by walking the registry's
parent links — the same walk as [`owning_browser`](@ref), stopping one level
sooner.

A `BrowserContext` owns itself, which makes `owning_context` safe to call on
either owner without asking which one it has. That is what lets the network
events (D11) subscribe on "the context of whatever you named".
"""
function owning_context(obj::ChannelOwner)
    conn = obj.connection
    return lock(conn.lock) do
        guid = obj.guid
        while true
            candidate = get(conn.objects, guid, nothing)
            candidate isa BrowserContext && return candidate
            parent = get(conn.parents, guid, nothing)
            (parent === nothing || isempty(parent)) && return nothing
            guid = parent
        end
    end
end

"""
    browser_name(page::Page) -> String
    browser_name(context::BrowserContext) -> String

Engine a page or context is running on, found by walking up to its
[`Browser`](@ref). This is what lets a call decide an engine-specific question
*client-side* — [`pdf`](@ref) refuses to run off Chromium without a round trip
to be told so (D7).

Raises [`TargetClosedError`](@ref) when the owning browser is gone, since a
page with no browser above it has been closed.
"""
function browser_name(obj::Union{Page,BrowserContext})
    browser = owning_browser(obj)
    browser === nothing && throw(
        TargetClosedError(
            "no live browser above this object, so it has been closed";
            name = "TargetClosedError",
        ),
    )
    return browser_name(browser)
end

"""
Main frame backing `page`; page-level actions delegate to it.

Raises [`TargetClosedError`](@ref) once the page has closed. Every page-level
entry point (`goto!`, `title`, `evaluate`, `locator`, `frames`, `frame_locator`,
the waiting calls) hops through here, so this one guard covers them all.

The check is on the **page**, not on the frame, and that distinction is load
bearing. Probed on both engines: closing a page disposes the page but leaves
its main frame registered, because the driver parents a main frame to the
browser context rather than to the page. Guarding on the frame therefore
catches nothing on a page close — it only fires when the whole context goes.
Guarding on the page catches both, since disposing a context cascades to its
pages.

Two failure modes this closes. Calls that do a round-trip (`title`, `evaluate`)
were already raising `TargetClosedError`, but from the driver and only after a
protocol call. Calls that do not (`locator`, which is lazy by design) returned
a perfectly ordinary object that failed confusingly later. And when the context
had gone, the surviving `::Frame` assertion turned into a Julia `TypeError`,
which is neither catchable as a `PlaywrightError` nor informative.
"""
function main_frame(page::Page)
    frame = from_channel(page.connection, page.initializer["mainFrame"])
    if lookup_object(page.connection, page.guid) === nothing || !(frame isa Frame)
        throw(
            TargetClosedError(
                "the page has been closed, so this call has nothing to run against";
                name = "TargetClosedError",
            ),
        )
    end
    return frame
end

"""
    Locator

Lazy handle for `selector` inside a frame. Holds no element reference —
every action re-resolves the selector in the browser, Playwright-style.
Created with [`locator`](@ref).

`strict` mirrors Playwright's strictness: when true (the default) acting on a
selector that matches more than one element is an error rather than a silent
pick. It is checked on *action*, not on construction.

```julia
loc = locator(page, "#name")            # nothing has happened yet
set_value!(loc, "Ada")                        # now the selector is resolved
```

Read the three parts back with [`frame`](@ref), [`selector`](@ref) and
[`is_strict`](@ref).
"""
struct Locator
    frame::Frame
    selector::String
    strict::Bool
end

Locator(frame::Frame, selector::AbstractString) = Locator(frame, String(selector), true)

"""
    PlaywrightAPI

Root handle passed to the [`playwright`](@ref) block. Fields `chromium` and
`firefox` are the launchable [`BrowserType`](@ref)s; `process` is the driver
subprocess and `connection` the protocol connection (internal).
"""
struct PlaywrightAPI
    chromium::BrowserType
    firefox::BrowserType
    process::Base.Process
    connection::Connection
end

# --- Docs for the exported channel-owner types ----------------------------
#
# The types themselves are generated (src/generated/channels.jl), which is not
# hand-edited, so the docstrings for the ones callers actually name live here.

@doc """
    Browser

A running browser process, from [`launch`](@ref). Holds
[`BrowserContext`](@ref)s; `close` it to shut the process down. Ask
[`browser_name`](@ref) which engine it is.

```julia
playwright() do pw
    browser = launch(pw.chromium; headless = true)
    try
        page = new_page(browser)
        goto!(page, "https://example.com")
    finally
        close!(browser)
    end
end
```
""" Browser

@doc """
    BrowserContext

An isolated profile inside a [`Browser`](@ref) — its own cookies, storage and
permissions — from [`new_context`](@ref). The unit of isolation between tests,
and the owner of the `:page`, `:console` and `:pageerror` events
([`expect_event`](@ref)). Closing one closes its pages.

```julia
ctx = new_context(browser)
page = new_page(ctx)          # this page's cookies are its own
close!(ctx)                    # …and go away with the context
```
""" BrowserContext

@doc """
    BrowserType

A launchable engine: `pw.chromium` or `pw.firefox` on the handle
[`playwright`](@ref) hands you. Pass it to [`launch`](@ref).

```julia
playwright() do pw
    for bt in (pw.chromium, pw.firefox)     # run a test on both engines
        browser = launch(bt; headless = true)
        # ...
        close!(browser)
    end
end
```
""" BrowserType

@doc """
    Page

One tab. The main thing you drive: [`goto!`](@ref), [`locator`](@ref),
[`evaluate`](@ref), [`screenshot`](@ref). Created by [`new_page`](@ref), and
also what arrives from `expect_event(ctx, :page)` when a popup opens.

Calls on a closed page raise [`TargetClosedError`](@ref).

```julia
page = new_page(browser)
goto!(page, "https://example.com")
expect(locator(page, "h1"); to_have_text = "Example Domain")
```
""" Page

@doc """
    Frame

A document within a [`Page`](@ref) — the main frame, or one per `<iframe>`. Get
at them with [`frames`](@ref), or scope into one with
[`frame_locator`](@ref)/[`content_frame`](@ref). Most page-level calls are
frame-level calls on the main frame.

```julia
for f in frames(page)
    @info url(f)
end
```
""" Frame

@doc """
    ElementHandle

A reference to one specific element in the browser, from
[`element_handle`](@ref) or [`wait_for_selector`](@ref).

A snapshot, unlike a [`Locator`](@ref): it keeps pointing at *that* element and
goes stale when the page re-renders. Prefer a locator unless you need to hold
onto one element. [`dispose!`](@ref) it when done.

```julia
handle = wait_for_selector(page, "#chart")
evaluate(page, "el => el.dataset.ready", handle)
dispose!(handle)
```
""" ElementHandle

@doc """
    JSHandle

A reference to a JavaScript value kept *in the browser*, from
[`evaluate_handle`](@ref) — for values that cannot cross the wire, like a DOM
node or a closure. [`dispose!`](@ref) it when done, or use the do-block form of
`evaluate_handle`, which disposes for you.

```julia
evaluate_handle(page, "() => window.myApp") do handle
    evaluate(page, "app => app.version", handle)
end   # disposed on the way out
```
""" JSHandle

@doc """
    Route

One intercepted request, waiting for you to decide what happens to it.

Handed to a [`route!`](@ref) handler, and settled exactly once with
[`abort!`](@ref), [`continue!`](@ref) or [`fulfill!`](@ref). A route nobody
settles is continued for you with a warning (D6) — never left hanging, because
a hung request surfaces as an unrelated timeout thirty seconds later.

[`request`](@ref) reads what was asked for; [`url`](@ref) is shorthand for its
URL.

```julia
route!(ctx, "**/api/items", route -> fulfill!(route; json = ["a", "b"]))
```
""" Route

@doc """
    Request

One HTTP request the browser made — the object delivered by the `:request`
event and handed to a route handler.

Nearly everything on it is free, because it arrives in the initializer (D10):
[`url`](@ref), [`method`](@ref), [`resource_type`](@ref),
[`is_navigation_request`](@ref), [`headers`](@ref), [`post_data`](@ref) and
[`redirected_from`](@ref). Only [`response`](@ref) and [`raw_headers`](@ref)
go back to the driver, and both say so.

```julia
request -> resource_type(request) == "image"    # a predicate matcher
```
""" Request

@doc """
    Response

What came back for a [`Request`](@ref): [`status`](@ref),
[`status_text`](@ref), [`ok`](@ref), [`headers`](@ref) and the URL it finally
came from, all read from the initializer.

The body is not in the initializer and cannot be — it may still be arriving.
[`body`](@ref), [`text`](@ref) and [`json`](@ref) fetch it, block until it is
complete, and say so in their docstrings.

```julia
resp = goto!(page, url)
@test ok(resp)
@test json(resp)["items"] == [1, 2]
```
""" Response

@doc """
    Artifact

A file the driver is producing — a trace zip from [`stop_tracing!`](@ref) or a
[`video`](@ref) recording. Three verbs: [`path`](@ref) blocks until it is
completely written and says where it is, [`save_as!`](@ref) copies it somewhere
of your choosing, and [`delete_file!`](@ref) removes it.

The distinction worth knowing: the driver knows the eventual path immediately,
but the file is only complete later — a video not until its page or context
closes. `path` is what waits.

```julia
artifact = stop_tracing!(ctx)
save_as!(artifact, "artifacts/trace.zip")   # blocks until fully written
```
""" Artifact
