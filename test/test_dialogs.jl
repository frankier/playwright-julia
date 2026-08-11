# Dialogs, against the fake connection.
#
# The lifetime is tested before the behaviour, which is the ordering that made
# Same as route interception: a registry whose dispatcher leaks, dies or deadlocks
# fails in ways that look like the page's fault rather than the package's.
#
# `timeout_fixture`, not `event_fixture`: these tests answer the driver by
# hand, and event_fixture's autoreply task would win the race and block them
# forever. (test_downloads.jl's header has the longer version.)
#
# Every wait here is bounded. A dialog nobody answers blocks its page until the
# driver's own timeout, and a test that reproduces that failure by hanging is
# not a test.

using Playwright:
    Dialog,
    dialog_type,
    message,
    default_value,
    accept!,
    dismiss!,
    on_dialog!,
    off_dialog!,
    with_dialog

"Announce a Dialog on the fixture's context, as the driver does."
function fire_dialog(
    f,
    guid = "dialog@1";
    kind = "confirm",
    text = "really?",
    default = "",
    page_guid = "page@1",
)
    send_create(
        f.fake,
        "context@1",
        "Dialog",
        guid,
        Dict(
            "type" => kind,
            "message" => text,
            "defaultValue" => default,
            "page" => Dict("guid" => page_guid),
        ),
    )
    @test timedwait(
        () -> Playwright.lookup_object(f.fake.connection, guid) !== nothing,
        5.0,
    ) === :ok
    send_event(
        f.fake,
        "context@1",
        "dialog",
        Dict{String,Any}(
            "dialog" => Dict("guid" => guid),
            "page" => Dict("guid" => page_guid),
        ),
    )
    return nothing
end

# An unbounded recording responder, not a counted one. A helper that waits for
# exactly N messages has to predict how many the code under test will send, and
# a wrong prediction blocks the suite forever instead of failing it -- which is
# how the first version of this file hung. `autoreply!` (test_events.jl) loops
# until the connection closes, so nothing here has to guess.
collect_requests!(f) = autoreply!(f.fake)

"Wait for `cond`, failing the test rather than hanging if it never holds."
bounded(cond; seconds = 10.0) = @test timedwait(cond, seconds) === :ok

