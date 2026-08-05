# HTTP.jl — the thinnest possible Julia web server, driven end to end.
#
#     julia --project=examples examples/http_jl.jl
#     PLAYWRIGHT_JL_ENGINE=firefox julia --project=examples examples/http_jl.jl
#
# This is the first example on purpose. HTTP.jl brings no conventions of its
# own, so what is left is *the pattern* every browser test follows: start a
# server on a free port, wait for it, drive it through the public API, and
# shut it down in a `finally` whatever happens.

using HTTP
using Test
using Playwright

include("common.jl")

const PAGE = """
<!doctype html>
<html>
  <head><title>Playwright.jl · HTTP.jl</title></head>
  <body>
    <h1 id="heading">Servers under test</h1>
    <input id="name" value="" placeholder="your name" />
    <button id="greet">Greet</button>
    <ul id="log"></ul>
    <script>
      // A late DOM mutation, so the assertions below have something to wait
      // for rather than something to find already present.
      document.getElementById("greet").addEventListener("click", () => {
        const name = document.getElementById("name").value || "stranger";
        setTimeout(() => {
          const li = document.createElement("li");
          li.textContent = "Hello, " + name + "!";
          li.className = "greeting";
          document.getElementById("log").appendChild(li);
        }, 300);
      });
    </script>
  </body>
</html>
"""

function handler(req::HTTP.Request)
    req.target == "/" && return HTTP.Response(
        200,
        ["Content-Type" => "text/html; charset=utf-8"],
        body = PAGE,
    )
    return HTTP.Response(404, "not found")
end

# HTTP.jl can pick the port itself and hand it back, which is better than
# `free_port()` from common.jl: there is no window between choosing a port and
# binding it. The other examples use `free_port()` because their frameworks
# insist on being told a port up front.
server = HTTP.serve!(handler, "127.0.0.1", 0; listenany = true)
url = "http://127.0.0.1:$(HTTP.port(server))/"

try
    wait_for_server(url)

    playwright() do pw
        browser = launch(engine(pw); headless = true)
        try
            page = new_page(browser)
            goto(page, url)

            @testset "HTTP.jl example" begin
                # Document-level assertions: the page is the one we think it is.
                expect(page; to_have_title = "Playwright.jl · HTTP.jl")
                expect(locator(page, "#heading"); to_have_text = "Servers under test")

                # Nothing has been greeted yet. `to_have_count = 0` is a real
                # assertion about absence, not a missing element swallowed.
                expect(locator(page, "li.greeting"; strict = false); to_have_count = 0)

                # Fill, click, and assert on what the *browser* rendered. The
                # 300ms the page waits before appending is handled by expect's
                # retry, not by a sleep on this side. `fill` extends Base.fill,
                # so it needs no qualification.
                fill(locator(page, "#name"), "Ada")
                expect(locator(page, "#name"); to_have_value = "Ada")
                click(locator(page, "#greet"))

                expect(locator(page, "li.greeting"); to_have_text = "Hello, Ada!")
                expect(locator(page, "li.greeting"; strict = false); to_have_count = 1)

                # `expect` raises on failure rather than returning false, which
                # is what makes it retry — so it is an assertion in its own
                # right, not something to wrap in `@test`. Once it has settled,
                # a plain read is the natural thing to `@test`.
                @test text_content(locator(page, "li.greeting")) == "Hello, Ada!"
                @test is_visible(locator(page, "#greet"))

                # A second greeting, to show the count assertion moving.
                click(locator(page, "#greet"))
                expect(locator(page, "li.greeting"; strict = false); to_have_count = 2)
                @test length(
                    evaluate_all(
                        locator(page, "li.greeting"; strict = false),
                        "els => els.map(e => e.textContent)",
                    ),
                ) == 2
            end
        finally
            close(browser)
        end
    end
finally
    close(server)
end
