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
    # `utils` is LocalUtils? in the protocol, so the key can be absent as well
    # as null — get, not indexing. The absent case is answered once, by
    # local_utils, rather than at each of HAR replay's call sites.
    utils = from_channel(
        conn,
        get(root.initializer, "utils", nothing),
    )::Union{LocalUtils,Nothing}
    conn.local_utils = utils
    return PlaywrightAPI(chromium, firefox, proc, conn, utils)
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

# --- Shared option builders ------------------------------------------
#
# `launchPersistentContext` takes LaunchOptions *and* ContextOptions, so a third
# entry point written by hand would be the union of `launch`'s twelve keywords
# and `new_context`'s sixteen, copy-pasted — and three copies of a default drift
# apart. So the defaults and the snake_case → wire-name mapping live here once,
# and all three entry points call these.
#
# `test_connection.jl` pins the exact wire params for every caller, so a change
# here that alters what goes out is a test failure rather than a surprise.

"""
The wire options for a browser launch, from this package's snake_case keywords.

Internal. Every option is omitted from the message entirely when left unset, so
the driver's own defaults apply — an option the caller never mentioned must be
absent, not present-and-null, or the driver applies a different default.
"""
launch_options(;
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
) = (;
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

"""
The wire options for a browser context, from this package's snake_case keywords.

Internal. Three of these are transformed rather than passed through — `viewport`
and `record_video` become protocol objects, `extra_http_headers` a NameValue
array — and `accept_downloads` maps onto an enum whose third value must never be
produced (see `accept_downloads_option`).
"""
context_options(;
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
    accept_downloads::Union{Bool,Nothing} = nothing,
) = (;
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
    # `nothing` omits the parameter rather than mapping to the enum's third
    # value -- see accept_downloads_option, where the reason is a silent timeout
    # rather than a style preference.
    acceptDownloads = accept_downloads_option(accept_downloads),
)

"The keywords each builder accepts, for splitting a caller's kwargs between them."
option_keywords(builder) = Base.kwarg_decl(only(methods(builder)))

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
function launch(bt::BrowserType; kwargs...)
    options = launch_options(; kwargs...)
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
`ignore_https_errors`, `java_script_enabled`, `record_video`,
`accept_downloads`.

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

`accept_downloads` is a convenience rather than boilerplate: **downloads
already work with it unset**, on both engines. Pass `false` to make
the browser refuse them — which does not stop the [`Download`](@ref) arriving,
only makes [`failure`](@ref) non-`nothing`. Leaving it unset omits the
parameter from the wire entirely; see [`Download`](@ref).

To choose where the driver puts downloaded files, pass `downloads_path` to
[`launch`](@ref) — the protocol carries it as a launch option, not a context
one.
"""
new_context(browser::Browser; kwargs...) =
    _browser_new_context(browser; context_options(; kwargs...)...)::BrowserContext

"""
    launch_persistent_context(browser_type, user_data_dir; kwargs...) -> BrowserContext

Launch a browser on the profile directory `user_data_dir` and return its
context, so cookies, `localStorage` and the rest of the profile **survive the
process**.

Every context this package otherwise makes is a fresh incognito profile. That is
the right default and the wrong only option: a suite for anything with a login
has to replay the login every test or reach for `storage_state`, and neither is
what a real browser does.

```julia
ctx = launch_persistent_context(pw.chromium, "/tmp/profile"; headless = true)
# A persistent context arrives with a page already open — use it rather than
# calling new_page, which would open a blank second one.
page = first(pages(ctx))
goto!(page, url)
click!(locator(page, "#accept-cookies"))
close!(ctx)

# Same directory, new process. The cookie is still there.
ctx = launch_persistent_context(pw.chromium, "/tmp/profile"; headless = true)
```

Takes the keywords of [`launch`](@ref) **and** [`new_context`](@ref) together;
see those for what each does.

`user_data_dir` is positional because it is the entire reason the function
exists and there is no sensible default. Playwright allows an empty string,
meaning a temporary profile; this package raises instead, because a *persistent*
context whose profile evaporates is a call nobody meant to make.

!!! note "It comes with a page, and `close!` takes the browser with it"
    `length(pages(ctx)) == 1` immediately after this returns, on both engines.
    That is the one way this function differs from every other context in the
    package. Reach for `first(pages(ctx))`, not [`new_page`](@ref).

    [`close!`](@ref) on the returned context takes the browser down with it —
    the *driver* does that, not this package, verified on both engines. So
    there is no browser handle to hold and nothing extra to close, and a
    `close!` on the browser afterwards would raise rather than be a no-op.
"""
function launch_persistent_context(
    bt::BrowserType,
    user_data_dir::AbstractString;
    kwargs...,
)
    isempty(user_data_dir) && throw(
        ArgumentError(
            "user_data_dir must name a directory. Playwright reads an empty " *
            "string as \"use a temporary profile\", which is the opposite of " *
            "what launch_persistent_context is for — use new_context for a " *
            "profile that need not survive the process.",
        ),
    )

    launch_keys = option_keywords(launch_options)
    context_keys = option_keywords(context_options)
    unknown = setdiff(keys(kwargs), (launch_keys..., context_keys...))
    isempty(unknown) || throw(
        ArgumentError(
            "unknown option$(length(unknown) == 1 ? "" : "s") " *
            "$(join(map(repr, unknown), ", ")) for launch_persistent_context. " *
            "It takes launch's keywords and new_context's together.",
        ),
    )

    split(names) = (; (k => v for (k, v) in kwargs if k in names)...)
    options = merge(
        launch_options(; split(launch_keys)...),
        context_options(; split(context_keys)...),
    )

    result = _browser_type_launch_persistent_context(
        bt;
        userDataDir = String(user_data_dir),
        options...,
    )
    # The Browser comes back too and is deliberately dropped: it has exactly one
    # context, is not independently useful, and the driver closes it with the
    # context anyway (see PERSISTENT_BROWSERS' note).
    return result.context::BrowserContext
end

# PERSISTENT_BROWSERS: deliberately absent.
#
# A persistent context might be expected to need an ownership table, so that
# closing it also closes the browser process behind it. **This driver needs no
# such thing.** On both engines, closing a persistent context already takes the
# browser process with it, disposes the Browser object, and makes an explicit
# close! raise TargetClosedError.
#
# So there is no ownership table and close!(::BrowserContext) is unchanged. The
# claim is not merely assumed either — test_smoke_persistent.jl asserts on the
# *process* that nothing is left behind, so a driver that ever stops
# doing this is a test failure here rather than a leak in the wild.

# Pages opened by new_page(::Browser) own the context created for them, so
# close!(page) can tear it down. A Page is a generated struct with a fixed
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
goto!(page, url)
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
it. This is Playwright's `close`. It takes the bang because it changes what the
page can observe, in the most final way available.

It extends nothing in `Base`, so it is an ordinary export.
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

# Persistent contexts included: the driver closes the browser along with the
# context, so there is nothing extra to do here. See PERSISTENT_BROWSERS' note.
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
