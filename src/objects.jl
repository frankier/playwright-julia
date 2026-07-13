# Concrete channel-owner types for the protocol objects milestone 1 touches,
# plus the client-side Locator (which is not a protocol object — it lazily
# holds a selector and resolves inside the browser on every action).

mutable struct PlaywrightRoot <: ChannelOwner
    @channel_owner_fields
end

mutable struct BrowserType <: ChannelOwner
    @channel_owner_fields
end

mutable struct Browser <: ChannelOwner
    @channel_owner_fields
end

mutable struct BrowserContext <: ChannelOwner
    @channel_owner_fields
end

mutable struct Page <: ChannelOwner
    @channel_owner_fields
end

mutable struct Frame <: ChannelOwner
    @channel_owner_fields
end

mutable struct Response <: ChannelOwner
    @channel_owner_fields
end

mutable struct Request <: ChannelOwner
    @channel_owner_fields
end

CHANNEL_TYPES["Playwright"] = PlaywrightRoot
CHANNEL_TYPES["BrowserType"] = BrowserType
CHANNEL_TYPES["Browser"] = Browser
CHANNEL_TYPES["BrowserContext"] = BrowserContext
CHANNEL_TYPES["Page"] = Page
CHANNEL_TYPES["Frame"] = Frame
CHANNEL_TYPES["Response"] = Response
CHANNEL_TYPES["Request"] = Request

"Name of the browser a `BrowserType` launches: \"chromium\" or \"firefox\"."
browser_name(bt::BrowserType) = bt.initializer["name"]::String

"Main frame backing `page`; page-level actions delegate to it."
main_frame(page::Page) = from_channel(page.connection, page.initializer["mainFrame"])::Frame

"""
    Locator

Lazy handle for `selector` inside a frame. Holds no element reference —
every action re-resolves the selector in the browser, Playwright-style.
Created with [`locator`](@ref).
"""
struct Locator
    frame::Frame
    selector::String
end

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
