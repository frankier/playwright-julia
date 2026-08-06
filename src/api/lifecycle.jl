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
    close!(browser)
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

"The protocol's NameValue array, from the Julia-side Dict callers expect."
name_value_array(d::AbstractDict) =
    [Dict{String,Any}("name" => String(k), "value" => string(v)) for (k, v) in d]

"Coerce a Dict/NamedTuple option into the protocol's string-keyed object."
as_object(x) = Dict{String,Any}(String(k) => v for (k, v) in pairs(x))

# `recordVideo` nests an object inside an object, so its `size` needs the same
# coercion the outer option gets — otherwise a NamedTuple size would go out as
# something the driver cannot read.
record_video_option(::Nothing) = nothing
function record_video_option(opt)
    out = as_object(opt)
    haskey(out, "size") && (out["size"] = as_object(out["size"]))
    return out
end

"""
    launch(browser_type::BrowserType; headless=true, timeout=180_000, kwargs...) -> Browser

Launch a browser instance of `browser_type` (e.g. `pw.chromium`), waiting up
to `timeout` ms for it to start.

`timeout` here is the one timeout in the package that does **not** follow the
[`set_default_timeout!`](@ref) cascade, and deliberately so: it bounds browser
process startup, not an action on a page, and at launch time there is no page
or context in existence to inherit a setting from. It keeps its own 180 s
default because a cold browser start is far slower than any action.

Every option below is optional and is omitted from the protocol message
entirely when left unset, so the driver's own defaults apply:

| Option | Meaning |
|---|---|
| `args` | Extra browser command-line arguments |
| `chromium_sandbox` | Enable Chromium's sandbox (off by default in containers) |
| `env` | Environment for the browser process, as a `Dict` |
| `firefox_user_prefs` | Firefox `about:config` preferences, as a `Dict` |
| `executable_path` | Run this browser binary instead of the bundled one |
| `channel` | Branded channel, e.g. `"chrome"` or `"msedge"` |
| `slow_mo` | Delay each operation by this many ms, for debugging |
| `proxy` | Proxy settings, e.g. `Dict("server" => "http://…")` |
| `downloads_path` | Where to put downloads |

`executable_path` and `channel` are what make `CHROME_BIN`-style provisioning
work on a machine that already has a browser installed.

!!! note "Options for the other engine are ignored, not errors"
    `args` and `chromium_sandbox` mean nothing to Firefox, and
    `firefox_user_prefs` means nothing to Chromium — but passing them anyway is
    harmless. The driver ignores what does not apply to the engine it is
    launching.

    Probed against the 1.61.1 driver on both engines: Firefox launched with
    `args` and `chromium_sandbox`, Chromium launched with `firefox_user_prefs`,
    and one shared option set launched both — every combination started *and*
    rendered a page. So one option set can be shared across engines without
    partitioning it per engine, which is why this package ships no
    `launch_options(engine; …)` filter: there is nothing for it to prevent.

```julia
# Fine on both engines, despite half of it applying to neither.
opts = (; args = ["--disable-dev-shm-usage"], chromium_sandbox = false,
          firefox_user_prefs = Dict("dom.disable_beforeunload" => true))
for bt in (pw.chromium, pw.firefox)
    browser = launch(bt; headless = true, opts...)
    # ...
end
```

```julia
launch(pw.chromium; headless=true, chromium_sandbox=false,
       args=["--disable-dev-shm-usage"])
```
"""
function launch(
    bt::BrowserType;
    headless::Bool = true,
    timeout::Real = 180_000,
    args::Union{AbstractVector,Nothing} = nothing,
    chromium_sandbox::Union{Bool,Nothing} = nothing,
    env::Union{AbstractDict,Nothing} = nothing,
    firefox_user_prefs::Union{AbstractDict,Nothing} = nothing,
    executable_path::Union{AbstractString,Nothing} = nothing,
    channel::Union{AbstractString,Nothing} = nothing,
    slow_mo::Union{Real,Nothing} = nothing,
    proxy::Union{AbstractDict,Nothing} = nothing,
    downloads_path::Union{AbstractString,Nothing} = nothing,
)
    options = (;
        headless,
        timeout,
        args,
        chromiumSandbox = chromium_sandbox,
        env = env === nothing ? nothing : name_value_array(env),
        firefoxUserPrefs = firefox_user_prefs,
        executablePath = executable_path,
        channel,
        slowMo = slow_mo,
        proxy,
        downloadsPath = downloads_path,
    )
    return try
        _browser_type_launch(bt; options...)::Browser
    catch err
        # First-use nicety: if this browser was never installed, install it
        # and retry once instead of surfacing the driver's error.
        (err isa PlaywrightError && occursin("Executable doesn't exist", err.message)) ||
            rethrow()
        @info "Browser $(browser_name(bt)) is not installed yet; installing it now"
        run(driver_cmd("install", browser_name(bt)))
        _browser_type_launch(bt; options...)::Browser
    end
