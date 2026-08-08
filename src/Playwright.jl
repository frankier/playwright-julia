"""
    Playwright

Drive real browsers — Chromium and Firefox — from Julia, through the official
Playwright automation engine.

```julia
using Playwright

playwright() do pw
    browser = launch(pw.chromium; headless=true)
    page = new_page(browser)
    goto!(page, "https://example.com")
    println(title(page))
    close!(browser)
end
```
"""
module Playwright

using JSON
using Scratch
using Downloads
using Base64
using Dates
using p7zip_jll: p7zip

export playwright,
    install,
    # The channel-owner types a caller actually names — in a type annotation,
    # an `isa` check, or a `Vector{Page}`. The rest of the generated channel
    # layer stays internal.
    Browser,
    BrowserContext,
    BrowserType,
    Page,
    Frame,
    Locator,
    ElementHandle,
    JSHandle,
    launch,
    new_page,
    close!,
    goto!,
    title,
    locator,
    glob_to_regex,
    # The network surface: Request and Response
    Request,
    Response,
    headers,
    headers_array,
    raw_headers,
    resource_type,
    is_navigation_request,
    redirected_from,
    post_data,
    post_data_string,
    request,
    response,
    status,
    status_text,
    ok,
    body,
    text,
    json,
    method,
    RequestFailure,
    error_text,
    APIResponse,
    fetch_uid,
    expect_request,
    expect_response,
    # Route interception
    Route,
    route!,
    unroute!,
    unroute_all!,
    with_route,
    abort!,
    continue!,
    fulfill!,
    RouteRegistration,
    # HAR replay
    route_from_har,
    with_har,
    # HAR recording
    HarRecording,
    start_har_recording!,
    stop_har_recording!,
    with_har_recording,
    # WebSocket routing
    WebSocketRoute,
    WebSocketRouteRegistration,
    route_web_socket!,
    unroute_web_socket!,
    with_web_socket_route,
    # Mock or proxy, and the messages
    connect!,
    send_to_page!,
    send_to_server!,
    close_ws!,
    # The route's own events
    on_message_from_page!,
    on_message_from_server!,
    on_close!,
    click!,
    text_content,
    input_value,
    set_value!,
    screenshot,
    screenshot_bytes,
    pdf,
    pdf_bytes,
    save_as!,
    # Uploads
    set_input_files!,
    FileChooser,
    expect_file_chooser,
    element,
    is_multiple,
    set_files!,
    # Dialogs
    Dialog,
    dialog_type,
    message,
    default_value,
    accept!,
    dismiss!,
    on_dialog!,
    off_dialog!,
    with_dialog,
    # Downloads
    Download,
    expect_download,
    suggested_filename,
    artifact,
    cancel!,
    failure,
    path,
    delete_file!,
    start_tracing!,
    stop_tracing!,
    with_tracing,
    video,
    Artifact,
    with_page,
    report_diagnostics,
    evaluate,
    evaluate_handle,
    eval_on_selector,
    eval_on_selector_all,
    dispose!,
    nth,
    inner_text,
    inner_html,
    get_attribute,
    is_visible,
    is_checked,
    is_enabled,
    dispatch_event!,
    frames,
    parent_frame,
    url,
    frame_name,
    frame_locator,
    content_frame,
    owner_frame,
    new_context,
    launch_persistent_context,
    contexts,
    pages,
    console_messages,
    page_errors,
    clear_console_messages!,
    clear_page_errors!,
    ConsoleMessage,
    PageError,
    set_default_timeout!,
    set_default_strict!,
    set_default_navigation_timeout!,
    evaluate_all,
    element_handle,
    frame,
    selector,
    is_strict,
    browser_name,
    expect,
    Not,
    retry_until,
    wait_for_selector,
    wait_for_function,
    expect_event,
    wait_for_event,
    with_events,
    next_event,
    pending_events,
    EventStream,
    PlaywrightError,
    DriverError,
    TimeoutError,
    TargetClosedError,
    AssertionFailure

include("errors.jl")
include("driver.jl")
include("transport.jl")
include("connection.jl")
include("generated/channels.jl")
include("serializers.jl")
include("objects.jl")
include("timeouts.jl")
include("api/globs.jl")
include("api/events.jl")
include("api/lifecycle.jl")
include("api/navigation.jl")
include("api/locators.jl")
include("api/waiting.jl")
include("api/expect.jl")
include("api/frames.jl")
include("api/evaluate.jl")
include("api/diagnostics.jl")
include("api/artifacts.jl")
include("api/downloads.jl")
# Network: after events.jl, whose Subscription the route dispatcher holds, and
# after lifecycle.jl, whose name_value_array it mirrors.
include("api/network.jl")
include("api/routing.jl")
# After routing.jl: HAR replay is a route! handler with a release hook,
# so it needs route!, the settle verbs and RouteRegistration to exist.
include("api/har.jl")
# After routing.jl: reuses its raise_collected, and its dispatcher pattern.
# After routing.jl: third use of its registry + dispatcher shape, and it
# reuses raise_collected and driver_pattern.
include("api/websockets.jl")
include("api/dialogs.jl")
include("api/uploads.jl")
include("api/apirequest.jl")
include("api/fixtures.jl")

end # module
