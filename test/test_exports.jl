# The package's public surface, pinned.
#
# This exists to fence refactors: moving code between files must not move, drop
# or accidentally add a single exported name. When the API grows deliberately,
# add the name here in the same commit — the diff is then a visible record of a
# public-surface change rather than a silent one.

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
        # The names that could not take the obvious bang, because `Base.fill!`
        # and `Base.delete!` are exported and would be ambiguous rather than
        # extended.
        :set_value!,
        :close!,
        :set_default_strict!,
        :set_default_timeout!,
        :set_default_navigation_timeout!,
        # locator ergonomics
        :evaluate_all,
        :element_handle,
        :frame,
        :selector,
        :is_strict,
        # the channel-owner types callers name
        :Browser,
        :BrowserContext,
        :BrowserType,
        :Page,
        :Frame,
        :Locator,
        :ElementHandle,
        :JSHandle,
        # engines by name (D1a)
        :Engine,
        :engine,
        :engine_name,
        # engine metadata
        :browser_name,
        # retrying assertions
        :expect,
        :Not,
        :retry_until,
        # driver-side waiting
        :wait_for_selector,
        :wait_for_function,
        # the event surface
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
        # the glob dialect, exported because a user debugging a route
        # needs to be able to ask what their glob actually matches.
        :glob_to_regex,
        # Request and Response
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
        # route interception
        :Route,
        :RouteRegistration,
        :route!,
        :unroute!,
        :unroute_all!,
        :with_route,
        :abort!,
        :continue!,
        :fulfill!,
        # HAR replay
        :route_from_har,
        :with_har,
        # HAR recording
        :HarRecording,
        :start_har_recording!,
        :stop_har_recording!,
        :with_har_recording,
        # WebSocket routing
        :WebSocketRoute,
        :WebSocketRouteRegistration,
        :route_web_socket!,
        :unroute_web_socket!,
        :with_web_socket_route,
        # mock or proxy, and the messages
        :connect!,
        :send_to_page!,
        :send_to_server!,
        :close_ws!,
        # the route's own events
        :on_message_from_page!,
        :on_message_from_server!,
        :on_close!,
        :frame_name,
        :new_context,
        # persistent contexts
        :launch_persistent_context,
        :new_page,
        :nth,
        :owner_frame,
        :page_errors,
        :pages,
        :parent_frame,
        :playwright,
        # artifact capture and the Artifact surface
        :pdf,
        :pdf_bytes,
        :save_as!,
        :path,
        :delete_file!,
        # tracing
        :start_tracing!,
        :stop_tracing!,
        :with_tracing,
        # video
        :video,
        :Artifact,
        # the with_page fixture
        :with_page,
        :report_diagnostics,
        # uploads
        :set_input_files!,
        :FileChooser,
        :expect_file_chooser,
        :element,
        :is_multiple,
        :set_files!,
        # dialogs
        :Dialog,
        :dialog_type,
        :message,
        :default_value,
        :accept!,
        :dismiss!,
        :on_dialog!,
        :off_dialog!,
        :with_dialog,
        # downloads
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

    # `Playwright.fetch` is deliberately NOT exported — Base.fetch and
    # Distributed.fetch both exist, and exporting this name would make `using
    # Playwright` alongside either of them ambiguous. The cost is that
    # `checkdocs = :exports` cannot see its docstring, so this test stands in for
    # the gate the export list would otherwise have given.
    @testset "Playwright.fetch is unexported but documented" begin
        @test !(:fetch in names(Playwright))
        @test isdefined(Playwright, :fetch)
        documented = Base.Docs.meta(Playwright)
        @test haskey(documented, Base.Docs.Binding(Playwright, :fetch))
    end

    # The README's "not yet covered" list, checked against the export set.
    #
    # A list of absences is the one kind of documentation that rots silently.
    # Nothing breaks when it goes stale, it only misinforms. So this asserts that
    # nothing the list calls uncovered is in fact exported.
    #
    # Written as a function over its inputs, so the gate can be watched failing
    # as well as passing.
    @testset "the README's not-covered list is still true" begin
        # The phrase the list would use, and the exported name that exists if
        # the thing is in fact covered.
        claims = [
            "HAR recording" => :start_har_recording!,
            "route_from_har" => :route_from_har,
            "WebSocket routing" => :route_web_socket!,
            "persistent contexts" => :launch_persistent_context,
        ]

        "The `Not yet covered` paragraph alone — the covered prose above it
        mentions the same features on purpose."
        function not_covered_paragraph(text)
            start = findfirst("Not yet covered", text)
            start === nothing && return ""
            rest = text[first(start):end]
            stop = findfirst("\n\n", rest)
            return stop === nothing ? rest : rest[1:first(stop)]
        end

        status_claims_are_honest(text, exported) = sort([
            phrase for (phrase, name) in claims if
            occursin(phrase, not_covered_paragraph(text)) && name in exported
        ])

        readme = read(joinpath(dirname(@__DIR__), "README.md"), String)
        @test !isempty(not_covered_paragraph(readme))   # the walk is not vacuous
        @test status_claims_are_honest(readme, names(Playwright)) == String[]

        # The gate, watched failing: a list that still calls WebSocket routing
        # uncovered must be caught, or this test is decoration.
        stale = "Not yet covered: WebKit; WebSocket routing; service workers.\n\n"
        @test status_claims_are_honest(stale, names(Playwright)) == ["WebSocket routing"]
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

