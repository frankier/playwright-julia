# Dialogs (SPEC-M7.md D12).
#
# Playwright's rule: with no listener registered a dialog is auto-dismissed;
# with one registered it is not, and a dialog nobody answers blocks its page
# until the driver times out.
#
# That rule is mechanical rather than conventional. `dialog` is in page.yml's
# updateSubscription enum, so "a client subscribed" and "the driver now expects
# somebody to answer" are the SAME event on the wire. Any design that
# subscribes speculatively has already disarmed the safety net -- which is why
# this is a registry rather than an expect_event wrapper, and why nothing here
# subscribes until a handler actually exists.
#
# The lifetime is M6's route dispatcher, reused rather than reinvented, and it
# carries the same three decisions:
#
#   * a dialog nobody settles is dismissed, and warned about once per
#     registration (M6 D6)
#   * a handler that throws is collected and rethrown at release, with the
#     dialog still dismissed so the page proceeds (M6 D7)
#   * handlers run on a dispatcher task, never on the transport reader task
#     (M6 D5 -- the world-age trap in events.jl's header)
#
# One wrinkle the routes did not have: the `dialog` event is declared on
# browserContext, not page (browserContext.yml:364), while the *subscription*
# is accepted on either. So a page-scoped registry subscribes to the page's
# context and filters by the dialog's own `page` -- the same split M6 D11 made
# for the network events.

# --- The Dialog wrapper ----------------------------------------------------
#
# `Dialog` is a generated ChannelOwner, so this is accessors over its
# initializer plus the two settle verbs. The type itself is documented here
# rather than in the generated file, which is never hand-edited.

"""
    Dialog

A JavaScript dialog the page opened: `alert`, `confirm`, `prompt`, or the
`beforeunload` prompt.

Read it with [`dialog_type`](@ref), [`message`](@ref) and
[`default_value`](@ref); answer it with [`accept!`](@ref) or
[`dismiss!`](@ref).

```julia
with_dialog(page; handler = d -> accept!(d; prompt_text = "Ada")) do
    click!(locator(page, "#ask-name"))
end
```

!!! warning "A dialog blocks its page until it is answered"
    With no handler registered the driver dismisses dialogs itself and the page
    carries on. Registering one — with [`on_dialog!`](@ref) or
    [`with_dialog`](@ref) — takes that over, and from then until the
    registration is released every dialog on the page is yours to answer. A
    handler that returns without answering gets a dismissal and one warning
    rather than a hung page.

Dialogs arrive through the registry rather than through
[`expect_event`](@ref): subscribing is *what* disables the driver's
auto-dismiss, so an event-shaped API would disarm the safety net simply by
being used. See the [Files, dialogs and uploads](@ref) guide.
"""
Dialog

"""
    dialog_type(d::Dialog) -> String

Which kind of dialog: `"alert"`, `"beforeunload"`, `"confirm"` or `"prompt"`.

Spelled `dialog_type` rather than `type`, which is unusable as a Julia
function name in any script that also uses the word.
"""
dialog_type(d::Dialog) = get(d.initializer, "type", "")::String

"""
    message(d::Dialog) -> String

The text the page asked with — the argument to `alert`, `confirm` or `prompt`.
"""
message(d::Dialog) = get(d.initializer, "message", "")::String

"""
    default_value(d::Dialog) -> String

The pre-filled value of a `prompt`, or `""` for the dialog types that have no
such thing.
"""
default_value(d::Dialog) = get(d.initializer, "defaultValue", "")::String

"""
    accept!(d::Dialog; prompt_text=nothing)

Accept the dialog — OK on a `confirm`, leave on a `beforeunload`, submit on a
`prompt`.

`prompt_text` is the text to submit and is meaningful only for `prompt`; the
dialog's own [`default_value`](@ref) is used when it is omitted.

```julia
with_dialog(page; handler = d -> accept!(d; prompt_text = "Ada")) do
    click!(locator(page, "#ask-name"))
end
```
"""
function accept!(d::Dialog; prompt_text::Union{AbstractString,Nothing} = nothing)
    settle_dialog!(d) do
        _dialog_accept(d; promptText = prompt_text)
    end
    return nothing
end

