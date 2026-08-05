# Run every example and report which ones passed.
#
#     julia --project=examples examples/runexamples.jl              # both engines
#     PLAYWRIGHT_JL_ENGINE=firefox julia --project=examples examples/runexamples.jl
#
# Each example runs in its own process. That is not ceremony: they start real
# servers and load frameworks that install global state, and one example's
# leftover has no business deciding whether the next one passes. It also means
# a segfault in one is a failure rather than the end of the run.
#
# Sequential on purpose — the examples share a CI runner, and running four web
# frameworks at once measures the runner, not the package.

const EXAMPLES = ["http_jl.jl", "oxygen_jl.jl", "genie_jl.jl", "wglmakie_jl.jl"]

engines =
    haskey(ENV, "PLAYWRIGHT_JL_ENGINE") ? [ENV["PLAYWRIGHT_JL_ENGINE"]] :
    ["chromium", "firefox"]

results = Tuple{String,String,Bool,Float64}[]

for engine in engines, name in EXAMPLES
    script = joinpath(@__DIR__, name)
    isfile(script) || continue
    @info "Running $name on $engine"
    env = copy(ENV)
    env["PLAYWRIGHT_JL_ENGINE"] = engine
    cmd = `$(Base.julia_cmd()) --project=$(@__DIR__) --color=yes $script`
    t0 = time()
    ok = success(pipeline(setenv(cmd, env), stdout = stdout, stderr = stderr))
    push!(results, (name, engine, ok, time() - t0))
end

println("\n", "="^62)
for (name, engine, ok, secs) in results
    println(
        rpad(name, 20),
        rpad(engine, 10),
        ok ? "PASS" : "FAIL",
        lpad(string(round(secs, digits = 1), "s"), 10),
    )
end
println("="^62)

failed = count(!, (ok for (_, _, ok, _) in results))
if failed > 0
    @error "$failed example run(s) failed"
    exit(1)
end
@info "All $(length(results)) example run(s) passed"
