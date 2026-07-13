# User-facing sync API. No wire-protocol details beyond building params
# Dicts and resolving channel references.

"""
    playwright(f) -> result of `f`

Start the Playwright driver, call `f(pw)` with a [`PlaywrightAPI`](@ref)
(fields `chromium`, `firefox`), and guarantee driver shutdown when the block
exits — normally or by exception. Installs the driver on first use.

```julia
playwright() do pw
    browser = launch(pw.chromium)
    # ...
    close(browser)
end
```
"""
function playwright(f::Function)
    pw = start_playwright()
    try
        return f(pw)
    finally
        shutdown(pw)
    end
end

function start_playwright()
    driver_installed() || install_driver()
    proc = open(pipeline(driver_cmd("run-driver"); stderr = stderr), "r+")
    transport = Transport(proc.out, proc.in; on_message = _ -> nothing)
    conn = start!(Connection(transport))
    local root
    try
        result = send_message(conn, "", "initialize",
                              Dict{String,Any}("sdkLanguage" => "python"))
        root = from_channel(conn, result["playwright"])::PlaywrightRoot
    catch
        close(conn)
        kill_driver(proc)
        rethrow()
    end
    chromium = from_channel(conn, root.initializer["chromium"])::BrowserType
    firefox = from_channel(conn, root.initializer["firefox"])::BrowserType
    return PlaywrightAPI(chromium, firefox, proc, conn)
end

function shutdown(pw::PlaywrightAPI)
    close(pw.connection)   # closes the driver's stdio; run-driver exits on EOF
    kill_driver(pw.process)
    return nothing
end

function kill_driver(proc::Base.Process)
    if timedwait(() -> process_exited(proc), 5.0) !== :ok
        kill(proc)
        wait(proc)
    end
    return nothing
end

"""
    launch(browser_type::BrowserType; headless=true, timeout=180_000) -> Browser

Launch a browser instance of `browser_type` (e.g. `pw.chromium`), waiting up
to `timeout` ms for it to start.
"""
function launch(bt::BrowserType; headless::Bool = true, timeout::Real = 180_000)
    result = send_message(bt, "launch",
                          Dict{String,Any}("headless" => headless,
                                           "timeout" => timeout))
    return from_channel(bt.connection, result["browser"])::Browser
end

"""
    new_page(browser::Browser) -> Page

Open a new page in a fresh browser context.
"""
function new_page(browser::Browser)
    ctx_result = send_message(browser, "newContext", Dict{String,Any}())
    context = from_channel(browser.connection, ctx_result["context"])::BrowserContext
    page_result = send_message(context, "newPage", Dict{String,Any}())
    return from_channel(browser.connection, page_result["page"])::Page
end

"""
    goto(page::Page, url; timeout=30_000, wait_until="load") -> Union{Response,Nothing}

Navigate `page` to `url` and wait for the navigation to finish. `wait_until`
is one of `"load"`, `"domcontentloaded"`, `"networkidle"` or `"commit"`.
"""
function goto(page::Page, url::AbstractString;
              timeout::Real = 30_000, wait_until::AbstractString = "load")
    params = Dict{String,Any}("url" => url, "timeout" => timeout,
                              "waitUntil" => wait_until)
    result = send_message(main_frame(page), "goto", params)
    return from_channel(page.connection, get(result, "response", nothing))
end

"""
    title(page::Page) -> String

Title of the document currently loaded in `page`.
"""
title(page::Page) = send_message(main_frame(page), "title", Dict{String,Any}())["value"]

"""
    close(page::Page)
    close(browser::Browser)

Close a page, or a browser and all of its pages.
"""
Base.close(page::Page) = (send_message(page, "close", Dict{String,Any}()); nothing)
Base.close(browser::Browser) = (send_message(browser, "close", Dict{String,Any}()); nothing)
