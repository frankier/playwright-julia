# Files, dialogs and uploads

Three things a page can do that are not requests you make: it can hand you a
file, it can stop dead behind a JavaScript dialog, and it can ask you for a
file. They are grouped here because they share a shape — the browser starts
something and waits for the Julia side to answer — and because two of the three
have a failure mode that looks like nothing happening at all.

| You want | Reach for |
|---|---|
| the file a click downloaded | [`expect_download`](@ref) |
| to answer `alert` / `confirm` / `prompt` | [`with_dialog`](@ref) |
| to fill an `<input type=file>` | [`set_input_files!`](@ref) |
| to answer a file dialog with no input behind it | [`expect_file_chooser`](@ref) |

## Downloads

A download is caught the same way any event is — subscribe before the click, not
after:

```julia
dl = expect_download(page) do
    click!(locator(page, "#export"))
end

suggested_filename(dl)                  # "report-2026.csv" — what the server called it
save_as!(dl; path = "artifacts/report.csv")
```

[`expect_download`](@ref) attaches the subscription before running the block, so
a download that starts instantly is still caught. It raises
[`TimeoutError`](@ref) only when *no* download starts at all.

A [`Download`](@ref) is an [`Artifact`](@ref) plus the two things the event knows
and the artifact does not — where the file came from, and what the server named
it. [`artifact`](@ref) hands back the artifact underneath, so nothing is lost by
going through the wrapper.

### A refused download is still a download

This is the one to read twice.

```julia
ctx = new_context(browser; accept_downloads = false)
dl = expect_download(page) do
    click!(locator(page, "#export"))
end
```

That call **returns normally**. The event still arrives, with a correct
[`url`](@ref) and [`suggested_filename`](@ref); the refusal is not visible
anywhere until you ask for the file itself. And when you do,
[`path`](@ref) and [`save_as!`](@ref) *raise* a [`DriverError`](@ref) — they do
not return `nothing`.

So the success check is [`failure`](@ref), which is the only one of these that
answers without throwing:

```julia
if isnothing(failure(dl))
    save_as!(dl; path = "artifacts/report.csv")
else
    @warn "download refused" reason = failure(dl)
end
```

`isnothing(path(dl))` looks like the same question and is not: it raises rather
than returning `nothing`, and nothing in the name warns you.

### Where the file lives

[`path`](@ref) blocks until the download has finished, then returns the driver's
own copy — so `isfile(path(dl))` immediately afterwards is true, with no polling
and no `sleep`. That copy is temporary; [`save_as!`](@ref) puts it somewhere you
chose, and [`delete_file!`](@ref) drops it early if you are downloading a lot of
large files in one run.

[`cancel!`](@ref) abandons one still in progress. Afterwards
[`failure`](@ref) reports the cancellation rather than `nothing`.

### `accept_downloads` is not boilerplate

**Downloads work with it unset.** It is a way to make the browser *refuse*
downloads, not a switch that enables them:

```julia
ctx = new_context(browser; accept_downloads = false)   # refuse
ctx = new_context(browser)                             # accept — the default
```

Leaving it unset omits the parameter from the wire entirely, deliberately: the
protocol has a third value that hands downloads to the browser's own machinery
and then emits no event at all, which costs a full timeout with no diagnostic.
The Julia keyword is a `Bool` so that value cannot be reached by accident.

To choose the directory the driver downloads into, pass `downloads_path` to
[`launch`](@ref) — it is a launch option, not a context one.

## Dialogs

`alert`, `confirm`, `prompt` and the `beforeunload` prompt all block their page
until somebody answers. The rule that follows from that is the important part:

!!! warning "Registering a handler is what disarms the auto-dismiss"
    With no handler registered, the driver dismisses dialogs itself and the page
    carries on. Register one and that stops: from then until the registration is
    released, **every** dialog on that page is yours to answer.

[`with_dialog`](@ref) is the form to use, because it cannot leave a registration
behind:

```julia
with_dialog(page; handler = accept!) do
    click!(locator(page, "#confirm-delete"))
end
```

