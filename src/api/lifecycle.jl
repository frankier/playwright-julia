# Driver and browser lifecycle: starting and stopping Playwright itself,
# launching browsers, opening pages, closing things.

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

# Backstop against leaked drivers: playwright() already guarantees shutdown,
# but a REPL user holding a bare start_playwright() would otherwise leave a
# node process behind when Julia exits.
const LIVE_DRIVERS = Base.Process[]
const LIVE_DRIVERS_LOCK = ReentrantLock()

function kill_leaked_drivers()
    procs = lock(LIVE_DRIVERS_LOCK) do
        drivers = copy(LIVE_DRIVERS)
        empty!(LIVE_DRIVERS)
        drivers
    end
    for proc in procs
        process_exited(proc) || kill(proc)
    end
    return nothing
end

function __init__()
    atexit(kill_leaked_drivers)
    return nothing
end

function track_driver(proc::Base.Process, keep::Bool)
    lock(LIVE_DRIVERS_LOCK) do
        keep ? push!(LIVE_DRIVERS, proc) : filter!(p -> p !== proc, LIVE_DRIVERS)
    end
    return nothing
end

function start_playwright()
    driver_installed() || install_driver()
    proc = open(pipeline(driver_cmd("run-driver"); stderr = stderr), "r+")
    track_driver(proc, true)
    transport = Transport(proc.out, proc.in; on_message = _ -> nothing)
    conn = start!(Connection(transport))
    local root
    try
        # The root object is implicit: it is addressed by the empty guid and is
        # never announced by a __create__ event, so it is constructed rather
        # than looked up.
        root = _root_initialize(
            Root(conn, "Root", "", Dict{String,Any}());
            sdkLanguage = "python",
        )::PlaywrightRoot
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
    track_driver(proc, false)
    return nothing
end

"""
    launch(browser_type::BrowserType; headless=true, timeout=180_000) -> Browser

Launch a browser instance of `browser_type` (e.g. `pw.chromium`), waiting up
to `timeout` ms for it to start.
"""
function launch(bt::BrowserType; headless::Bool = true, timeout::Real = 180_000)
    return try
        _browser_type_launch(bt; headless, timeout)::Browser
    catch err
        # First-use nicety: if this browser was never installed, install it
        # and retry once instead of surfacing the driver's error.
        (err isa PlaywrightError && occursin("Executable doesn't exist", err.message)) ||
            rethrow()
        @info "Browser $(browser_name(bt)) is not installed yet; installing it now"
        run(driver_cmd("install", browser_name(bt)))
        _browser_type_launch(bt; headless, timeout)::Browser
    end
end

"""
    new_page(browser::Browser) -> Page

Open a new page in a fresh browser context.
"""
function new_page(browser::Browser)
    context = _browser_new_context(browser)::BrowserContext
    return _browser_context_new_page(context)::Page
end

"""
    close(page::Page)
    close(browser::Browser)

Close a page, or a browser and all of its pages.
"""
Base.close(page::Page) = _page_close(page)
Base.close(browser::Browser) = _browser_close(browser)
