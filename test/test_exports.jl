# The package's public surface, pinned.
#
# This exists to fence refactors: splitting src/api.jl into src/api/* (T4) must
# not move, drop or accidentally add a single exported name. When the API grows
# deliberately, add the name here in the same commit — the diff is then a
# visible record of a public-surface change rather than a silent one.

@testset "exports" begin
    expected = [
        :AssertionFailure,
        :ConsoleMessage,
        :DriverError,
        :PageError,
        :Playwright,        # the module itself
        :PlaywrightError,
        :TargetClosedError,
        :TimeoutError,
        :clear_console_messages!,
        :clear_page_errors!,
        # M6 T1 (D3): the renames that could not take the obvious bang, because
        # `Base.fill!` and `Base.delete!` are exported and would be ambiguous
        # rather than extended. These are first-class exports for the first
        # time, so `checkdocs = :exports` now covers them.
        :set_value!,
        :close!,
        :set_default_strict!,
        :set_default_timeout!,
        :set_default_navigation_timeout!,
        # T7: locator ergonomics
        :evaluate_all,
        :element_handle,
        :frame,
        :selector,
        :is_strict,
        # T10: the channel-owner types callers name
        :Browser,
        :BrowserContext,
        :BrowserType,
        :Page,
        :Frame,
        :Locator,
        :ElementHandle,
        :JSHandle,
        # T8: engine metadata
        :browser_name,
        # T6: retrying assertions
        :expect,
        :Not,
        :retry_until,
        # T5: driver-side waiting
        :wait_for_selector,
        :wait_for_function,
        # T4: the event surface
        :EventStream,
        :expect_event,
        :wait_for_event,
        :with_events,
        :next_event,
        :pending_events,
        :click!,
        :console_messages,
        :dispose!,
        :eval_on_selector,
        :eval_on_selector_all,
        :evaluate,
        :evaluate_handle,
        :content_frame,
        :contexts,
        :dispatch_event!,
        :frame_locator,
        :frames,
        :get_attribute,
        :goto!,
        :inner_html,
        :inner_text,
        :input_value,
        :is_checked,
        :is_enabled,
        :is_visible,
        :install,
        :launch,
        :locator,
        # M6 T8: the glob dialect, exported because a user debugging a route
        # needs to be able to ask what their glob actually matches.
        :glob_to_regex,
        # M6 T9: Request and Response (D10)
        :Request,
        :Response,
        :headers,
        :headers_array,
        :raw_headers,
        :resource_type,
        :is_navigation_request,
        :redirected_from,
        :post_data,
        :post_data_string,
        :request,
        :response,
        :status,
        :status_text,
        :ok,
        :body,
        :text,
        :json,
        :method,
        :RequestFailure,
        :error_text,
        :APIResponse,
        :fetch_uid,
        :expect_request,
        :expect_response,
        # M6 T10: route interception (D5–D9)
        :Route,
        :RouteRegistration,
        :route!,
        :unroute!,
        :unroute_all!,
        :with_route,
        :abort!,
        :continue!,
        :fulfill!,
        :frame_name,
        :new_context,
        :new_page,
        :nth,
        :owner_frame,
        :page_errors,
        :pages,
        :parent_frame,
        :playwright,
        # M4 T7/T4: artifact capture and the Artifact surface
        :pdf,
        :pdf_bytes,
        :save_as!,
        :path,
        :delete_file!,
        # M4 T5: tracing
        :start_tracing!,
        :stop_tracing!,
        :with_tracing,
        # M4 T6: video
        :video,
        :Artifact,
        # M4 T9: the with_page fixture
        :with_page,
        :report_diagnostics,
        # M7 T14: dialogs (D12)
        :Dialog,
        :dialog_type,
        :message,
        :default_value,
        :accept!,
        :dismiss!,
        :on_dialog!,
        :off_dialog!,
        :with_dialog,
        # M7 T12: downloads (D10, D11)
        :Download,
        :expect_download,
        :suggested_filename,
        :artifact,
        :cancel!,
        :failure,
        :screenshot,
        :screenshot_bytes,
        :text_content,
        :title,
        :url,
    ]
    @test sort(names(Playwright)) == sort(expected)

    # Every exported name must actually resolve — an export with no definition
    # behind it only fails at the call site.
    for name in expected
        @test isdefined(Playwright, name)
    end

    # D14: `Playwright.fetch` is deliberately NOT exported — Base.fetch and
    # Distributed.fetch both exist, and exporting this name would make `using
    # Playwright` alongside either of them ambiguous. The cost is that
    # `checkdocs = :exports` cannot see its docstring, which is gap 1's shape
    # arrived at on purpose this time. So the gate the export list would have
    # given is replaced by this test rather than dropped.
    @testset "Playwright.fetch is unexported but documented (D14)" begin
        @test !(:fetch in names(Playwright))
        @test isdefined(Playwright, :fetch)
        documented = Base.Docs.meta(Playwright)
        @test haskey(documented, Base.Docs.Binding(Playwright, :fetch))
    end

    # ...and every one carries documentation. The generated channel types are
    # the trap here: they are defined in a file that is not hand-edited, so
    # their docstrings live in src/objects.jl and are easy to forget when a
    # new one joins the public surface.
    @testset "every export is documented" begin
        # Read the module's own docs table rather than calling `Base.Docs.doc`,
        # which needs the REPL stdlib and so is not available under Pkg.test.
        documented = Base.Docs.meta(Playwright)
        for name in expected
            name === :Playwright && continue   # the module's own docstring
            @test haskey(documented, Base.Docs.Binding(Playwright, name))
        end
    end