# --- Two safety nets for the naming rules ----------------------------------
#
# Renames are mechanical, and mechanical changes are exactly the ones that
# regress quietly. The first testset guards the `Base`-shadowing trap. The second
# checks that no old spelling survives anywhere.

@testset "using Playwright shadows nothing in Base" begin
    # `fill!` and `delete!` are exported by Base, so a Playwright export of the
    # same name would not extend Base — it would make both ambiguous and break
    # `fill!` on arrays for anyone who writes `using Playwright`. That is why the
    # names are `set_value!` and `delete_file!`. If either ever comes back as the
    # obvious spelling, the identity assertions below fail before any user sees
    # an UndefVarError.
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
    # objects as Base's. Extending Base is fine. Exporting a second binding
    # under the same name is not.
    @test Locator in [
        m.sig.parameters[2] for
        m in methods(count) if m.module === Playwright && length(m.sig.parameters) == 2
    ]
end

@testset "no old spelling survives anywhere" begin
    # Each old name is searched for *as a call*, across every hand-written source
    # in the repo, so "no old spelling survives" is a grep rather than a habit.
    root = dirname(@__DIR__)

    # Hand-written sources only. src/generated/ is codegen output whose wire
    # names (`_frame_goto`, `_page_clear_console_messages`) legitimately keep
    # Playwright's spelling, and docs/build/ is a build artifact.
    function hand_written_files()
        paths = String[joinpath(root, "README.md")]
        # Whole directories, not just the subdirectories that hold prose today:
        # a grep that does not cover a file is indistinguishable from a file
        # with nothing to find.
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

    # Three prefixes are excluded, because each marks something that is not this
    # package's export:
    #
    #   * a leading `.` is a JavaScript method call inside an `evaluate` string —
    #     `document.getElementById("x").click()` is not this package's `click`;
    #   * a leading word character is a generated channel function;
    #   * a leading `$` is a variable interpolated into a string, as in
    #     `"function $name("` in test_codegen.jl, which builds the name of a
    #     *generated* function.
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
        # `name` was the package's single worst export -- a word so generic that
        # `using Playwright` shadowed it in any script that had its own.
        # `frame_name` says which name it means.
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
    # and `close(server)` are all correct. Only the three channel-owner methods
    # take the bang, so this checks `close` by what it is applied to.
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
