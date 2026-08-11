# What differs between the engines

Playwright.jl tests five engines. They are not five of a kind, and they do not
all do the same things. This page is the list of every place they diverge, why,
and what to do instead.

It exists because the alternative is worse. A cross-engine suite that quietly
narrows its assertions until everything passes tells you nothing; one that
records each difference tells you what your own suite should expect. Every skip
in this package's test suite has a row here, and a test enforces that — a skip
with no row fails the build.

## The five

| Name | What it is | Installed by |
|---|---|---|
| `chromium` | Playwright's bundled Chromium | `julia bin/install.jl chromium` |
| `firefox` | Playwright's bundled Firefox | `julia bin/install.jl firefox` |
| `webkit` | Playwright's bundled WebKit | `julia bin/install.jl webkit`, plus `--with-deps` on Linux |
| `chrome` | The real Google Chrome, from the system | a system package (see below) |
| `msedge` | The real Microsoft Edge, from the system | a system package (see below) |

`chrome` and `msedge` are **not browser types.** Playwright launches them as
`chromium` with a `channel`, which is why [`engine`](@ref) exists:

```julia
playwright() do pw
    for name in ("chromium", "firefox", "webkit", "chrome", "msedge")
        browser = launch(engine(pw, name); headless = true)
        # ...
        close!(browser)
    end
end
```

Ask [`engine_name`](@ref) which of the five you asked for, and
[`browser_name`](@ref) what is actually running. **They disagree on purpose**,
and the disagreement is the most common source of a wrong test:

```julia
e = engine(pw, "msedge")
engine_name(e)                        # "msedge"
browser_name(launch(e))               # "chromium"
```

A test that branches on `browser_name(browser) == "chromium"` now catches
Chrome and Edge as well. That is usually what you want — they are Chromium — and
occasionally not.

### The branded two are a moving target, deliberately

Chrome and Edge come from the machine, not from Playwright. In CI they are
whatever version the runner image currently ships, and they update on Google's
and Microsoft's schedules — so a matrix that is green today can go red tomorrow
with no commit in between.

That is accepted on purpose. A Chrome stable release that breaks this package is
worth finding out about, and pinning it away would be pretending users are on a
version they are not. When such a failure happens, the version is in the job log
and the engine is in every test name.

Installing them is a **system-wide** change — apt on Linux (needing root), a
`.dmg` on macOS, an `.exe` on Windows — not a download into
`PLAYWRIGHT_BROWSERS_PATH`. `install` warns before it starts. If you only want a
browser to test with, `chromium` is the bundled build and touches nothing.

### WebKit on Linux needs system libraries

WebKit is the engine that does not ship its own world. On a stock Ubuntu,
`install` succeeds and the browser then fails to *launch* on a missing shared
library. The fix is the driver's own dependency installer:

```console
$ sudo -E "$(which julia)" --project=. bin/install.jl --with-deps webkit
```

It needs root, and it is Linux-only — passing `with_deps` on Windows or macOS
raises rather than silently doing nothing. A launch that fails this way says so
and names this command.

On distributions Playwright does not package dependencies for — anything that is
not Debian/Ubuntu — `--with-deps` cannot help, and the libraries have to come
from the distribution. This is why this package's own WebKit testing happens on
Ubuntu CI rather than on the maintainer's Fedora workstation.

## Divergences

Every row is a real difference, found by running the suite. "Platform" is filled
in only where the platform is what makes the row true.

