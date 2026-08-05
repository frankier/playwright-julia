#     julia --project=docs docs/make.jl
#
# D4: this build never launches a browser. Every browser-requiring sample in
# the guide is a plain ```julia block, so the site can be built and gated on a
# runner with no browsers installed, and a docs failure always means a docs
# problem.

using Documenter
using Playwright

# Every jldoctest block runs against a bare `using Playwright` and nothing
# else. D4 constrains which docstrings can carry one: only browser-free paths
# qualify — value deserialisation, matcher construction, error construction —
# because this build must never launch a browser.
DocMeta.setdocmeta!(Playwright, :DocTestSetup, :(using Playwright); recursive = true)

makedocs(;
    sitename = "Playwright.jl",
    authors = "Frankie Robertson",
    modules = [Playwright],
    # D5, and the two gates this milestone is not allowed to weaken:
    # checkdocs reports any exported name missing from the reference, and
    # warnonly = false turns every Documenter warning — a broken @ref, a
    # missing page, a duplicate docstring — into a failed build.
    checkdocs = :exports,
    warnonly = false,
    doctest = true,
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://frankier.github.io/playwright-julia",
        assets = String[],
        # api.md is one page covering the whole export list, and it is over
        # Documenter's default warning size. That is the page working as
        # intended — splitting a reference into six pages to satisfy a byte
        # count would make it worse to use — so the limit is raised rather
        # than the page cut up. The hard limit moves with it, because
        # Documenter requires warn < threshold.
        size_threshold_warn = 400 * 1024,
        size_threshold = 500 * 1024,
    ),
    pages = [
        "Home" => "index.md",
        "Getting started" => "getting-started.md",
        "Guide" => [
            "guide/locators.md",
            "guide/waiting.md",
            "guide/assertions.md",
            "guide/events.md",
            "guide/artifacts.md",
            "guide/errors.md",
        ],
        "Examples" => [
            "examples/http.md",
            "examples/oxygen.md",
            "examples/genie.md",
            # examples/wglmakie.md is gated on T7.
        ],
        "API reference" => "api.md",
    ],
)

# Only in CI. Run locally, `deploydocs` cannot detect a deployment
# environment and says so — a warning on every local build, in a milestone
# whose acceptance is a warning-free build.
if get(ENV, "CI", "false") == "true"
    deploydocs(;
        repo = "github.com/frankier/playwright-julia",
        devbranch = "main",
        push_preview = false,
    )
end
