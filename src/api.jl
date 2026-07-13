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
