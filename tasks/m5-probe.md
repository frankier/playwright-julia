# T1 probe findings — headless WebGL for WGLMakie (D8)

Probed against the live 1.61.1 driver on **Chromium and Firefox**, 2026-08-05,
with **`DISPLAY` and `WAYLAND_DISPLAY` unset** — the CI condition, not this
workstation's. Three scripts, five browser configurations, plus a second full
run that reproduced the first exactly. Screenshots are under the scratch
directory (gitignored — reproduce with the script at the bottom).

**Verdict: Chromium renders WGLMakie perfectly, with no launch flags at all.
Firefox has no WebGL implementation whatsoever and cannot be made to acquire
one. Recommended assertion level: D8 level 3 — Chromium-only for the rendered
pixels — with the Firefox leg retained as a level-2 structural assertion, so
the example still exercises both engines.** Dropping WGLMakie is not on the
table; it works, on one engine.

## The statistic the verdict turns on

Every screenshot is 1280×720 PNG, decoded with `PNGFiles` and reduced to the
count of distinct pixel colours. The three states separate cleanly and are
bit-identical across runs:

| Page state | distinct colours | std of channel values |
|---|---|---|
| Bonito still on its loading spinner | 123 | 0.011 |
| Firefox's "no WebGL" fallback text | 241 | 0.026 |
| **Fully rendered plot** | **1686** | **0.119** |

A threshold of `> 500` distinguishes rendered from not-rendered with an order
of magnitude of headroom on both sides. The figure is deliberately
high-variance — three series in red, blue and green — so a uniform result
cannot be explained away as a flat plot.

## Q1 — does it render on Chromium? Yes, and no flag is needed

| Configuration | WebGL context | rendered | distinct colours |
|---|---|---|---|
| **no `args` at all** | `webgl2` | **yes** | 1686 |
| `--use-gl=swiftshader` | `webgl2` | yes | 1686 |
| `--enable-unsafe-swiftshader --use-gl=angle --use-angle=swiftshader` | `webgl2` | yes | 1686 |

All three produce a **byte-identical** screenshot. The renderer string is the
same in all three:

```
vendor:   Google Inc. (Google)
renderer: ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero) (0x0000C0DE)), SwiftShader driver)
version:  WebGL 2.0 (OpenGL ES 3.0 Chromium)
```

So **the exact `launch` argument this repo should pass is: none.** Playwright's
Chromium already ships SwiftShader and already selects it when there is no GPU;
`--use-gl=swiftshader` is a no-op here, and the `--enable-unsafe-swiftshader`
incantation that circulates for this problem is not needed on 1.61.1. The
example gets a plain `launch(pw.chromium; headless = true)`, which is also the
line a reader would have written anyway.

`SwiftShader` is a CPU rasteriser, so the renderer string is itself the
evidence for the no-GPU half of the question: Chromium did not fall back from a
GPU, it never had one. `DISPLAY` was unset for every run above.

**Zero page errors** on every Chromium configuration.

## Q1a — the first render is slow, and that is the real trap

The first probe run reported Chromium as *not* rendering. It was wrong, and the
way it was wrong is the finding that matters most for T7. It waited three
seconds and screenshotted a loading spinner.

Waiting on the pixels instead, over three consecutive cold-to-warm launches
against the same server:

| launch | time to `ncolors > 500` |
|---|---|
| 1 (cold) | **57.9 s** |
| 2 | 2.7 s |
| 3 | 1.8 s |

Nearly a minute for the first render — Bonito serving its bundle, the browser
compiling the WGLMakie JS, and SwiftShader compiling shaders on the CPU, all at
once. **T7 must therefore wait on a readiness condition and budget at least
90 s for it**, and CI, where everything is cold, is the 57.9 s case every time.
A fixed `sleep` of any plausible length is either a flake or a minute wasted;
this is `retry_until`'s warm-up mode applied to rendering rather than to server
start-up, which makes it the second example in the milestone to justify the M4
API rather than merely demonstrate it.

## Q2 — does it render on Firefox? No, and it cannot be made to

Firefox headless has **no WebGL context at all** — not a slow one, not a broken
one, none. `canvas.getContext('webgl2')` and `('webgl')` both return `null`.

Attempted, all with identical results:

| Configuration | WebGL |
|---|---|
| default | none |
| `firefox_user_prefs`: `webgl.force-enabled`, `webgl.disabled=false`, `webgl.forbid-software=false` | none |
| `env`: `LIBGL_ALWAYS_SOFTWARE=1`, `GALLIUM_DRIVER=llvmpipe`, `MESA_GL_VERSION_OVERRIDE=4.5`, `MESA_GLSL_VERSION_OVERRIDE=450` | none |
| both of the above together, plus `gfx.webrender.software`, `gfx.webrender.all`, `layers.acceleration.force-enabled`, `webgl.out-of-process=false` | none |

