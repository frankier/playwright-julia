#!/usr/bin/env julia
#
# Install the Playwright driver and browsers, standalone.
#
#     julia bin/install.jl                  # chromium and firefox
#     julia bin/install.jl chromium         # just one
#     PLAYWRIGHT_BROWSERS_PATH=.playwright julia bin/install.jl
#
# This exists because `install()` is otherwise only reachable from inside a
# Julia session that already has Playwright.jl loadable — which is exactly what
# a project carrying it as a *test* dependency does not have. See the README's
# "Installing browsers in CI" section.

using Pkg

# Run either from an environment that already has Playwright.jl, or from a bare
# checkout with nothing set up. The second case is the one CI hits.
try
    @eval using Playwright
catch
    root = dirname(@__DIR__)
    @info "Playwright.jl not in the active environment; activating the checkout" root
    Pkg.activate(root)
    Pkg.instantiate()
    @eval using Playwright
end

browsers = Playwright.browsers_from_args(ARGS)
path = Playwright.browsers_path()
@info "Installing Playwright browsers" browsers destination =
    something(path, "Playwright's default cache")

Playwright.install(; browsers)

@info "Done. Browsers are in " * something(
    path,
    "Playwright's default cache — set PLAYWRIGHT_BROWSERS_PATH to relocate",
)
