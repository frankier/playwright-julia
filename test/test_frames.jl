# Smoke tests for the frames slice, on Chromium and Firefox.
#
# This is the case Bonnie's CDP shim could not express: reaching into a
# same-origin iframe, driving something in it, and reading the result back.

@testset "frames ($(browser_name))" for browser_name in ("chromium", "firefox")
    with_fixture_server() do base_url
        playwright() do pw
            browser = launch(getfield(pw, Symbol(browser_name)))
            page = new_page(browser)
            goto!(page, "$base_url/iframe.html")

            main = Playwright.main_frame(page)

            @testset "enumeration" begin
                fs = frames(page)
                @test length(fs) == 2
                @test fs[1] === main          # main frame first
                @test all(f -> f isa Playwright.Frame, fs)

                # url is folded forward from `navigated` events, not left at
                # whatever the frame started as.
                @test endswith(url(main), "/iframe.html")
                @test occursin("iframe-child.html", url(fs[2]))
                @test frame_name(main) == ""
            end

            @testset "parent_frame" begin
                child = frames(page)[2]
                @test parent_frame(child) === main
                @test parent_frame(main) === nothing
            end

            @testset "frame_locator drives elements inside the child" begin
                inner = frame_locator(page, "#child")
                @test inner isa Playwright.FrameLocator

                @test text_content(locator(inner, "#child-status")) == "untouched"
                click!(locator(inner, "#child-button"))
                @test text_content(locator(inner, "#child-status")) == "pressed"

                set_value!(locator(inner, "#child-input"), "typed inside")
                @test input_value(locator(inner, "#child-input")) == "typed inside"

                # The parent is untouched by all of that.
                @test text_content(locator(page, "#parent-status")) == "untouched"
            end

            @testset "content_frame evaluates in the child, not the parent" begin
                inner = frame_locator(page, "#child")
                child = content_frame(inner)
                @test child isa Playwright.Frame
                @test evaluate(child, "document.title") == "Child Frame"
                @test evaluate(child, "document.title") isa String
                # The parent's own title is different — proof we crossed over.
                @test title(page) == "Iframe Parent"

                # The effects of the frame_locator actions above are visible here.
                @test evaluate(child, "document.getElementById('child-input').value") ==
                      "typed inside"

                # content_frame works from a plain Locator too.
                @test content_frame(locator(page, "#child")) === child
                @test child === frames(page)[2]
            end

            @testset "owner_frame is the inverse" begin
                @test owner_frame(locator(page, "#child")) === main
                @test owner_frame(
                    locator(frame_locator(page, "#child"), "#child-button"),
                ) === frames(page)[2]
            end

            @testset "detached frames disappear" begin
                @test length(frames(page)) == 2
                evaluate(page, "() => window.detachChild()")
                # The driver reports frameDetached asynchronously.
                @test timedwait(() -> length(frames(page)) == 1, 10.0) === :ok
                @test frames(page) == [main]
            end

            close!(browser)
        end
    end
end
