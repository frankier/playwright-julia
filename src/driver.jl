# Driver bundle management: download/locate the Playwright driver (the
# playwright-core npm package run by a pinned Node.js binary) and install
# browsers through it.
#
# Upstream no longer publishes prebuilt driver zips; like playwright-python's
# scripts/build_driver.py we assemble the bundle from two published artifacts:
#   - the playwright-core npm tarball (pinned in PLAYWRIGHT_VERSION)
#   - the official Node.js binary (pinned in NODE_VERSION)
# The assembled layout matches upstream driver bundles:
#   node | node.exe    the Node.js binary
#   package/**         the playwright-core npm package (cli.js entry point)

"Pinned playwright-core npm version. The single place the version is set."
const PLAYWRIGHT_VERSION = "1.61.1"

"Pinned Node.js version used to run the driver."
const NODE_VERSION = "24.17.0"

const NPM_REGISTRY = "https://registry.npmjs.org"
const NODEJS_DIST = "https://nodejs.org/dist"

function default_os()
    Sys.iswindows() ? :windows :
    Sys.isapple() ? :macos :
    Sys.islinux() ? :linux : error("unsupported OS for the Playwright driver")
end

"""
    node_platform(; os, arch) -> String

Map an OS/architecture pair to the nodejs.org archive infix
(`node-v<ver>-<infix>`), e.g. `"linux-x64"`.
"""
function node_platform(; os::Symbol = default_os(), arch::Symbol = Sys.ARCH)
    archpart =
        arch === :x86_64 ? "x64" :
        arch === :aarch64 ? "arm64" :
        error("unsupported architecture for the Playwright driver: $arch")
    ospart =
        os === :linux ? "linux" :
        os === :macos ? "darwin" :
        os === :windows ? "win" : error("unsupported OS for the Playwright driver: $os")
    return "$ospart-$archpart"
end

playwright_core_url() =
    "$NPM_REGISTRY/playwright-core/-/playwright-core-$PLAYWRIGHT_VERSION.tgz"

function node_url(; os::Symbol = default_os(), arch::Symbol = Sys.ARCH)
    platform = node_platform(; os, arch)
    ext = os === :windows ? "zip" : "tar.xz"
    return "$NODEJS_DIST/v$NODE_VERSION/node-v$NODE_VERSION-$platform.$ext"
end

"Scratch directory holding the assembled driver for the pinned versions."
driver_dir() = @get_scratch!("driver-$PLAYWRIGHT_VERSION-node-$NODE_VERSION")

node_exe_name() = Sys.iswindows() ? "node.exe" : "node"

"Marker file written after a complete, successful assembly."
driver_ok_marker(dir) = joinpath(dir, ".complete")

driver_installed(dir = driver_dir()) = isfile(driver_ok_marker(dir))

"""
    driver_cmd(args...; dir=driver_dir()) -> Cmd

Command running the driver CLI: `<dir>/node <dir>/package/cli.js args...`.
"""
function driver_cmd(args::AbstractString...; dir::AbstractString = driver_dir())
    node = joinpath(dir, node_exe_name())
    cli = joinpath(dir, "package", "cli.js")
    return Cmd([node, cli, args...])
end

# `members` limits extraction to specific archive paths — needed for the
# Node.js dist archives, whose npm/npx symlinks 7z refuses to extract.
function extract_archive(
    archive::AbstractString,
    dest::AbstractString;
    members::Vector{String} = String[],
)
    if endswith(archive, ".zip")
        run(pipeline(`$(p7zip()) x -y -o$dest $archive $members`; stdout = devnull))
    else
        # .tgz / .tar.xz: decompress to a .tar, then extract it.
        mktempdir() do tmp
            run(pipeline(`$(p7zip()) x -y -o$tmp $archive`; stdout = devnull))
            tars = filter(f -> endswith(f, ".tar"), readdir(tmp; join = true))
            length(tars) == 1 || error("expected one .tar inside $archive")
            run(pipeline(`$(p7zip()) x -y -o$dest $(tars[1]) $members`; stdout = devnull))
        end
    end
end

function download_with_progress(
    url::AbstractString,
    dest::AbstractString,
    what::AbstractString,
)
    @info "Downloading $what" url
    last_pct = Ref(-1)
    Downloads.download(
        url,
        dest;
        progress = (total, now) -> begin
            total > 0 || return
            pct = floor(Int, 100 * now / total)
            if pct != last_pct[] && pct % 10 == 0
                last_pct[] = pct
                @info "  $what: $pct%"
            end
        end,
    )
end

