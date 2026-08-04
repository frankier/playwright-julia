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
Main frame backing `page`; page-level actions delegate to it.

Raises [`TargetClosedError`](@ref) once the page has closed. Every page-level
entry point (`goto`, `title`, `evaluate`, `locator`, `frames`, `frame_locator`,
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