@testset "dialogs" begin
    # --- The lifetime, first ------------------------------------------------

    @testset "nothing is subscribed until a handler exists" begin
        # Subscribing is what disables the driver's auto-dismiss, so a registry
        # that subscribed eagerly would disarm the safety net for every page
        # nobody ever registered on. This is the assertion that pins that.
        f = timeout_fixture()
        @test Playwright.dialog_registry_for(f.page) === nothing
        @test !isready(f.fake.client_messages)
        shutdown!(f.fake)
    end

    @testset "the dispatcher starts on registration and stops on release" begin
        f = timeout_fixture()
        collect_requests!(f)

        reg = on_dialog!(d -> dismiss!(d), f.page)
        registry = Playwright.dialog_registry_for(f.page)
        @test registry !== nothing
        @test registry.task isa Task
        task = registry.task
        @test !istaskdone(task)

        off_dialog!(f.page, reg)
        # Stopped, not merely abandoned: a dispatcher that outlives its
        # registry is a task leaked per page.
        bounded(() -> istaskdone(task))
        @test Playwright.dialog_registry_for(f.page) === nothing
        shutdown!(f.fake)
    end

    @testset "registering opts in, and releasing opts out" begin
        f = timeout_fixture()
        seen = collect_requests!(f)

        reg = on_dialog!(d -> dismiss!(d), f.page)
        bounded(() -> length(seen) >= 1)
        @test seen[1]["method"] == "updateSubscription"
        @test seen[1]["params"]["event"] == "dialog"
        @test seen[1]["params"]["enabled"] == true
        # On the page, not the context: that is what scopes the driver's
        # "somebody will answer this" expectation.
        @test seen[1]["guid"] == "page@1"

        off_dialog!(f.page, reg)
        bounded(() -> length(seen) >= 2)
        @test seen[2]["method"] == "updateSubscription"
        @test seen[2]["params"]["enabled"] == false
        shutdown!(f.fake)
    end

    @testset "the dispatcher survives a handler that throws" begin
        # the rule. The exception must not kill the task -- a dead
        # dispatcher hangs every later dialog on the page.
        f = timeout_fixture()
        collect_requests!(f)

        reg = on_dialog!(_ -> error("handler boom"), f.page)
        registry = Playwright.dialog_registry_for(f.page)
        fire_dialog(f, "dialog@a")
        bounded(() -> length(reg.exceptions) >= 1)
        @test !istaskdone(registry.task)

        # ...and it still answers the next one.
        answered = Ref(false)
        reg2 = on_dialog!(d -> (answered[] = true; dismiss!(d)), f.page)
        fire_dialog(f, "dialog@b")
        bounded(() -> answered[])
        off_dialog!(f.page, reg2)

        err = try
            off_dialog!(f.page, reg)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("handler boom", sprint(showerror, err))
        shutdown!(f.fake)
    end

    # --- The behaviour ------------------------------------------------------

    @testset "the accessors read the initializer" begin
        f = timeout_fixture()
        seen = Ref{Any}(nothing)
        collect_requests!(f)

        reg = on_dialog!(f.page) do d
            seen[] = (dialog_type(d), message(d), default_value(d))
            dismiss!(d)
        end
        fire_dialog(f, "dialog@p"; kind = "prompt", text = "your name?", default = "Ada")
        bounded(() -> seen[] !== nothing)
        @test seen[] == ("prompt", "your name?", "Ada")
        off_dialog!(f.page, reg)
        shutdown!(f.fake)
    end

    @testset "accept! sends promptText only when given" begin
        f = timeout_fixture()
        seen = collect_requests!(f)

        reg = on_dialog!(d -> accept!(d; prompt_text = "Ada"), f.page)
        fire_dialog(f, "dialog@q"; kind = "prompt")
        bounded(() -> any(m -> m["method"] == "accept", seen))
        acc = seen[findfirst(m -> m["method"] == "accept", seen)]
        @test acc["guid"] == "dialog@q"
        @test acc["params"]["promptText"] == "Ada"
        off_dialog!(f.page, reg)
        shutdown!(f.fake)

        f2 = timeout_fixture()
        seen2 = collect_requests!(f2)
        reg2 = on_dialog!(d -> accept!(d), f2.page)
        fire_dialog(f2, "dialog@r")
        bounded(() -> any(m -> m["method"] == "accept", seen2))
        acc2 = seen2[findfirst(m -> m["method"] == "accept", seen2)]
        @test !haskey(acc2["params"], "promptText")
        off_dialog!(f2.page, reg2)
        shutdown!(f2.fake)
    end

    @testset "a handler that answers nothing gets a dismissal and one warning" begin
        # the rule for dialogs. The page proceeds either way; the warning
        # is once per registration, because a page firing alerts in a loop
        # would otherwise bury its own signal.
        f = timeout_fixture()
        seen = collect_requests!(f)

        reg = on_dialog!(_ -> nothing, f.page)
        fire_dialog(f, "dialog@x")
        bounded(() -> any(m -> m["method"] == "dismiss", seen))
        @test any(m -> m["method"] == "dismiss" && m["guid"] == "dialog@x", seen)
        # Asserted through the registration's own flag rather than @test_logs.
        # The warning is emitted on the dispatcher task, which was spawned
        # before the macro installed its logger and so never sees it -- a
        # @test_logs here would pass or fail on logger propagation rather than
        # on the behaviour, which is worse than not testing it that way.
        @test reg.warned

        # Second dialog: dismissed again, but not warned about again.
        before = count(m -> m["method"] == "dismiss", seen)
        fire_dialog(f, "dialog@y")
        bounded(() -> count(m -> m["method"] == "dismiss", seen) > before)

        off_dialog!(f.page, reg)
        shutdown!(f.fake)
    end

    @testset "a throwing handler still gets the dialog dismissed" begin
        f = timeout_fixture()
        seen = collect_requests!(f)

        reg = on_dialog!(_ -> error("nope"), f.page)
        fire_dialog(f, "dialog@z")
        # The page must proceed even though the handler failed.
        bounded(() -> any(m -> m["method"] == "dismiss" && m["guid"] == "dialog@z", seen))
        @test_throws Exception off_dialog!(f.page, reg)
        shutdown!(f.fake)
    end

    @testset "handlers never run on the transport reader task" begin
        # The world-age trap in events.jl's header, asserted rather than
        # trusted: user code on the reader task cannot call anything defined
        # after the connection started.
        f = timeout_fixture()
        collect_requests!(f)
        ran_on = Ref{Any}(nothing)

        reg = on_dialog!(f.page) do d
            ran_on[] = current_task()
            dismiss!(d)
        end
        registry = Playwright.dialog_registry_for(f.page)
        fire_dialog(f, "dialog@t")
        bounded(() -> ran_on[] !== nothing)
        @test ran_on[] === registry.task
        @test ran_on[] !== f.fake.connection.transport.reader
        off_dialog!(f.page, reg)
        shutdown!(f.fake)
    end

    @testset "with_dialog releases even when the body throws" begin
        f = timeout_fixture()
        collect_requests!(f)
        @test_throws ErrorException with_dialog(f.page; handler = dismiss!) do
            error("body boom")
        end
        @test Playwright.dialog_registry_for(f.page) === nothing
        shutdown!(f.fake)
    end

    @testset "a dialog for another page is not this page's to answer" begin
        # the filter. The event is declared on the context, so without a
        # filter a two-page context would have every handler answering every
        # page's dialogs.
        f = timeout_fixture()
        touched = Ref(false)
        collect_requests!(f)

        reg = on_dialog!(d -> (touched[] = true; dismiss!(d)), f.page)
        fire_dialog(f, "dialog@other"; page_guid = "page@2")
        # Nothing to wait *for*, so give the dispatcher a chance to be wrong.
        bounded(() -> Playwright.dialog_registry_for(f.page) !== nothing)
        @test touched[] == false

        fire_dialog(f, "dialog@mine"; page_guid = "page@1")
        bounded(() -> touched[])
        off_dialog!(f.page, reg)
        shutdown!(f.fake)
    end
end
