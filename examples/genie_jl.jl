# Genie.jl — the full framework, and the slowest to start.
#
#     julia --project=examples examples/genie_jl.jl
#     PLAYWRIGHT_JL_ENGINE=firefox julia --project=examples examples/genie_jl.jl
#
# The slowness is why this example exists. `up()` returns long before the
# server will answer a request, so a browser test that navigates straight
# afterwards gets a connection refused — and the usual fix, a `sleep` picked by
# trial and error, is either too short on a loaded CI runner or wasted on every
# run forever after.
#
# `wait_for_server` in common.jl is `retry_until(…; on_error = :retry)`:
# connection refused is the expected state during warm-up, so it is retried
# rather than raised, and the wait ends the moment a request succeeds.
#
# The number that justifies all of that: **Genie answered its first request
# 25.0 seconds after `up()` returned** (measured 2026-08-05, warm depot, idle
# workstation; a cold CI runner is slower). The browser work that follows
# takes 2 seconds. The example measures and prints the wait on every run, so
# the claim stays checkable rather than becoming folklore.

using Genie
using Genie.Router
using Genie.Renderer.Html
using Genie.Requests
using HTTP
using Test
using Playwright

include("common.jl")

const ARTICLES = [
    (id = 1, title = "Waiting is not sleeping", tag = "testing"),
    (id = 2, title = "Locators, briefly", tag = "api"),
    (id = 3, title = "Tracing a failure", tag = "artifacts"),
]

route("/") do
    items = join(["""<li class="article" data-tag="$(a.tag)">
                       <a href="/articles/$(a.id)">$(a.title)</a>
                     </li>""" for a in ARTICLES], "\n")
    html("""
    <!doctype html>
    <html>
      <head><title>Playwright.jl · Genie.jl</title></head>
      <body>
        <h1 id="heading">Articles</h1>
        <ul id="articles">$items</ul>
      </body>
    </html>
    """)
end

route("/articles/:id::Int") do
    # The route declared `:id::Int`, so Genie has already converted it.
    id = payload(:id)
    article = ARTICLES[findfirst(a -> a.id == id, ARTICLES)]
    html("""
    <!doctype html>
    <html>
      <head><title>$(article.title)</title></head>
      <body>
        <h1 id="title">$(article.title)</h1>
        <p id="tag">$(article.tag)</p>
        <a id="back" href="/">Back</a>
      </body>
    </html>
    """)
end

port = free_port()
url = "http://127.0.0.1:$port/"

# `async = true` hands control straight back; the server is not ready yet.
Genie.up(port, "127.0.0.1"; async = true)

try
    started = Base.time()
    wait_for_server(url; timeout = 120_000)
    warmup = round(Base.time() - started, digits = 1)
    @info "Genie answered its first request after $(warmup)s"

    playwright() do pw
        browser = launch(engine(pw); headless = true)
        try
            page = new_page(browser)
            goto!(page, url)

            @testset "Genie.jl example" begin
                expect(page; to_have_title = "Playwright.jl · Genie.jl")
                expect(locator(page, "#heading"); to_have_text = "Articles")
                expect(locator(page, "li.article"; strict = false); to_have_count = 3)

                # Genie's routing is the thing under test, so the example
                # follows a link and checks it landed on the right route.
                click!(locator(page, "li.article a"; strict = false))
                expect(page; to_have_url = r"/articles/1$")
                expect(locator(page, "#title"); to_have_text = "Waiting is not sleeping")
                @test text_content(locator(page, "#tag")) == "testing"

                # …and back, so the return route is covered too.
                click!(locator(page, "#back"))
                expect(page; to_have_title = "Playwright.jl · Genie.jl")
                @test length(
                    evaluate_all(
                        locator(page, "li.article"; strict = false),
                        "els => els.map(e => e.dataset.tag)",
                    ),
                ) == 3
                @test evaluate_all(
                    locator(page, "li.article"; strict = false),
                    "els => els.map(e => e.dataset.tag)",
                ) == ["testing", "api", "artifacts"]
            end
        finally
            close!(browser)
        end
    end
    @info "Genie warm-up was $(warmup)s — the honest justification for " *
          "retry_until(…; on_error = :retry) over a sleep"
finally
    Genie.down()
end
