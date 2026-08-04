# Timeout settings and the resolver every API entry point calls.
#
# The 1.61 protocol has no setDefaultTimeout command — `grep` finds none in
# protocol/spec/. Upstream clients resolve the cascade client-side and put an
# explicit `timeout` on every call, and so does this package. Settings therefore
# live in a side table keyed by guid rather than in the protocol initializer.

"Package default for action timeouts, in milliseconds."
const DEFAULT_TIMEOUT = 30_000

"Package default for navigation timeouts, in milliseconds."
const DEFAULT_NAVIGATION_TIMEOUT = 30_000

# Settings live on the Connection (`conn.timeouts`, guid → NO_TIMEOUTS-shaped
# NamedTuple) rather than in a module-global table. Two reasons: guids are only
# unique within one driver process, so a global table would let a second
# playwright() session inherit the first one's settings; and it puts the
# settings under the connection's own lock, so pruning them from dispose_locked
# needs no second lock and cannot invert a lock order.
const NO_TIMEOUTS = (action = nothing, navigation = nothing)

"Owners that can carry a timeout setting."
const TimeoutOwner = Union{Page,BrowserContext}

# The type of every user-facing `timeout` keyword in src/api/. `nothing` is the
# default and means "resolve the cascade"; an explicit number short-circuits it.
# Spelling it once keeps a call site from quietly reverting to a literal
# default, which is exactly the regression T2b exists to prevent.
const MaybeTimeout = Union{Real,Nothing}

function set_timeout_setting!(owner::TimeoutOwner, key::Symbol, ms::Integer)
    ms < 0 && throw(ArgumentError("timeout must be non-negative, got $ms"))
    conn = owner.connection
    lock(conn.lock) do
        current = get(conn.timeouts, owner.guid, NO_TIMEOUTS)
        conn.timeouts[owner.guid] = merge(current, NamedTuple{(key,)}((Int(ms),)))
    end
    return nothing
end

"""
    set_default_timeout!(target, milliseconds)

Set the default timeout for actions on a [`Page`](@ref) or
[`BrowserContext`](@ref) — clicks, locator queries, waits and assertions.

The setting is inherited: a page with no setting of its own uses its context's.
An explicit `timeout` keyword on a call still wins over both.

```julia
ctx = new_context(browser)
set_default_timeout!(ctx, 2_000)   # a missing element fails in 2 s, not 30
page = new_page(ctx)
set_default_timeout!(page, 5_000)  # ...but this page gets 5 s
```

Milliseconds; `0` means no timeout. See also
[`set_default_navigation_timeout!`](@ref).
"""
set_default_timeout!(target::TimeoutOwner, milliseconds::Integer) =
    set_timeout_setting!(target, :action, milliseconds)

"""
    set_default_navigation_timeout!(target, milliseconds)

Set the default timeout for navigations (`goto` and friends) on a
[`Page`](@ref) or [`BrowserContext`](@ref).

Navigations fall back to the [`set_default_timeout!`](@ref) setting when no
navigation-specific one is in force, so setting only the action default also
shortens navigations rather than leaving them at 30 s.

Milliseconds; `0` means no timeout.
"""
set_default_navigation_timeout!(target::TimeoutOwner, milliseconds::Integer) =
    set_timeout_setting!(target, :navigation, milliseconds)

# Frames sit under their page and pages under their context, so one generic
# walk up the chain covers the whole cascade without any type having to know
# its own position in it.
#
# The chain is *not* quite the __create__ tree: a page's main frame is parented
# to the browser context, so `conn.settings_parents` supplies the missing
# frame → page hop and is consulted first. Without it every `locator(page, …)`
# — which always resolves through the main frame — would silently skip any
# `set_default_timeout!(page, …)`.
function inherited_setting(obj::ChannelOwner, key::Symbol)
    conn = obj.connection
    lock(conn.lock) do
        guid = obj.guid
        while true
            setting = get(conn.timeouts, guid, nothing)
            if setting !== nothing
                value = getfield(setting, key)
                value === nothing || return value
            end
            parent = get(conn.settings_parents, guid, nothing)
            parent === nothing && (parent = get(conn.parents, guid, nothing))
            (parent === nothing || isempty(parent)) && return nothing
            guid = parent
        end
    end
end

"""
    resolve_timeout(target, kwarg) -> Int

Resolve an action timeout: the call's own `timeout` keyword if given, else the
nearest [`set_default_timeout!`](@ref) setting walking up from `target`
(frame → page → context), else [`DEFAULT_TIMEOUT`](@ref).
"""
resolve_timeout(target::ChannelOwner, kwarg::Integer) = Int(kwarg)
resolve_timeout(target::ChannelOwner, ::Nothing) =
    something(inherited_setting(target, :action), DEFAULT_TIMEOUT)

"""
    resolve_navigation_timeout(target, kwarg) -> Int

Resolve a navigation timeout: the call's own keyword, else the nearest
[`set_default_navigation_timeout!`](@ref) setting, else the nearest
[`set_default_timeout!`](@ref) setting, else
[`DEFAULT_NAVIGATION_TIMEOUT`](@ref).
"""
resolve_navigation_timeout(target::ChannelOwner, kwarg::Integer) = Int(kwarg)
resolve_navigation_timeout(target::ChannelOwner, ::Nothing) = something(
    inherited_setting(target, :navigation),
    inherited_setting(target, :action),
    DEFAULT_NAVIGATION_TIMEOUT,
)

# A Locator is a client-side construct, so it resolves through its frame.
resolve_timeout(loc::Locator, kwarg) = resolve_timeout(loc.frame, kwarg)
resolve_navigation_timeout(loc::Locator, kwarg) =
    resolve_navigation_timeout(loc.frame, kwarg)