"""
    install_driver(; force=false) -> String

Ensure the driver bundle is assembled in the scratch space; return its
directory. Downloads the playwright-core npm package and a Node.js binary
on first use.
"""
function install_driver(; force::Bool = false)
    dir = driver_dir()
    if force
        rm(dir; recursive = true, force = true)
        mkpath(dir)
    end
    driver_installed(dir) && return dir

    mktempdir() do tmp
        # playwright-core npm tarball extracts to package/
        core_tgz = joinpath(tmp, "playwright-core.tgz")
        download_with_progress(
            playwright_core_url(),
            core_tgz,
            "Playwright driver $PLAYWRIGHT_VERSION",
        )
        extract_archive(core_tgz, tmp)
        pkg = joinpath(tmp, "package")
        isfile(joinpath(pkg, "cli.js")) || error("playwright-core package has no cli.js")
        dest_pkg = joinpath(dir, "package")
        rm(dest_pkg; recursive = true, force = true)
        mv(pkg, dest_pkg)

        # Node.js: extract only the node binary out of the dist archive.
        node_archive = joinpath(tmp, "node-dist" * (Sys.iswindows() ? ".zip" : ".tar.xz"))
        download_with_progress(node_url(), node_archive, "Node.js $NODE_VERSION")
        node_tree = joinpath(tmp, "node-tree")
        root_name = "node-v$NODE_VERSION-$(node_platform())"
        node_member = Sys.iswindows() ? "$root_name/node.exe" : "$root_name/bin/node"
        extract_archive(node_archive, node_tree; members = [node_member])
        root = joinpath(node_tree, root_name)
        node_src =
            Sys.iswindows() ? joinpath(root, "node.exe") : joinpath(root, "bin", "node")
        isfile(node_src) || error("node binary not found in Node.js archive at $node_src")
        node_dest = joinpath(dir, node_exe_name())
        cp(node_src, node_dest; force = true)
        chmod(node_dest, 0o755)
    end

    write(driver_ok_marker(dir), PLAYWRIGHT_VERSION)
    @info "Playwright driver installed" dir
    return dir
end

"""
    install(; browsers=["chromium", "firefox"])

Download the Playwright driver bundle (if needed) and install `browsers`
into the standard Playwright browser cache via the driver's own installer.
Safe to call repeatedly — both steps are no-ops when already done.

`browsers` names engines the driver understands: `"chromium"`, `"firefox"`,
`"webkit"`. [`launch`](@ref) calls this for you the first time an engine turns
out to be missing, so an explicit `install` is for the case where you want the
download to happen *now* — in a CI step of its own, say, rather than inside the
first test.

```julia
install()                          # both engines
install(; browsers = ["chromium"]) # just one
```

Set `PLAYWRIGHT_BROWSERS_PATH` to put the browsers somewhere cacheable rather
than in the default per-user cache. From outside a Julia session, the same
thing is `julia bin/install.jl`, which works from a bare checkout — the case a
package carrying Playwright.jl as a *test* dependency hits in CI.
"""
function install(; browsers::Vector{String} = ["chromium", "firefox"])
    dir = install_driver()
    @info "Installing browsers via Playwright driver" browsers
    run(driver_cmd("install", browsers...; dir))
    return nothing
end

# --- Install ergonomics ----------------------------------------------------

"""
    browsers_path() -> Union{String,Nothing}

Where browsers are installed to and looked up from, or `nothing` when the
Playwright default cache is in use (`~/.cache/ms-playwright` on Linux,
`~/Library/Caches/ms-playwright` on macOS, `%USERPROFILE%\\AppData\\Local\\ms-playwright`
on Windows).

Set `PLAYWRIGHT_BROWSERS_PATH` to override it. The driver reads the variable
itself, and both [`install`](@ref) and the driver process started by
[`playwright`](@ref) inherit this process's environment, so setting it in
`ENV` — or in the shell before starting Julia — is enough for installing *and*
launching to agree on the location.

Worth pointing at a project-local directory in CI, where a cache you control is
easier to key and restore than one in the home directory.
"""
browsers_path() = get(ENV, "PLAYWRIGHT_BROWSERS_PATH", nothing)

"The browsers installed when the caller does not say otherwise."
const DEFAULT_BROWSERS = ["chromium", "firefox"]

"""
    browsers_from_args(args) -> Vector{String}

Browser names from a command line, defaulting to [`DEFAULT_BROWSERS`](@ref)
when none are given. Used by `bin/install.jl`; unknown names are rejected here
rather than after a download has already started.
"""
function browsers_from_args(args)
    isempty(args) && return copy(DEFAULT_BROWSERS)
    known = ("chromium", "firefox", "webkit")
    names = String[]
    for arg in args
        name = lowercase(String(arg))
        name in known || throw(
            ArgumentError(
                "unknown browser `$name`. Choose from: " * join(known, ", ") * ".",
            ),
        )
        push!(names, name)
    end
    return names
end
