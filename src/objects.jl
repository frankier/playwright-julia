# Hand-written companions to the generated channel-owner types.
#
# The protocol object types themselves (Browser, Page, Frame, …) and the
# CHANNEL_TYPES registry now come from src/generated/channels.jl. What stays
# here is what the protocol has no notion of: Locator, which is a client-side
# construct, PlaywrightAPI, which is this package's entry handle, and small
# accessors over channel-owner initializers.

"Name of the browser a `BrowserType` launches: \"chromium\" or \"firefox\"."
browser_name(bt::BrowserType) = bt.initializer["name"]::String

"Main frame backing `page`; page-level actions delegate to it."
main_frame(page::Page) = from_channel(page.connection, page.initializer["mainFrame"])::Frame

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