end

"""
    new_context(browser::Browser; kwargs...) -> BrowserContext

Open a fresh browser context — an isolated profile with its own cookies,
storage and permissions, and the unit of isolation between tests. Contexts are
cheap; a new browser is not.

Options (all optional, omitted from the wire when unset): `viewport` (a `Dict`
or `NamedTuple` of `width`/`height`), `user_agent`, `locale`, `timezone_id`,
`color_scheme`, `device_scale_factor`, `is_mobile`, `has_touch`, `offline`,
`permissions`, `base_url`, `extra_http_headers` (a `Dict`),
`ignore_https_errors`, `java_script_enabled`, `record_video`.

```julia
ctx = new_context(browser; viewport=(width=1280, height=720))
page = new_page(ctx)
close!(ctx)
```

`record_video` takes a `dir` and an optional `size`, and recording is
context-scoped because that is what the protocol offers — there is no per-page
switch. See [`video`](@ref) for reading the result, and note that the file is
not complete until the page or context closes:

```julia
ctx = new_context(browser; record_video = (dir = "artifacts/video",))
```
"""
function new_context(
    browser::Browser;
    viewport = nothing,
    record_video = nothing,
    user_agent::Union{AbstractString,Nothing} = nothing,
    locale::Union{AbstractString,Nothing} = nothing,
    timezone_id::Union{AbstractString,Nothing} = nothing,
    color_scheme::Union{AbstractString,Nothing} = nothing,
    device_scale_factor::Union{Real,Nothing} = nothing,
    is_mobile::Union{Bool,Nothing} = nothing,
    has_touch::Union{Bool,Nothing} = nothing,
    offline::Union{Bool,Nothing} = nothing,
    permissions::Union{AbstractVector,Nothing} = nothing,
    base_url::Union{AbstractString,Nothing} = nothing,
    extra_http_headers::Union{AbstractDict,Nothing} = nothing,
    ignore_https_errors::Union{Bool,Nothing} = nothing,
    java_script_enabled::Union{Bool,Nothing} = nothing,
)
    return _browser_new_context(
        browser;
        viewport = viewport === nothing ? nothing : as_object(viewport),
        recordVideo = record_video_option(record_video),
        userAgent = user_agent,
        locale,
        timezoneId = timezone_id,
        colorScheme = color_scheme,
        deviceScaleFactor = device_scale_factor,
        isMobile = is_mobile,
        hasTouch = has_touch,
        offline,
        permissions,
        baseURL = base_url,
        extraHTTPHeaders = extra_http_headers === nothing ? nothing :
                           name_value_array(extra_http_headers),
        ignoreHTTPSErrors = ignore_https_errors,
        javaScriptEnabled = java_script_enabled,
    )::BrowserContext
end

# Pages opened by new_page(::Browser) own the context created for them, so
# close!(page) can tear it down (D7). A Page is a generated struct with a fixed
# field layout, so the association lives here rather than on the object.
const IMPLICIT_CONTEXTS = Dict{String,BrowserContext}()
const IMPLICIT_CONTEXTS_LOCK = ReentrantLock()

