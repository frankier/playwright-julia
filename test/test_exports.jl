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
        :clear_console_messages,
        :clear_page_errors,
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
        :click,
        :console_messages,
        :dispose,
        :eval_on_selector,
        :eval_on_selector_all,
        :evaluate,
        :evaluate_handle,
        :content_frame,
        :contexts,
        :dispatch_event,
        :frame_locator,
        :frames,
        :get_attribute,
        :goto,
        :inner_html,
        :inner_text,
        :input_value,
        :is_checked,
        :is_enabled,
        :is_visible,
        :install,
        :launch,
        :locator,
        :name,
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
        :save_as,
        :path,
        :delete,
        :screenshot,
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
end
