using Test
using Playwright

# CI splits the smoke suite into one job per engine via PLAYWRIGHT_JL_ENGINE;
# locally the var is unset and all five run. It takes one name, a
# comma-separated list, or nothing (D5) — the middle case being "the two that
# already worked, while I fix the third", which with five engines is the
# difference between a two-minute loop and a twenty-minute one.
#
# Parsed by the package, not here, so that this and examples/common.jl cannot
# disagree about what an engine name is. An unknown name throws before the
# first browser starts, rather than yielding an empty loop that passes by
# testing nothing.
#
# The const is module-level so the smoke files included below can see it —
# `include` evaluates at module scope, not inside the @testset's local scope.
const SMOKE_ENGINES = Playwright.parse_engine_names(get(ENV, "PLAYWRIGHT_JL_ENGINE", ""))

# --- Where did it hang? -----------------------------------------------------
#
# Windows jobs stall inside the test process and print nothing, because the
# whole suite is one top-level @testset and Test writes its report only when
# that testset finishes. A job killed at the CI timeout therefore says only
# "somewhere in thirty files", which is what made the first three attempts at
# this cost an hour each and settle nothing.
#
# So each file announces itself before it runs and reports its duration after,
# unbuffered, and a watchdog turns a hang into a failure that names the file.
# The timings are useful on their own: they are the per-file cost on each
# platform, which nothing else here measures.
const CURRENT_FILE = Ref("<none>")
const FILE_STARTED = Ref(time())
# Per file, not for the run. The longest smoke file takes a couple of minutes
# on a cold Windows runner, so ten is generous; set 0 to disable.
const FILE_TIMEOUT = parse(Float64, get(ENV, "PLAYWRIGHT_JL_FILE_TIMEOUT", "600"))

function include_traced(file)
    CURRENT_FILE[] = file
    FILE_STARTED[] = time()
    println(stderr, ">>> $file")
    flush(stderr)
    # joinpath(@__DIR__) rather than a bare relative path: `include` inside a
    # function still resolves against the including file, but only by way of a
    # task-local, and this is not the place to depend on that. Evaluation is in
    # this module either way, which is what the files below need.
    include(joinpath(@__DIR__, file))
    println(stderr, "<<< $file  $(round(time() - FILE_STARTED[]; digits = 1))s")
    flush(stderr)
end

# The task running the suite, captured so the watchdog can read its state from
# outside. A Timer callback runs on its own task, so nothing it asks about
# itself describes the hang.
const MAIN_TASK = current_task()

# The nested @testset descriptions the main task is currently inside, outermost
# first. Test keeps that stack in task-local storage, and a Task's storage is an
# ordinary IdDict reachable from another task -- which is the only way to get a
# testset name out of a run that will never reach its own report. Internals, so
# it is wrapped: a change to the key must degrade the watchdog, not replace the
# diagnosis with an exception inside the diagnostic.
function testset_stack()
    try
        store = MAIN_TASK.storage
        store === nothing && return String[]
        stack = get(store, :__BASETESTNEXT__, nothing)
        stack === nothing && return String[]
        return [string(getfield(ts, :description)) for ts in stack]
    catch err
        return ["<unavailable: $err>"]
    end
end

# A Timer, deliberately: it runs on the event loop, so it fires while the main
# task sits in a `take!` that will never be satisfied -- the shape every stalled
# Windows job has. If it does *not* fire, the process is blocked somewhere that
# never yields to libuv, which is itself the answer to a different question.
watchdog =
    FILE_TIMEOUT <= 0 ? nothing :
    Timer(30.0; interval = 30.0) do _
        elapsed = time() - FILE_STARTED[]
        elapsed > FILE_TIMEOUT || return
        println(
            stderr,
            "!!! WATCHDOG: $(CURRENT_FILE[]) has been running for " *
            "$(round(Int, elapsed))s (limit $(round(Int, FILE_TIMEOUT))s).",
        )
        println(stderr, "!!! testset: " * join(testset_stack(), " > "))
        flush(stderr)
        # Every task's backtrace, which for a deadlock is the whole answer: the
        # line the suite is waiting on and the line whoever should wake it is
        # waiting on, together. Undocumented, and worth it -- the alternative is
        # another hour-long run that says no more than the last one did.
        try
            @ccall jl_print_task_backtraces(0::Cint)::Cvoid
        catch err
            println(stderr, "!!! could not dump task backtraces: $err")
        end
        flush(stderr)
        exit(1)
    end

# Deadlines for every take!/fetch in the suite. Not a test file and not inside
# the testset: the files below call these at load, so they have to exist first.
include(joinpath(@__DIR__, "waits.jl"))

@testset "Playwright.jl" begin
    @testset "package loads" begin
        @test Playwright isa Module
        @test isdefined(Playwright, :playwright)
    end

    include_traced("test_project.jl")
    include_traced("test_exports.jl")
    include_traced("test_errors.jl")
    include_traced("test_driver.jl")
    include_traced("test_protocol_spec.jl")
    include_traced("test_codegen.jl")
    include_traced("test_serializers.jl")
    include_traced("test_transport.jl")
    include_traced("test_connection.jl")
    include_traced("test_timeouts.jl")
    include_traced("test_globs.jl")
    include_traced("test_network.jl")
    include_traced("test_events.jl")
    include_traced("test_routing.jl")
    # After test_routing.jl: HAR replay is a route! handler, so its tests
    # reuse send_route and last_patterns from there.
    include_traced("test_har.jl")
    # After test_har.jl: reuses its har_fixture, which is the only fake-driver
    # fixture that registers a LocalUtils and a Tracing channel.
    include_traced("test_websockets.jl")
    include_traced("test_waiting.jl")
    # After test_waiting.jl: these use its waiting_request helper, as well as
    # timeout_fixture (test_timeouts.jl) and send_event (test_events.jl).
    include_traced("test_downloads.jl")
    include_traced("test_dialogs.jl")
    include_traced("test_uploads.jl")
    include_traced("test_locator_eval.jl")
    include_traced("test_closed.jl")
    include_traced("test_expect.jl")
    include_traced("test_metadata.jl")
    include_traced("test_engines.jl")

    if get(ENV, "PLAYWRIGHT_JL_SMOKE", "") == "1"
        include_traced("test_smoke.jl")
        include_traced("test_fixtures.jl")
        include_traced("test_evaluate.jl")
        include_traced("test_frames.jl")
        include_traced("test_parity.jl")
        include_traced("test_smoke_network.jl")
        # After test_smoke_network.jl: reuses its with_browser, within_deadline
        # and todo_texts helpers, and its network.html fixture page.
        include_traced("test_smoke_har.jl")
        # After test_smoke.jl and test_smoke_network.jl: uses the former's
        # fixture server and playwright_browser_pids, the latter's
        # within_deadline.
        include_traced("test_smoke_persistent.jl")
        # After test_smoke_network.jl: reuses within_deadline and with_browser.
        # Its server is its own — proving mock mode never contacts the real one
        # needs a server that counts connections.
        include_traced("test_smoke_websockets.jl")
        include_traced("test_smoke_files.jl")
    else
        @info "Skipping smoke tests (set PLAYWRIGHT_JL_SMOKE=1 to enable)"
    end

    # The artifact tests are mostly hermetic, so this always runs —
    # but the few legs that need a real browser are gated inside the file and
    # use test_smoke.jl's fixture server, which is why it comes last.
    include_traced("test_artifacts.jl")
    include_traced("test_fixtures_api.jl")
end

watchdog === nothing || close(watchdog)
