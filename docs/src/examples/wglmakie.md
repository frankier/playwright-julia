# WGLMakie.jl

An interactive plot, screenshotted and traced. The hardest of the four
examples, and the one that justifies the artifact API: a WebGL canvas is
exactly the case where "the assertion failed" tells you nothing and a
screenshot tells you everything.

```console
$ julia --project=examples examples/wglmakie_jl.jl
$ PLAYWRIGHT_JL_ENGINE=firefox julia --project=examples examples/wglmakie_jl.jl
```

## Chromium renders. Firefox has no WebGL at all.

Stating this plainly, because it decides what the example can claim.

**Chromium renders the figure in full, with no launch flags.** Playwright's
Chromium ships SwiftShader — a CPU rasteriser — and selects it when there is no
GPU, so WebGL works headless, with no GPU and no X display. Both
`--use-gl=swiftshader` and the `--enable-unsafe-swiftshader` incantation that
circulates for this problem produce a **byte-identical** screenshot to passing
nothing at all. The renderer reports itself as:

```
ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero) (0x0000C0DE)), SwiftShader driver)
```

**Headless Firefox has no WebGL context whatsoever.** Not a slow one, not a
broken one — `getContext('webgl2')` and `getContext('webgl')` both return
`null`. Four escalating attempts changed nothing: `webgl.force-enabled` and
friends, a Mesa software-GL environment (`LIBGL_ALWAYS_SOFTWARE`,
`GALLIUM_DRIVER=llvmpipe`), and both together. The console explains itself:

```
Failed to create WebGL context: WebGL creation failed:
* Exhausted GL driver options. (FEATURE_FAILURE_WEBGL_EXHAUSTED_DRIVERS)
```

Firefox looked for a driver it would accept and found none, which is why
pointing it at a software rasteriser changes nothing.

So **the rendered-pixel assertion runs on Chromium only.** Firefox is still
run, and still asserted on, structurally: the canvas is created at the
requested size, `getContext` returns nothing, and the page raises no errors.
WGLMakie's no-WebGL fallback is a *designed* path rather than a crash, which
makes "no page errors" a real assertion on both engines rather than a
tautology on one.

## Waiting for pixels

There is no DOM event for "WebGL has painted". The canvas element exists long
before anything is drawn on it, so [`wait_for_selector`](@ref) returns far too
early — the first version of the probe did exactly that and screenshotted
Bonito's loading spinner.

What *is* observable is the screenshot. So the wait is on the pixels: count the
distinct colours in a screenshot and retry until the plot appears. The figure
is deliberately high-variance — three series in red, blue and green — so a
blank result cannot be explained away as a flat plot, and the three states are
an order of magnitude apart:

| Page state | distinct colours |
|---|---|
| Bonito still loading | 123 |
| Firefox's no-WebGL fallback | 241 |
| **fully rendered** | **~1690** |

The threshold is 500, with an order of magnitude of headroom on both sides.

**The budget is 90 seconds, and it needs to be.** A cold first render measured
57.9 seconds — Bonito serving its bundle, the browser compiling the WGLMakie
JavaScript, and SwiftShader compiling shaders on the CPU, all at once — against
1.8 seconds warm. CI is the cold case every single time. This is
[`retry_until`](@ref) applied to rendering rather than to server start-up, and
it is the second place in these examples where a fixed `sleep` would be either
a flake or a minute thrown away. See [Waiting](@ref).

## The artifacts

The run is wrapped in [`with_tracing`](@ref) and ends with a
[`screenshot`](@ref), both written to `examples/output/` (gitignored).

That is not decoration. When a WebGL page fails in CI, the assertion message is
`false` — the trace's filmstrip and the screenshot are the only things that can
tell you whether the canvas was blank, the plot was wrong, or the page never
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