"""
    dismiss!(d::Dialog)

Dismiss the dialog — Cancel on a `confirm` or `prompt`, stay on a
`beforeunload`. An `alert` has only one button, and dismissing it presses that.
"""
function dismiss!(d::Dialog)
    settle_dialog!(d) do
        _dialog_dismiss(d)
    end
    return nothing
end

# --- Settle tracking -------------------------------------------------------
#
# Same shape as routing.jl's: a guid-keyed marker, so "did the handler answer
# this?" is answerable without asking the driver, and dropped when the dispatch
# ends so it cannot outlive the dialog.

const SETTLED_DIALOGS = Set{String}()
const SETTLED_DIALOGS_LOCK = ReentrantLock()

is_settled(d::Dialog) =
    lock(SETTLED_DIALOGS_LOCK) do
        d.guid in SETTLED_DIALOGS
    end

function settle_dialog!(f::Function, d::Dialog)
    lock(SETTLED_DIALOGS_LOCK) do
        push!(SETTLED_DIALOGS, d.guid)
    end
    return f()
end

forget_dialog!(d::Dialog) =
    lock(SETTLED_DIALOGS_LOCK) do
        delete!(SETTLED_DIALOGS, d.guid)
        nothing
    end

# --- The registry and its dispatcher (the lifetime, written first) ---------

"One `on_dialog!` registration: its handler, what it threw, and whether it is live."
mutable struct DialogRegistration
    handler::Function
    exceptions::Vector{Any}
    warned::Bool
    active::Bool
end

DialogRegistration(handler) = DialogRegistration(handler, Any[], false, true)

"Per-page dialog state: the registrations, the subscription, and the dispatcher."
mutable struct DialogRegistry
    page::Page
    context::BrowserContext
    registrations::Vector{DialogRegistration}
    subscription::Union{Subscription,Nothing}
    task::Union{Task,Nothing}
    lock::ReentrantLock
    # Held for the whole of one dialog's handling, so off_dialog! can wait for
    # an in-flight handler to finish before returning. Re-entrant: a handler
    # that unregisters itself is legal and must not deadlock against itself.
    dispatching::ReentrantLock
end

DialogRegistry(page::Page, ctx::BrowserContext) = DialogRegistry(
    page,
    ctx,
    DialogRegistration[],
    nothing,
    nothing,
    ReentrantLock(),
    ReentrantLock(),
)

const DIALOG_REGISTRIES = Dict{String,DialogRegistry}()
const DIALOG_REGISTRIES_LOCK = ReentrantLock()

dialog_registry_for(page::Page) =
    lock(DIALOG_REGISTRIES_LOCK) do
        get(DIALOG_REGISTRIES, page.guid, nothing)
    end

"""
Start the dispatcher for `registry` if it is not already running.

Spawned on the *first* registration and not before. That is not only about
leaking a task per page: subscribing is what disables the driver's
auto-dismiss, so a registry that subscribed eagerly would disarm the safety net
for pages nobody ever registered a handler on.
"""
function start_dialog_dispatcher!(registry::DialogRegistry)
    registry.task === nothing || return registry.task
    # The event lives on the context; the opt-in goes to the page, which is
    # what scopes the driver's "somebody will answer" expectation.
    sub = subscribe(
        registry.context,
        "dialog",
        (owner, params) -> from_channel(owner.connection, params["dialog"])::Dialog,
        (_owner, params) -> dialog_belongs_to(params, registry.page),
    )
    registry.subscription = sub
    update_subscription(registry.page, "dialog", true)
    registry.task = @async dispatch_dialogs(registry, sub)
    return registry.task
end

"Whether a `dialog` event's payload belongs to `page` (M6 D11's filter)."
function dialog_belongs_to(params, page::Page)
    ref = get(params, "page", nothing)
    ref === nothing && return true      # context-wide dialog: nobody else will take it
    return get(ref, "guid", nothing) == page.guid
end

