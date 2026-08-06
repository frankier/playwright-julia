# API reference

Every exported name, grouped by what it is for rather than alphabetically —
alphabetical order puts `click!` next to `clear_page_errors` and separates
`start_tracing` from `stop_tracing`, which helps nobody.

`checkdocs = :exports` is on, so this page is complete by construction: an
export missing from it fails the build.

```@docs
Playwright
```

## Sessions and lifecycle

```@docs
playwright
launch
install
new_context
new_page
close!
contexts
pages
browser_name
with_page
```

## Objects

```@docs
Browser
BrowserContext
BrowserType
Page
Frame
Locator
ElementHandle
JSHandle
```

## Navigation and capture

```@docs
goto!
title
url
screenshot
pdf
```

## Locator construction

```@docs
locator
nth
selector
frame
is_strict
```

### Reading an element

```@docs
text_content
inner_text
inner_html
get_attribute
input_value
is_visible
is_checked
is_enabled
```

### Acting on an element

```@docs
click!
set_value!
dispatch_event!
element_handle
```

## Frame navigation

```@docs
frames
parent_frame
owner_frame
frame_locator
content_frame
name
```

## Evaluating JavaScript

```@docs
evaluate
evaluate_all
evaluate_handle
eval_on_selector
eval_on_selector_all
dispose!
```

## Assertion functions

```@docs
expect
Not
retry_until
```

## Waiting functions

```@docs
wait_for_selector
wait_for_function
expect_event
wait_for_event
with_events
EventStream
next_event
pending_events
```

## Artifact capture

```@docs
Artifact
start_tracing
stop_tracing
with_tracing
video
save_as!
path
delete_file!
```

## Diagnostic readers

```@docs
console_messages
page_errors
clear_console_messages
clear_page_errors
report_diagnostics
ConsoleMessage
PageError
```

## Timeout settings

```@docs
set_default_timeout!
set_default_navigation_timeout!
```

## Error types

```@docs
PlaywrightError
DriverError
TimeoutError
TargetClosedError
AssertionFailure
```

## Base extensions

These extend their `Base` counterparts rather than taking a new name, so they
work unqualified — `count(loc)`, not `Playwright.count(loc)` — but they do not
appear in `names(Playwright)` and so are outside `checkdocs`' reach. They are
public surface all the same.

```@docs
Base.count
Base.length
Base.first
Base.last
Base.iterate
Base.close
```

## Internals

Not exported, and not part of the supported surface. They are here because the
docstrings above refer to them.

```@docs
Playwright.PlaywrightAPI
Playwright.DEFAULT_TIMEOUT
Playwright.browsers_path
```
