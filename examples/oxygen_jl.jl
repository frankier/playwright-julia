# Oxygen.jl — a micro-framework with routes, driven end to end.
#
#     julia --project=examples examples/oxygen_jl.jl
#     PLAYWRIGHT_JL_ENGINE=firefox julia --project=examples examples/oxygen_jl.jl
#
# What this adds over the HTTP.jl example is a *second surface*. A typical app
# is a page plus the JSON endpoints that page calls, and both need testing.
# The interesting part is that the JSON is checked through the browser's own
# `fetch` rather than through HTTP.jl on this side: that way the assertion
# covers what the page can actually reach — same origin, same cookies, same
# headers — instead of what Julia can reach.

using Oxygen
using HTTP
using Test
using Playwright

include("common.jl")

const INVENTORY = [
    (name = "widget", stock = 12),
    (name = "sprocket", stock = 0),
    (name = "gizmo", stock = 7),
]

@get "/api/inventory" function (req::HTTP.Request)
    return [Dict("name" => item.name, "stock" => item.stock) for item in INVENTORY]
end

@get "/" function (req::HTTP.Request)
    html = """
    <!doctype html>
    <html>
      <head><title>Playwright.jl · Oxygen.jl</title></head>
      <body>
        <h1>Inventory</h1>
        <table id="inventory"><tbody></tbody></table>
        <p id="status">loading…</p>
        <script>
          // The page fills itself in from the API, which is the whole point:
          // the DOM assertions below are only true if the route works.
          fetch("/api/inventory")
            .then(r => r.json())
            .then(items => {
              const body = document.querySelector("#inventory tbody");
              for (const item of items) {
                const tr = document.createElement("tr");
                tr.className = item.stock > 0 ? "in-stock" : "out-of-stock";
                tr.innerHTML = `<td class="name">\${item.name}</td>` +
                               `<td class="stock">\${item.stock}</td>`;
                body.appendChild(tr);
              }
              document.getElementById("status").textContent =
                items.length + " items";
            });
        </script>
      </body>
    </html>
    """
    return HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"], html)
end

# Oxygen wants the port up front, so this is where common.jl's `free_port`
# earns its place.
port = free_port()
url = "http://127.0.0.1:$port/"
serve(; host = "127.0.0.1", port = port, async = true, show_errors = true)

try
    wait_for_server(url)

    playwright() do pw
        browser = launch(engine_from_env(pw); headless = true)
        try
            page = new_page(browser)
            goto!(page, url)

            @testset "Oxygen.jl example" begin
                expect(page; to_have_title = "Playwright.jl · Oxygen.jl")

                # The HTML surface. The rows arrive after the fetch resolves,
                # so every one of these is a retrying assertion.
                expect(locator(page, "#status"); to_have_text = "3 items")
                expect(locator(page, "#inventory tr"; strict = false); to_have_count = 3)
                expect(locator(page, "tr.out-of-stock td.name"); to_have_text = "sprocket")
                expect(locator(page, "tr.in-stock"; strict = false); to_have_count = 2)

                # The JSON surface, fetched by the browser. `evaluate` hands
                # back the parsed body, so this is an ordinary Julia value by
                # the time it is asserted on.
                items = evaluate(page, "() => fetch('/api/inventory').then(r => r.json())")
                @test length(items) == 3
                @test [item["name"] for item in items] == ["widget", "sprocket", "gizmo"]
                @test items[2]["stock"] == 0

                # And the status code the browser saw, which a DOM assertion
                # cannot tell you.
                status = evaluate(page, "() => fetch('/api/inventory').then(r => r.status)")
                @test status == 200
            end

            # ## The same page, with the backend mocked
            #
            # Everything above went through Oxygen. Everything below drives the
            # *same page* with `/api/inventory` answered by the test instead —
            # which is the argument for route interception, stated as code
            # rather than as prose.
            #
            # What that buys: the empty state and the 500 are both one line
            # here, and neither needs a route in the server that exists only so
            # a test can reach it. A backend that has to grow endpoints for its
            # tests is a backend whose tests have changed it.
            @testset "Oxygen.jl example — mocked backend" begin
                ctx = first(contexts(browser))

                # An inventory the server never had.
                mocked = [
                    Dict("name" => "mock-widget", "stock" => 7),
                    Dict("name" => "mock-sprocket", "stock" => 0),
                ]
                with_route(
                    ctx,
                    "**/api/inventory",
                    route -> fulfill!(route; json = mocked),
                ) do
                    goto!(page, url)
                    expect(locator(page, "#status"); to_have_text = "2 items")
                    expect(
                        locator(page, "#inventory tr"; strict = false);
                        to_have_count = 2,
                    )
                    expect(
                        locator(page, "tr.out-of-stock td.name");
                        to_have_text = "mock-sprocket",
                    )
                end

                # The empty state, which the real server cannot produce without
                # a fixture and a way to reset it.
                with_route(ctx, "**/api/inventory", route -> fulfill!(route; json = [])) do
                    goto!(page, url)
                    expect(locator(page, "#status"); to_have_text = "0 items")
                    expect(
                        locator(page, "#inventory tr"; strict = false);
                        to_have_count = 0,
                    )
                end

                # ...and the failure path. `route.fetch` gets the genuine
                # response, and the page is handed its body under a 500 — the
                # real payload with the one thing changed that the test is
                # about.
                with_route(
                    ctx,
                    "**/api/inventory",
                    function (route)
                        upstream = Playwright.fetch(route)
                        fulfill!(route; response = upstream, status = 500)
                    end,
                ) do
                    goto!(page, url)
                    status =
                        evaluate(page, "() => fetch('/api/inventory').then(r => r.status)")
                    @test status == 500
                end

                # With every registration gone the page is served by Oxygen
                # again — the mocking left nothing behind.
                goto!(page, url)
                expect(locator(page, "#status"); to_have_text = "3 items")
            end
        finally
            close!(browser)
        end
    end
finally
    terminate()
end