| Engine | Platform | What differs | What to do instead | Whose |
|---|---|---|---|---|
| `firefox`, `webkit` | all | `pdf` and `pdf_bytes` do not exist. Upstream `page.pdf` is implemented only for Chromium. | Take a screenshot, or run the assertion on a Chromium-family engine. `chrome` and `msedge` support it — they *are* Chromium. | [Playwright](https://playwright.dev/docs/api/class-page#page-pdf) |
| `chrome`, `msedge` | all | The browser emits console messages of its own — autofill, enterprise policy and origin-trial notices — that the bundled Chromium does not. A test asserting "no console output" sees them. | Assert on the messages you expect rather than on their absence, or filter by `text`. | Playwright's, via the branded build |
| `webkit` | Linux | Will not launch after a plain `install webkit`; needs the system libraries. | `sudo -E "$(which julia)" --project=. bin/install.jl --with-deps webkit` (Debian/Ubuntu). See above. | [Playwright](https://playwright.dev/docs/browsers#install-system-dependencies) |
| `webkit` | all | **Rejects unknown command-line args instead of ignoring them.** WebKit parses its own command line strictly and exits on an argument it does not know, so a Chromium flag in `args` — `--disable-dev-shm-usage`, say — is fatal to it rather than inert. The other four engines ignore arguments that mean nothing to them. | Pass `args` per engine rather than sharing one list across all five, or leave it off for WebKit. | WebKit's own argument parser |
| `webkit` | all | **Resolves an unreachable host instead of raising.** A navigation to a closed port on localhost comes back as something WebKit is willing to hand over, where Chromium and Firefox both surface a network error. | Assert on the response — `status`, or the page's content — rather than on `goto!` throwing. | Playwright's, via WebKit |
| `webkit` | macOS | **Segfaults when a page opens a popup.** The browser process dies immediately (`Segmentation fault: 11`) and the call surfaces as `TargetClosedError`. Reproduced in the same two testsets on consecutive runs, so it is deterministic rather than flaky. Linux WebKit handles popups fine. | Assert the popup's effects through the opener, or cover popup behaviour on another engine. There is no workaround inside the popup itself — the process is gone. | Playwright's, via WebKit on macOS aarch64 |
| `webkit` | all | **Emits no download event for a content disposition attachment** in headless mode. `expect_download` waits out its whole budget rather than failing on a wrong value. | Fetch the URL directly and assert on the bytes, or run download coverage on a Chromium-family engine or Firefox. | Playwright's, via headless WebKit |
| `webkit` | Windows | Not tested at all, and not supported by this package's matrix. | Use `chromium` or `firefox` on Windows; WebKit on macOS is the closest equivalent target. | this package's scope |
| `chrome`, `msedge` | all | The orphan-process check cannot see them. It matches `ms-playwright` in the process path, and the branded browsers do not live there. | Nothing — the check is skipped rather than passing by matching nothing, which would be worse. | this package |
| any | Windows | The orphan-process check does not run: it shells out to `pgrep`. | Nothing. A `tasklist` parser is half a page for one assertion, on the platform where the leak it guards against is least likely to matter. | this package |

## Running a subset while you work

The default is all five, which is roughly 2.5× the old two-engine run. While
iterating, narrow it:

```console
$ PLAYWRIGHT_JL_SMOKE=1 PLAYWRIGHT_JL_ENGINE=webkit julia --project=. -e 'using Pkg; Pkg.test()'
$ PLAYWRIGHT_JL_SMOKE=1 PLAYWRIGHT_JL_ENGINE=chromium,firefox julia --project=. -e 'using Pkg; Pkg.test()'
```

An unknown name fails immediately rather than producing an empty engine loop
that passes by testing nothing.

The default stays all five on purpose: a default that silently tests less than
CI is how a contributor finds out about a WebKit failure from a red pull request
instead of from their own terminal.

## Writing your own cross-engine suite

[`skip_engine`](@ref) is exported for this. It logs the reason and returns a
`Bool`:

```julia
@testset "…" for name in SMOKE_ENGINES
    skip_engine(name, ("firefox", "webkit"), "no Page.pdf outside Chromium") && continue
    # ...
end
```

The discipline this package holds itself to, and recommends: **a skip that is
not visible in the output does not exist, and a skip nobody can explain in one
sentence is a bug until proven otherwise.**
