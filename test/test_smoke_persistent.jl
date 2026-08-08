# Persistent contexts against real browsers, both engines. Gated behind
# PLAYWRIGHT_JL_SMOKE=1.
#
# **The second launch is the criterion, not the first** (SC 18). Wrapping
# launchPersistentContext and asserting you got a usable context proves nothing
# about persistence — the whole feature is that the profile outlives the
# process, so the test closes the context, relaunches on the same directory in a
# new browser process, and asserts the state is still there.
#
# Runs after test_smoke_network.jl, whose with_browser and within_deadline
# helpers this file reuses, and test_smoke.jl, whose fixture server and
# playwright_browser_pids it uses.

using Playwright: launch_persistent_context

@testset "smoke: persistent contexts" begin
    with_fixture_server() do base_url
        playwright() do pw
            for engine in ("chromium", "firefox")
                bt = getfield(pw, Symbol(engine))

                @testset "$engine: the profile survives the process" begin
                    profile = mktempdir()

                    # --- First launch: write a cookie and a localStorage key --
                    written = within_deadline("$engine persistent write", 180.0) do
                        ctx = launch_persistent_context(bt, profile; headless = true)
                        try
                            # first(pages(ctx)), not new_page: a persistent
                            # context arrives with a page already open (D9), and
                            # new_page would leave that one blank and in the way.
                            page = first(pages(ctx))
                            goto!(page, "$base_url/index.html")
                            # max-age matters: a cookie with no expiry is a
                            # *session* cookie, and session cookies are supposed
                            # to die with the browser process. Without it this
                            # test fails on both engines and looks like a
                            # persistence bug when it is the cookie spec working
                            # correctly.
                            evaluate(
                                page,
                                """() => {
                                    document.cookie = "m8=survived; path=/; max-age=3600";
                                    localStorage.setItem("m8", "survived");
                                }""",
                            )
                            # Read it back inside this process first, so a
                            # failure after the relaunch is unambiguously about
                            # persistence rather than about the write.
                            evaluate(page, "() => localStorage.getItem('m8')")
                        finally
                            close!(ctx)
                        end
                    end
                    @test written == "survived"

                    # --- Second launch: same directory, new process -----------
                    reopened = within_deadline("$engine persistent reopen", 180.0) do
                        ctx = launch_persistent_context(bt, profile; headless = true)
                        try
                            page = first(pages(ctx))
                            goto!(page, "$base_url/index.html")
                            (
                                storage = evaluate(
                                    page,
                                    "() => localStorage.getItem('m8')",
                                ),
                                cookie = evaluate(page, "() => document.cookie"),
                            )
                        finally
                            close!(ctx)
                        end
                    end

                    @test reopened.storage == "survived"
                    @test occursin("m8=survived", reopened.cookie)
                end

                @testset "$engine: it arrives with exactly one page" begin
                    # Asserted so that a driver change to this behaviour is
                    # caught here rather than in a user's confusing blank second
                    # page. It is the one way a persistent context differs from
                    # every other context in this package.
                    profile = mktempdir()
                    count_and_second = within_deadline("$engine persistent pages", 180.0) do
                        ctx = launch_persistent_context(bt, profile; headless = true)
                        try
                            before = length(pages(ctx))
                            new_page(ctx)
                            (before, length(pages(ctx)))
                        finally
                            close!(ctx)
                        end
                    end

                    @test count_and_second[1] == 1
                    # ...and new_page really does open a *second* one, which is
                    # why the docstring points at first(pages(ctx)).
                    @test count_and_second[2] == 2
                end

                @testset "$engine: close! leaves no browser process" begin
                    # The process-level half of SC 20. T15 asserted the close on
                    # the wire; this asserts nothing is actually left running,
                    # which is the claim that matters and the one the wire
                    # assertion cannot make.
                    profile = mktempdir()
                    before = length(playwright_browser_pids())

                    within_deadline("$engine persistent process", 180.0) do
                        ctx = launch_persistent_context(bt, profile; headless = true)
                        goto!(first(pages(ctx)), "$base_url/index.html")
                        close!(ctx)
                    end

                    # The process exits asynchronously, so this waits for the
                    # count to come back rather than reading it once. Failing
                    # rather than hanging, and never a bare sleep.
                    settled = timedwait(30.0) do
                        length(playwright_browser_pids()) <= before
                    end === :ok
                    @test settled
                end
            end
        end
    end
end