"""
    new_page(browser::Browser) -> Page
    new_page(context::BrowserContext) -> Page

Open a new page. Given a [`Browser`](@ref), a fresh context is created to hold
it and is closed again by `close!(page)` — so a per-test page leaks nothing.
Given a [`BrowserContext`](@ref), the page joins that context and its lifetime
is yours.

```julia
page = new_page(browser)     # its own context, cleaned up with the page
goto(page, url)
close!(page)                  # …and the implicit context goes too

ctx = new_context(browser)   # or share one context between pages
a, b = new_page(ctx), new_page(ctx)
close!(ctx)                   # closes both
```

For a page that also collects screenshots and traces when a test fails, use
[`with_page`](@ref) instead of doing the bookkeeping by hand.
"""
function new_page(browser::Browser)
    context = new_context(browser)
    page = new_page(context)
    lock(IMPLICIT_CONTEXTS_LOCK) do
        IMPLICIT_CONTEXTS[page.guid] = context
    end
    return page
end

new_page(context::BrowserContext) = _browser_context_new_page(context)::Page

"""
    contexts(browser::Browser) -> Vector{BrowserContext}

The browser's currently open [`BrowserContext`](@ref)s. Shrinks as contexts are
closed, including the implicit ones [`new_page`](@ref) creates.

```julia
length(contexts(browser))   # 0 on a browser that has just launched
```

Useful mostly as a leak check at the end of a suite: a count that only ever
grows means something is not being closed.
"""
contexts(browser::Browser) = live_children(browser, BrowserContext)

"""
    pages(context::BrowserContext) -> Vector{Page}

The context's currently open [`Page`](@ref)s, in no guaranteed order. Shrinks
as pages close.

```julia
page = new_page(ctx)
length(pages(ctx))   # 1
```

A popup opened by the page under test shows up here once it exists — though
`expect_event(ctx, :page)` is the way to *wait* for one; see
[`expect_event`](@ref).
"""
pages(context::BrowserContext) = live_children(context, Page)

"""
Children of `parent` of type `T` that are still alive. Disposed objects leave
a stale guid behind in the parent's child list, so liveness is decided by the
object registry rather than by that list.
"""
function live_children(parent::ChannelOwner, ::Type{T}) where {T}
    conn = parent.connection
    return lock(conn.lock) do
        T[
            conn.objects[guid] for guid in get(conn.children, parent.guid, String[]) if
            get(conn.objects, guid, nothing) isa T
        ]
    end
end

"""
    close!(page::Page)
    close!(context::BrowserContext)
    close!(browser::Browser)

Close a page, a context and all of its pages, or a browser and everything in
it. This is Playwright's `close`; the bang is D1's rule — it changes what the
page can observe, in the most final way available.

Unlike the `close` it replaces, this extends nothing in `Base`, so it is an
ordinary export: `names(Playwright)` sees it and `checkdocs` covers it.
`close(sub)` on a `Subscription` keeps its old spelling, because detaching a
client-side buffer changes nothing the browser can see. Closing a page that `new_page(browser)` created also closes the context
that was created to hold it.
"""
function close!(page::Page)
    context = lock(IMPLICIT_CONTEXTS_LOCK) do
        pop!(IMPLICIT_CONTEXTS, page.guid, nothing)
    end
    # Closing the context closes the page with it.
    context === nothing ? _page_close(page) : close!(context)
    return nothing
end

close!(context::BrowserContext) = _browser_context_close(context)

function close!(browser::Browser)
    _browser_close(browser)
    forget_dead_implicit_contexts(browser.connection)
    return nothing
end

# close!(browser) disposes contexts without going through close!(page), so the
# implicit-context table would otherwise grow for the life of the process.
function forget_dead_implicit_contexts(conn::Connection)
    lock(IMPLICIT_CONTEXTS_LOCK) do
        filter!(IMPLICIT_CONTEXTS) do (_, context)
            context.connection !== conn || lookup_object(conn, context.guid) !== nothing
        end
    end
    return nothing
end
