# Files, dialogs and uploads

Three things a page can do that are not requests you make. It can hand you a
file, it can stop dead behind a JavaScript dialog, and it can ask you for a file.
They share a shape: the browser starts something and waits for the Julia side to
answer. Two of the three also fail in a way that looks like nothing happening at
all.

| You want | Reach for |
|---|---|
| the file a click downloaded | [`expect_download`](@ref) |
| to answer `alert` / `confirm` / `prompt` | [`with_dialog`](@ref) |
| to fill an `<input type=file>` | [`set_input_files!`](@ref) |
| to answer a file dialog with no input behind it | [`expect_file_chooser`](@ref) |

## Downloads

Catch a download the way you catch any event. Subscribe before the click, not
after:

```julia
dl = expect_download(page) do
    click!(locator(page, "#export"))
end

suggested_filename(dl)                  # "report-2026.csv" — what the server called it
save_as!(dl; path = "artifacts/report.csv")
```

[`expect_download`](@ref) attaches the subscription before running the block, so
it catches a download that starts instantly. It raises [`TimeoutError`](@ref)
only when *no* download starts at all.

A [`Download`](@ref) is an [`Artifact`](@ref) plus the two things the event knows
and the artifact does not: where the file came from, and what the server named
it. [`artifact`](@ref) hands back the artifact underneath, so the wrapper costs
you nothing.

### A refused download is still a download

This is the one to read twice.

```julia
ctx = new_context(browser; accept_downloads = false)
dl = expect_download(page) do
    click!(locator(page, "#export"))
end
```

That call **returns normally**. The event still arrives, with a correct
[`url`](@ref) and [`suggested_filename`](@ref). Nothing shows the refusal until
you ask for the file itself, and then [`path`](@ref) and [`save_as!`](@ref)
*raise* a [`DriverError`](@ref) rather than returning `nothing`.

So check [`failure`](@ref), the only one of these that answers without throwing:

```julia
if isnothing(failure(dl))
    save_as!(dl; path = "artifacts/report.csv")
else
    @warn "download refused" reason = failure(dl)
end
```

`isnothing(path(dl))` looks like the same question but is not. It raises rather
than returning `nothing`, and the name gives no warning of that.

### Where the file lives

[`path`](@ref) blocks until the download finishes, then returns the driver's own
copy. So `isfile(path(dl))` on the next line is true, with no polling and no
`sleep`. That copy is temporary. [`save_as!`](@ref) puts it somewhere you chose,
and [`delete_file!`](@ref) drops it early when one run downloads many large
files.

[`cancel!`](@ref) abandons one still in progress. Afterwards
[`failure`](@ref) reports the cancellation rather than `nothing`.

### `accept_downloads` is not boilerplate

**Downloads work with it unset.** It makes the browser *refuse* downloads. It is
not a switch that enables them:

```julia
ctx = new_context(browser; accept_downloads = false)   # refuse
ctx = new_context(browser)                             # accept — the default
```

Leaving it unset omits the parameter from the wire, on purpose. The protocol has
a third value that hands downloads to the browser's own machinery and then emits
no event at all, which costs a full timeout with no diagnostic. The Julia keyword
is a `Bool`, so you cannot reach that value by accident.

To choose the directory the driver downloads into, pass `downloads_path` to
[`launch`](@ref). It is a launch option, not a context one.

## Dialogs

`alert`, `confirm`, `prompt` and the `beforeunload` prompt all block their page
until somebody answers. One rule follows from that, and it is the important part:

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

The handler is a keyword, and the triggering action is the do-block. One call
takes two functions, so the keyword names the unusual one rather than leaving
argument position to tell them apart.

Read the dialog with [`dialog_type`](@ref), [`message`](@ref) and
[`default_value`](@ref); answer it with [`accept!`](@ref) or
[`dismiss!`](@ref):

```julia
with_dialog(page; handler = d -> accept!(d; prompt_text = "Ada")) do
    click!(locator(page, "#ask-name"))
end
```

`prompt_text` means something only for a `prompt`. Omit it and the dialog submits
its own [`default_value`](@ref). The name is `dialog_type` because `type` is
unusable as a function name in any script that also uses the word.

[`on_dialog!`](@ref) and [`off_dialog!`](@ref) are the unscoped pair, for a
registration that has to outlive one block. Three rules govern them:

- Handlers run on a dispatcher task, one per page, sequentially and in arrival
  order.
- The newest registration wins.
- [`off_dialog!`](@ref) rethrows whatever a handler threw. It also blocks until
  the dialog being handled right now has an answer, so the next line does not
  race it.

A handler that returns without answering gets a dismissal, plus one warning per
registration. Not a hung page, and not one warning per dialog.

### Why this is a registry and not an event

Every other one of these surfaces wraps [`expect_event`](@ref). Dialogs do not,
and the reason is mechanical rather than stylistic. On the wire, "a client
subscribed to `dialog`" and "the driver should stop auto-dismissing" are the
*same message*. Subscribing is what arms the trap.

So an event-shaped API would disarm the safety net by being used. An
`expect_event(page, :dialog)` that timed out would leave the page stuck behind
the next dialog, and a speculative subscription would do the same to pages nobody
was watching. The registry subscribes only once a handler exists to answer, and
unsubscribes when the last one goes away.

`:dialog` is therefore not in the
[event table](@ref "What you can subscribe to"), and asking for it says so:

```julia
expect_event(page, :dialog) do
    click!(locator(page, "#delete"))
end
# ArgumentError: event `:dialog` is not supported yet — deferred: Dialog is
# wrapped, but dialogs are answered with `on_dialog!`/`with_dialog`, not an
# event.
```

The error says *deferred* rather than *unknown*. That is the difference between
"there is an API for this, but not an event-shaped one" and "you made a typo".
Those send a reader to different places.

## Uploads

For an `<input type=file>` you can select, [`set_input_files!`](@ref) is the
whole story:

```julia
set_input_files!(locator(page, "#attachment"), "test/fixtures/upload.csv")
set_input_files!(locator(page, "#attachments"), ["a.csv", "b.csv"])
set_input_files!(locator(page, "#attachment"))                      # clears it
```

You can also supply a file from memory, with nothing on disk:

```julia
set_input_files!(loc; name = "x.csv", mime_type = "text/csv", buffer = bytes)
```

The two forms are mutually exclusive, and passing both raises an `ArgumentError`
*before* anything reaches the driver. So does naming a path that does not exist.
You could leave both checks to the driver, but the driver's complaint arrives
later and names the wire spelling rather than your keyword.

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
it *is* [`set_input_files!`](@ref) applied to the chooser's [`element`](@ref).
One implementation, one place for the rules to be wrong.

Unlike a dialog, an unanswered file chooser does not block the page. It never
receives files, so a test fails by uploading nothing rather than by timing out.

[`is_multiple`](@ref) reports whether the chooser accepts more than one file. A
`webkitdirectory` picker reports `false` on both engines, because selecting a
directory is one selection rather than many.

## Assert on the server, not the client

A test that uploads a file and then asserts on the page mostly tests the page's
own JavaScript. Assert on the receiving end instead:

```julia
set_input_files!(loc, path)
click!(locator(page, "#submit"))
# then check what the server actually received
```

Downloads work the same way round. [`suggested_filename`](@ref) is what the
server said, so an assertion on it checks the response headers rather than the
browser's rendering of them.