"""
Stop the dispatcher and wait for it to finish.

Closing the channel wakes it: `take!` on a closed channel raises, which is the
loop's exit. No sentinel, no polling, and above all no `sleep` — R1's tripwire
says a lifetime needing one is the wrong lifetime.
"""
function stop_dialog_dispatcher!(registry::DialogRegistry)
    task = registry.task
    sub = registry.subscription
    registry.task = nothing
    registry.subscription = nothing
    if sub !== nothing
        close(sub)
        close(sub.channel)
        try
            update_subscription(registry.page, "dialog", false)
        catch
            # The page closed first. Nothing is listening either way.
        end
    end
    # The dispatcher never rethrows a handler's exception, so a failure here
    # would be a bug in the dispatcher itself. Surface it.
    task === nothing || wait(task)
    return nothing
end

"""
The dispatcher loop: one per registered page, handlers run sequentially in
arrival order.

Sequential buys three things: deterministic ordering, no interleaving between
one dialog's answer and the next one's handler, and no lock needed inside a
user closure that touches shared state.
"""
function dispatch_dialogs(registry::DialogRegistry, sub::Subscription)
    while true
        dialog = try
            take!(sub.channel)
        catch
            break            # channel closed: stop_dialog_dispatcher! was called
        end
        dialog isa Dialog || continue
        try
            lock(registry.dispatching) do
                handle_dialog(registry, dialog)
            end
        catch e
            # handle_dialog catches everything a handler throws, so reaching
            # here is a bug in the dispatcher. Dying quietly would hang every
            # later dialog on this page — the exact failure this design exists
            # to prevent.
            @error "dialog dispatcher failed; later dialogs on this page will not be answered" exception =
                (e, catch_backtrace())
        end
    end
    return nothing
end

"""
Run the newest matching handler for `dialog`, and guarantee the dialog is
settled whatever happens.

Every path out settles: no live registration, a handler that returned without
answering, a handler that threw. An unanswered dialog is the worst failure
available here — the page stops dead and surfaces as an unrelated timeout.
"""
function handle_dialog(registry::DialogRegistry, dialog::Dialog)
    try
        return handle_dialog_inner(registry, dialog)
    finally
        forget_dialog!(dialog)
    end
end

function handle_dialog_inner(registry::DialogRegistry, dialog::Dialog)
    live = lock(registry.lock) do
        [reg for reg in registry.registrations if reg.active]
    end

    for reg in Iterators.reverse(live)      # newest registration wins
        try
            # invokelatest, and load-bearing: the dispatcher task's world age is
            # fixed when it is spawned at the first registration, so a handler
            # closure defined afterwards is "too new" for it and would raise
            # MethodError instead of running. The symptom would be the worst
            # one available — the second registration silently never fires.
            Base.invokelatest(reg.handler, dialog)
        catch e
            push!(reg.exceptions, e)
            dismiss_default!(dialog)        # the page proceeds regardless
            return nothing
        end

        if !is_settled(dialog)
            warn_unsettled_dialog!(reg)
            dismiss_default!(dialog)
        end
        return nothing
    end

    # Nothing live. Dismiss, matching what the driver would have done had
    # nobody ever subscribed.
    dismiss_default!(dialog)
    return nothing
end

"""
One warning per registration, never one per dialog.

The failure this catches is a handler that is wrong for every dialog. A page
firing an alert in a loop would otherwise bury its own signal.
"""
function warn_unsettled_dialog!(reg::DialogRegistration)
    reg.warned && return nothing
    reg.warned = true
    @warn """
    A dialog handler returned without answering the dialog; it has been
    dismissed. Call accept! or dismiss! on the dialog. This is reported once
    per registration, not once per dialog."""
    return nothing
end

"Dismiss a dialog nobody answered, silently. It may already be gone."
function dismiss_default!(dialog::Dialog)
    is_settled(dialog) && return nothing
    try
        dismiss!(dialog)
    catch
        # The page closed mid-dialog, or the driver already tore it down.
        # Raising here would kill a dispatcher with later dialogs to serve.
    end
    return nothing
end

# --- The public trio -------------------------------------------------------