The console says why:

```
Failed to create WebGL context: WebGL creation failed:
* AllowWebgl2:false restricts context creation on this system. ()
* WebglAllowWindowsNativeGl:false restricts context creation on this system. ()
* Exhausted GL driver options. (FEATURE_FAILURE_WEBGL_EXHAUSTED_DRIVERS)
```

"Exhausted GL driver options" is Firefox reporting that it looked for a driver
and found nothing it would accept — which is why pointing it at Mesa's software
rasteriser changes nothing. This is a property of Playwright's Firefox build in
a headless container, not of this machine.

## Q3 — what a structural assertion can key on

Firefox's failure is at least *clean and deterministic*. WGLMakie draws its own
fallback, identically on every run:

```
canvasCount   = 1                       # the canvas element is created…
canvas.getContext('webgl') = null       # …but never acquires a context
bodyText      = "Your graphics card does not seem to support WebGL"
canvasParent  = <div …><canvas width="800px" height="600px" …></canvas>
                <div id="webglmessage" …>Your graphics card does not seem to
                support <a href="…khronos.org/webgl/wiki/…">WebGL</a></div></div>
page_errors   = 0
```

Three usable anchors, in decreasing order of robustness: the `canvas` element
exists with the requested dimensions; `#webglmessage` is present; the body text
is that sentence. **Zero page errors on Firefox too** — the fallback is a
designed path, not a crash, so "no page errors" is a meaningful assertion on
both engines rather than a tautology on one.

## Recommendation — D8 level 3, with the Firefox leg kept

Level 1 is out: it requires both engines to render, and one cannot.

The recommendation is **level 3 (Chromium-only) for the pixel assertion**,
refined in one way that costs nothing and is worth stating explicitly:

- **Chromium** — assert on rendered output: take screenshots until the distinct
  colour count crosses the threshold, with a ≥ 90 s budget, then save the
  screenshot and the trace. This is the full M4 artifact demonstration on a
  real WebGL app.
- **Firefox** — do not skip it. Assert the level-2 structural facts: the canvas
  is created at the requested size, and there are no page errors. The example
  and the docs page then say plainly that headless Firefox has no WebGL, which
  is a true and useful thing for a reader to learn from this package.

That keeps SC 7's "both engines" honest for the example as a script, while
being straightforward about which engine the *rendering* claim covers. If
review prefers the strict reading of level 3 — Firefox not run at all — that is
a one-line change to the example and a shorter docs paragraph.

**Human review of this section is the gate on T7.**

## Reproducing

Under the `@pw-probe` shared environment (`Bonito`, `WGLMakie`, `PNGFiles`,
`Playwright`), with the display unset:

```
env -u DISPLAY -u WAYLAND_DISPLAY julia --project=@pw-probe probe.jl
```

```julia
using Bonito, WGLMakie, Playwright, PNGFiles, Sockets
WGLMakie.activate!()

app = App() do
    fig = Figure(size = (800, 600), backgroundcolor = :white)
    ax = Axis(fig[1, 1], title = "M5 probe")
    xs = range(0, 4pi, length = 200)
    lines!(ax, xs, sin.(xs), color = :red, linewidth = 4)
    lines!(ax, xs, cos.(xs), color = :blue, linewidth = 4)
    scatter!(ax, xs[1:10:end], sin.(xs[1:10:end]), color = :green, markersize = 20)
    fig
end

s = Sockets.listen(Sockets.localhost, 0)
port = Int(Sockets.getsockname(s)[2])
close(s)
server = Bonito.Server(app, "127.0.0.1", port)
ncolors(bytes) = length(Set(vec(PNGFiles.load(IOBuffer(bytes)))))

playwright() do pw
    for engine in (:chromium, :firefox)
        browser = launch(getproperty(pw, engine); headless = true)
        page = new_page(browser)
        goto(page, "http://127.0.0.1:$port/")
        wait_for_selector(page, "canvas"; timeout = 30_000)
        n = 0
        ok = retry_until(; timeout = 90_000, interval = 500, on_timeout = :false) do
            n = ncolors(screenshot(page))
            n > 500
        end
        @info "$engine rendered=$ok ncolors=$n errors=$(length(page_errors(page)))"
        close(browser)
    end
end
close(server)
```

The variants above are the same script with `args`, `env` and
`firefox_user_prefs` added to the `launch` call.
