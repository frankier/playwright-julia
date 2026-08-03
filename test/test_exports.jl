# The package's public surface, pinned.
#
# This exists to fence refactors: splitting src/api.jl into src/api/* (T4) must
# not move, drop or accidentally add a single exported name. When the API grows
# deliberately, add the name here in the same commit — the diff is then a
# visible record of a public-surface change rather than a silent one.

@testset "exports" begin
    expected = [
        :Playwright,        # the module itself
        :PlaywrightError,
        :click,
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
        :pages,
        :parent_frame,
        :playwright,
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