The handler is a keyword and the triggering action is the do-block. Two
functions in one call with only argument position to tell them apart reads
badly, so the keyword names the unusual one.

Read the dialog with [`dialog_type`](@ref), [`message`](@ref) and
[`default_value`](@ref); answer it with [`accept!`](@ref) or
[`dismiss!`](@ref):

```julia
with_dialog(page; handler = d -> accept!(d; prompt_text = "Ada")) do
    click!(locator(page, "#ask-name"))
end
```

`prompt_text` is meaningful only for a `prompt`; omitted, the dialog's own
[`default_value`](@ref) is submitted. `dialog_type` is spelled that way because
`type` is unusable as a function name in any script that also uses the word.

[`on_dialog!`](@ref) and [`off_dialog!`](@ref) are the unscoped pair, for when
the registration has to outlive one block. Handlers run on a dispatcher task,
one per page, sequentially and in arrival order; the newest registration wins;
and anything a handler throws is collected and rethrown out of
[`off_dialog!`](@ref) — which also blocks until a dialog being handled right now
has been answered, so the next line does not race it.

A handler that returns without answering gets a dismissal and one warning per
registration — not a hung page, and not one warning per dialog.

### Why this is a registry and not an event

Every other one of these surfaces is an [`expect_event`](@ref) wrapper. Dialogs
are not, and the reason is mechanical rather than stylistic: on the wire,
"a client subscribed to `dialog`" and "the driver should stop auto-dismissing"
are the *same message*. Subscribing is what arms the trap.

So an event-shaped API would disarm the safety net simply by being used — an
`expect_event(page, :dialog)` that timed out would leave the page stuck behind
the next dialog, and a speculative subscription would do it to pages nobody was
watching. The registry only subscribes once a handler actually exists to answer,
and unsubscribes when the last one goes away. `:dialog` is therefore not offered
in the [event table](@ref "What you can subscribe to") at all.

## Uploads

For an `<input type=file>` you can select, [`set_input_files!`](@ref) is the
whole story:

```julia
set_input_files!(locator(page, "#attachment"), "test/fixtures/upload.csv")
set_input_files!(locator(page, "#attachments"), ["a.csv", "b.csv"])
set_input_files!(locator(page, "#attachment"))                      # clears it
```

Files can also be supplied from memory, with no file on disk at all:

```julia
set_input_files!(loc; name = "x.csv", mime_type = "text/csv", buffer = bytes)
```

The two forms are mutually exclusive, and passing both raises an `ArgumentError`
*before* anything reaches the driver. So does naming a path that does not exist.
Both are checks you could leave to the driver; the driver's version of the
complaint arrives later and names the wire spelling rather than your keyword.

### When there is no input to select

A button that opens the browser's file dialog from JavaScript has no
`<input type=file>` to reach. [`expect_file_chooser`](@ref) catches the dialog
instead:

```julia
fc = expect_file_chooser(page) do
    click!(locator(page, "#attach"))
end
set_files!(fc, "test/fixtures/upload.csv")
```

[`set_files!`](@ref) takes exactly what [`set_input_files!`](@ref) takes, because
it *is* [`set_input_files!`](@ref) applied to the chooser's [`element`](@ref) —
one implementation, one place for the rules to be wrong.

Unlike a dialog, an unanswered file chooser does not block the page. It simply
never receives files, which is worth knowing when a test fails by uploading
nothing rather than by timing out.

[`is_multiple`](@ref) reports whether the chooser accepts more than one file.
Note that a `webkitdirectory` picker reports `false` on both engines — selecting
a directory is one selection, not many.

## Assert on the server, not the client

A test that uploads a file and then asserts on the page is mostly testing the
page's own JavaScript. The assertion worth writing is on the receiving end:

```julia
set_input_files!(loc, path)
click!(locator(page, "#submit"))
# then check what the server actually received
```

The same goes the other way for downloads — [`suggested_filename`](@ref) is what
the server said, so asserting on it checks the response headers rather than the
browser's rendering of them.
