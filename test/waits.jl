# Deadlines for every wait in the hermetic suite.
#
# The fake-driver tests are a conversation between the test and one or more
# background tasks over a Channel. When that conversation goes as intended the
# waits take microseconds; when it does not, an unbounded `take!` or `fetch`
# does not fail, it stops -- and a test that stops is a dead CI job with no
# output rather than a red assertion with a line number.
#
# That is not hypothetical. `sync` raced an autoreply loop for one frame, the
# loser waited forever, and it cost four Windows jobs a run for three runs
# before a watchdog found it. The race was the bug; the missing deadline is why
# it took an hour a time to learn anything.
#
# So nothing here waits forever. Sixty seconds is far beyond any legitimate
# wait in these tests -- the whole file they live in normally takes single-digit
# seconds -- and is only ever reached by a bug.

const WAIT_TIMEOUT = parse(Float64, get(ENV, "PLAYWRIGHT_JL_WAIT_TIMEOUT", "60"))

struct WaitTimedOut <: Exception
    what::String
    seconds::Float64
end

Base.showerror(io::IO, e::WaitTimedOut) =
    print(io, "timed out after $(round(Int, e.seconds))s waiting for ", e.what)

"""
    take_within!(ch, what = "a channel message"; timeout = WAIT_TIMEOUT)

`take!(ch)`, but a bug fails the test instead of stopping the run.
"""
function take_within!(
    ch::Channel,
    what::AbstractString = "a channel message";
    timeout::Real = WAIT_TIMEOUT,
)
    isready(ch) && return take!(ch)
    # Closing the channel rather than timing out this call alone, because the
    # failure being caught is usually two consumers on one channel: waking only
    # the one that asked leaves the other parked, and the run stops anyway a few
    # lines later with a less useful stack. Closing wakes every waiter with the
    # same explanation.
    timer = Timer(timeout) do _
        isopen(ch) && close(ch, WaitTimedOut(what, timeout))
    end
    try
        return take!(ch)
    finally
        close(timer)
    end
end

"""
    await(t, what = "a task"; timeout = WAIT_TIMEOUT)

`fetch(t)`, with a deadline. A task that threw still rethrows, unchanged.
"""
function await(t::Task, what::AbstractString = "a task"; timeout::Real = WAIT_TIMEOUT)
    # timedwait polls istaskdone, which -- unlike a bounded take! -- cannot
    # consume anything, so a timeout here leaves no claim behind.
    timedwait(() -> istaskdone(t), timeout) === :ok || throw(WaitTimedOut(what, timeout))
    return fetch(t)
end