end

# --- Part A's two safety nets (M6 T5) --------------------------------------
#
# The renames in SPEC-M6 D1–D3 are mechanical, and mechanical changes are
# exactly the ones that regress quietly. These two testsets are what stop that:
# the first guards the D3 trap, the second guards the substitution being total.

@testset "using Playwright shadows nothing in Base" begin
    # D3's trap, made permanent. `fill!` and `delete!` are exported by Base, so
    # a Playwright export of the same name would not extend Base — it would
    # make both ambiguous and break `fill!` on arrays for anyone who writes
    # `using Playwright`. That is why the renames are `set_value!` and
    # `delete_file!`. If either ever comes back as the obvious spelling, the
    # identity assertions below fail before any user sees an UndefVarError.
    #
    # This file is included after `using Playwright` in runtests.jl, so these
    # names resolve here exactly as they would in a user's script.

    @test fill! === Base.fill!
    @test delete! === Base.delete!
    @test close === Base.close
    @test count === Base.count
    @test first === Base.first

    # ...and they still do what Base does, on ordinary Julia data.
    @test fill!([1, 2, 3], 0) == [0, 0, 0]

    d = Dict(:a => 1, :b => 2)
    @test delete!(d, :a) === d
    @test !haskey(d, :a)

    io = IOBuffer()
    write(io, "hello")
    close(io)
    @test !isopen(io)

    @test count(isodd, [1, 2, 3]) == 2
    @test first([10, 20, 30]) == 10

    # `count` and `first` are extended for Locator and so are the same function
    # objects as Base's — which is the point of D3's "these keep extending
    # Base" half. Extending is fine; exporting a second binding is not.
    @test Locator in [
        m.sig.parameters[2] for
        m in methods(count) if m.module === Playwright && length(m.sig.parameters) == 2
    ]
end

@testset "no old spelling survives anywhere (SC A4)" begin
    # SPEC-M6 D4: the claim that Part A is complete is a grep, not a habit.
    # Each old name is searched for *as a call*, across every hand-written
    # source in the repo.
    root = dirname(@__DIR__)

    # Hand-written sources only. src/generated/ is codegen output whose wire
    # names (`_frame_goto`, `_page_clear_console_messages`) legitimately keep
    # Playwright's spelling, and docs/build/ is a build artifact.
    function hand_written_files()
        paths = String[joinpath(root, "README.md")]
        # "docs" and not "docs/src": docs/bonnie-parity.md sits directly in
        # docs/ and escaped Part A's rename entirely because the first version
        # of this walk stopped at docs/src. A grep that does not cover a file
        # is indistinguishable from a file with nothing to find.
        for dir in ("src", "test", "docs", "examples")
            for (base, _, names) in walkdir(joinpath(root, dir))
                occursin(joinpath("src", "generated"), base) && continue
                occursin(joinpath("docs", "build"), base) && continue
                occursin(joinpath("docs", "src", "examples"), base) && continue
                for n in names
                    endswith(n, ".jl") || endswith(n, ".md") || continue
                    push!(paths, joinpath(base, n))
                end
            end
        end
        return paths
    end

    files = hand_written_files()
    @test length(files) > 30      # the walk found something, i.e. it is not vacuous

    # A leading `.` means a JavaScript method call inside an `evaluate` string
    # — `document.getElementById("x").click()` is not this package's `click`,
    # and rewriting it would break only inside the browser. A leading word
    # character means a generated channel function. A leading `$` means a
    # variable interpolated into a string: `"function $name("` in
    # test_codegen.jl builds the name of a *generated* function and has nothing
    # to do with the export — the first version of this walk flagged it, which
    # is a false positive rather than a survivor.
    old_call(name) = Regex("(?<![.\\w\$])" * name * "\\(")

    renamed = [
        "goto" => "goto!",
        "click" => "click!",
        "fill" => "set_value!",
        "delete" => "delete_file!",
        "dispose" => "dispose!",
        "save_as" => "save_as!",
        "start_tracing" => "start_tracing!",
        "stop_tracing" => "stop_tracing!",
        "clear_console_messages" => "clear_console_messages!",
        "clear_page_errors" => "clear_page_errors!",
        "dispatch_event" => "dispatch_event!",
        # M7 D4: `name` was the package's single worst export -- a word so
        # generic that `using Playwright` shadowed it in any script that had
        # its own. `frame_name` says which name it means.
        "name" => "frame_name",
    ]

    for (old, new) in renamed
        pattern = old_call(old)
        offenders = String[]
        for path in files
            for (i, line) in enumerate(eachline(path))
                occursin(pattern, line) &&
                    push!(offenders, relpath(path, root) * ":" * string(i))
            end
        end
        # The message names the replacement, so a failure tells you the fix.
        @test isempty(offenders) ||
              error("`$old(` survives (should be `$new`): " * join(offenders, ", "))
    end

    # `close` cannot join that list: `close(sub)`, `close(conn)`, `close(io)`
    # and `close(server)` are all still correct — only the three channel-owner
    # methods were renamed. So it is checked by what it is applied to.
    close_offenders = String[]
    for path in files
        for (i, line) in enumerate(eachline(path))
            occursin(r"(?<![.\w])close\((browser|page|ctx|context)\)", line) &&
                push!(close_offenders, relpath(path, root) * ":" * string(i))
        end
    end
    @test isempty(close_offenders) || error(
        "`close(` on a channel owner survives (should be `close!`): " *
        join(close_offenders, ", "),
    )
end