"""
    on_dialog!(handler, page::Page) -> DialogRegistration

Register `handler` to answer dialogs on `page`, and return the registration so
[`off_dialog!`](@ref) can remove it.

```julia
reg = on_dialog!(page) do d
    dialog_type(d) == "confirm" ? accept!(d) : dismiss!(d)
end
click!(locator(page, "#delete"))
off_dialog!(page, reg)
```

!!! warning "Registering is what disarms the driver's auto-dismiss"
    With no handler registered, the driver dismisses dialogs by itself and the
    page carries on. Registering one takes that over: from here until
    [`off_dialog!`](@ref), **every** dialog on this page is yours to answer.
    A handler that returns without calling [`accept!`](@ref) or
    [`dismiss!`](@ref) gets a dismissal and one warning rather than a hung
    page, but the scoped [`with_dialog`](@ref) is the form that cannot leave a
    registration behind.

Handlers run on a dispatcher task, one per page, sequentially. The newest
registration wins. Whatever a handler throws is collected and rethrown out of
[`off_dialog!`](@ref).
"""
function on_dialog!(handler::Function, page::Page)
    ctx = owning_context(page)
    ctx === nothing && throw(
        ArgumentError(
            "cannot register a dialog handler: this page has no owning " *
            "BrowserContext, which usually means it has already been closed.",
        ),
    )
    registry = lock(DIALOG_REGISTRIES_LOCK) do
        get!(() -> DialogRegistry(page, ctx), DIALOG_REGISTRIES, page.guid)
    end
    reg = DialogRegistration(handler)
    lock(registry.lock) do
        push!(registry.registrations, reg)
    end
    start_dialog_dispatcher!(registry)
    return reg
end

"""
    off_dialog!(page::Page, reg)
    off_dialog!(page::Page)

Remove a dialog registration, or all of them, and rethrow anything the handlers
threw.

Blocks until a dialog currently being handled has been answered, so the call
after this one does not race a handler it thought had finished.
"""
function off_dialog!(page::Page, reg::DialogRegistration)
    registry = dialog_registry_for(page)
    registry === nothing && return nothing
    removed = lock(registry.lock) do
        reg.active = false
        filter!(r -> r !== reg, registry.registrations)
        [reg]
    end
    settle_dialog_in_flight!(registry)
    isempty(lock(() -> registry.registrations, registry.lock)) && retire_dialogs!(registry)
    raise_collected(removed)
    return nothing
end

function off_dialog!(page::Page)
    registry = dialog_registry_for(page)
    registry === nothing && return nothing
    removed = lock(registry.lock) do
        gone = copy(registry.registrations)
        for r in gone
            r.active = false
        end
        empty!(registry.registrations)
        gone
    end
    settle_dialog_in_flight!(registry)
    retire_dialogs!(registry)
    raise_collected(removed)
    return nothing
end

"""
Block until any dialog currently being handled has been answered.

Cheap when nothing is in flight — the lock is uncontended — and bounded by one
handler, because the registration was deactivated before this was called.
Called from the user's task, never the dispatcher's.
"""
function settle_dialog_in_flight!(registry::DialogRegistry)
    current_task() === registry.task && return nothing   # a handler unregistering itself
    lock(registry.dispatching) do
    end
    return nothing
end

"Stop the dispatcher and drop the registry, once nothing is registered."
function retire_dialogs!(registry::DialogRegistry)
    stop_dialog_dispatcher!(registry)
    lock(DIALOG_REGISTRIES_LOCK) do
        if isempty(registry.registrations)
            delete!(DIALOG_REGISTRIES, registry.page.guid)
        end
    end
    return nothing
end

"""
    with_dialog(body, page::Page; handler)

Answer dialogs with `handler` for the duration of `body`, then stop — even when
`body` throws.

```julia
with_dialog(page; handler = accept!) do
    click!(locator(page, "#confirm-delete"))
end
```

The handler is a **keyword** and the triggering action is the do-block. Two
functions in one call with only argument position to tell them apart reads
badly, so the keyword names the unusual one. (This is the opposite arrangement
from [`with_route`](@ref), where the matcher already separates them.)

Prefer this over [`on_dialog!`](@ref)/[`off_dialog!`](@ref): the scoped form
cannot leave a registration behind, and a registration left behind means every
later dialog on the page is yours to answer whether you meant it or not.

Anything `handler` throws surfaces here, after the dialog has been dismissed.
"""
function with_dialog(body::Function, page::Page; handler::Function)
    reg = on_dialog!(handler, page)
    try
        return body()
    finally
        off_dialog!(page, reg)
    end
end
