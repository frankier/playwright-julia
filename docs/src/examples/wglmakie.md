# WGLMakie.jl

An interactive plot, screenshotted and traced. This is the hardest of the four
examples, and the one that justifies the artifact API. A WebGL canvas is exactly
the case where "the assertion failed" tells you nothing and a screenshot tells
you everything.

```console
$ julia --project=examples examples/wglmakie_jl.jl
$ PLAYWRIGHT_JL_ENGINE=firefox julia --project=examples examples/wglmakie_jl.jl
```

## Both engines render it, headless

**Chromium renders the figure in full, with no launch flags.** Playwright's
Chromium ships SwiftShader, a CPU rasteriser, and selects it when there is no
GPU. So WebGL works headless, with no GPU and no X display. Both
`--use-gl=swiftshader` and the `--enable-unsafe-swiftshader` incantation that
circulates for this problem produce a **byte-identical** screenshot to passing
nothing at all. The renderer reports itself as:

```
ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero) (0x0000C0DE)), SwiftShader driver)
```

**The pinned Firefox renders it too.** That is worth measuring rather than
assuming: older builds gave no WebGL context at all here, with the console
reporting

```
Failed to create WebGL context: WebGL creation failed:
* Exhausted GL driver options. (FEATURE_FAILURE_WEBGL_EXHAUSTED_DRIVERS)
```

The pinned build reports `has_webgl == true` and paints 1625 distinct colours,
against Chromium's ~1690. So **the rendered-pixel assertion runs on both
engines.**

## Waiting for pixels

There is no DOM event for "WebGL has painted". The canvas element exists long
before anything appears on it, so [`wait_for_selector`](@ref) returns far too
early and screenshots Bonito's loading spinner.

The screenshot is what you *can* observe. So wait on the pixels: count the
distinct colours in a screenshot, and retry until the plot appears. The figure
uses three series in red, blue and green, so nobody can explain a blank result
away as a flat plot. The two states are an order of magnitude apart:

| Page state | distinct colours |
|---|---|
| Bonito still loading | 123 |
| **fully rendered** | **1625 on Firefox, ~1690 on Chromium** |

The threshold is 500, which leaves an order of magnitude of headroom on both
sides.

**The budget is 90 seconds, and it needs to be.** A cold first render measures
57.9 seconds, against 1.8 seconds warm. Three things happen at once in that
minute: Bonito serves its bundle, the browser compiles the WGLMakie JavaScript,
and SwiftShader compiles shaders on the CPU. CI hits the cold case every time.

This is [`retry_until`](@ref) applied to rendering rather than to server
start-up. It is the second place in these examples where a fixed `sleep` would be
either a flake or a minute thrown away. See [Waiting](@ref).

## The artifacts

[`with_tracing`](@ref) wraps the run, which ends with a [`screenshot`](@ref).
Both land in `examples/output/`, which git ignores.

That is not decoration. When a WebGL page fails in CI the assertion message is
just `false`. The trace's filmstrip and the screenshot are the only things that
can tell you whether the canvas was blank, the plot was wrong, or the page never
loaded. Open the trace with:

```console
$ npx playwright@1.61.1 show-trace examples/output/wglmakie-chromium.zip
```

See [Artifacts](@ref).

## The source

Read from `examples/wglmakie_jl.jl` at build time:

```@eval
using Markdown, Playwright
src = read(joinpath(pkgdir(Playwright), "examples", "wglmakie_jl.jl"), String)
Markdown.parse("```julia\n" * src * "```")
```
