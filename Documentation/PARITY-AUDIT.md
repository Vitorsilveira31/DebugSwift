# iOS and Android parity audit

Goal: every DebugSwift capability works on iOS and on Android, with the same shape of screen, and the
code stays in Skip Fuse (Swift) wherever it can. Compose, Android views or Kotlin are used only where
Swift cannot reach the platform.

How each Android entry is rated:

- **Dedicated**: a purpose-built SwiftUI screen, comparable to the iOS one.
- **Generic**: the shared detail screen (a text snapshot plus Refresh/Capture/Export buttons and one
  input field). It runs, but it is not the iOS experience.
- **Gap**: the iOS capability does not exist on Android yet.

The state below was measured on an Android 17 emulator by opening every entry of a host app's debug
panel. That run covered 52 entries and all of them opened without crashing the app; the panel now
has 53 (see the summary), so one entry has not been through that check. Opening a screen says it
loads and renders; it does not say each button does what the iOS one does.

## Summary

| Area | iOS entries | Android entries | Dedicated | Generic | Capability gaps |
| --- | --- | --- | --- | --- | --- |
| Network | 9 | 9 | 9 | 0 | none known |
| Performance | 11 | 11 | 11 | 0 | none known; the rates on the Disk screen are process wide |
| Interface | 9 | 10 | 10 | 0 | none known; the 3D view debugger opens from View Hierarchy |
| Resources | 9 | 10 | 10 | 0 | the Realm browser shows only what the host registers, since Realm lives on the JVM |
| App | 13 | 13 | 13 | 0 | none known |

Android has 53 entries and every one has a dedicated screen.

## Public API

The host-facing API is the same on both platforms: `import DebugSwiftUI` gives `DebugSwift` and
every namespace under it (`App`, `Console`, `Network`, `Resources`, `Performance`,
`PushNotification`, `APNSToken`, `WebSocket`, `WKWebView`, `SwiftUIRender`, `Measurement`). On iOS
it re-exports the DebugSwift module; on Android `DebugSwiftUI/Sources/DebugSwiftUI/AndroidAPI`
declares the same types, members, signatures and main-actor isolation on top of the Android
runtime. `DebugSwiftRuntime.install(...)` starts it on both, and `.debugSwiftPanel()` on the root
view presents the panel when the floating button or `DebugSwift.App.presentDebugger()` asks.

`Example/Sources/DebugSwiftExample/Debugger/APIParityCheck.swift` uses every public member of the
iOS API and is compiled for iOS and for Android, so a missing or different member fails the build.

Members whose types exist only on iOS have an Android counterpart under the same namespace:

| iOS | Android |
| --- | --- |
| `DebugSwift.debugViewController()`, `debugFeatureViewController(for:)` (UIKit) | `DebugSwiftRuntime.panel(onDone:)`, `.debugSwiftPanel()` |
| `App.shared.customControllers` (`UIViewController`) | `App.shared.customTools` (`DebugTool`, SwiftUI) |
| `Resources.shared.configureCoreData(...)`, `configureSwiftData(...)` | `Resources.shared.registerDatabase(named:)`, `registerPreferences(named:)` |
| `APNSToken.didRegister(deviceToken:)` (APNs) | the same call, plus `APNSToken.didRegister(token:)` for the FCM token |
| `PerformanceLeak.controller` / `.view` (UIKit) | `PerformanceLeak.className` (the leaked Activity) |

Where Android cannot do what iOS does, the member exists and says so in its documentation:
`ThreadChecker.enableAutoFix()` records violations (Android cannot move a call that already ran),
`WKWebView.captureRequestBodies` and `captureResponseHeaders` are kept but WebViewClient exposes
neither, `SwiftUIRender` overlays become the Compose render counts, `APNSToken.environment` is
`.unknown` for FCM, `Resources.getAccessibleAppGroups()` is empty, and `Debugger.logEnable` and
`feedbackEnable` are kept for the same code to compile.

Swift `URLSession` traffic on Android is captured and goes through Network Injection as on iOS:
`URLSession.shared` needs nothing and a session the app creates needs
`DebugSwift.Network.shared.injectIntoConfiguration(configuration)` (as on iOS) or
`DebugSwiftRuntime.configure(configuration)`. The request is still sent by Foundation's own HTTP
protocol, or by the next protocol the session itself lists (a host's mock, for example), created
for the same task, so the session's cookies, credentials, timeouts and cache,
the delegate's redirect and challenge decisions, data streamed to a data delegate and download
files behave as without DebugSwift. Two limits: a rewrite that lets the request through replaces
the response a completion handler or `async` call gets, but a data delegate still receives the
real body, which Foundation streams to it directly; and download tasks honor delays and network
failures, not rules that answer with an HTTP response. For a task read through a session delegate
(no completion handler, no `async`), the inspector shows status, headers and timing but not the
body: corelibs hands those chunks from its protocol straight to the session's delegate, which is
fixed when the session is created. A protocol registered only with
`URLProtocol.registerClass(_:)` doesn't answer captured requests: corelibs keeps that registry
internal, so DebugSwift can't consult it, and Foundation's built-in protocols send the request
instead. List such a protocol in the session's `protocolClasses` to keep it. Swift `URLSessionWebSocketTask` sockets are
not captured on Android; OkHttp sockets wrapped in `DebugSwiftWebSocketListener` are.
`Example/Android/CaptureCheck/run.sh` checks this capture against corelibs on a device or emulator:
host protocols, downloads, timeouts, masking of large bodies, rewrites, and stops during injected
and forwarded loads.

## Done so far (verified on an Android 17 emulator)

- Swift network traffic reaches the Kotlin network tools, and the injection rules (delay, HTTP error,
  network error, rewrite) act on Swift requests.
- Resources: files with preview, share and delete; preferences with edit and add; databases with
  tables, paged rows and a SQL console; Keystore aliases; cookies.
- App: crash reports and process exits (no more binary dump), filterable Logcat, deep link opener,
  mock location (confirmed at the OS level on the GPS, network and fused providers), device info,
  custom info and actions, event timeline.
- Performance: live CPU, memory and frame charts, battery, disk throughput, slow frame timeline, main
  thread stalls with the stack the thread was stuck in, ANR reports, backtraces of the main thread or
  all threads, retained Activities with a GC recheck, StrictMode violations, memory warning
  simulation and the on-screen widget.
- Push: a simulator that posts real notifications (scenarios, templates, behavior options, a live
  history with per-entry actions), and the registration token with a copy button; the host app
  reports its Firebase token to it.
- Installed libraries from the process maps and from the APK, the agent debug log with capture on and
  off and the newest entries, and the Realm browser for what the host registers.
- Floating debug button: a draggable button over the app that opens the panel. The setting and the
  position are remembered, and taps on it are kept out of the recorded gestures.
- Interface: a window tree with Android views and Compose semantics (text, description, test tag,
  clicks), a highlight drawn in the app, a measurement tool that gives the gap between two
  elements, a color palette sampled from the screen, the system animation scales, a live
  recomposition rate for Compose that needs no wrapper in the host's UI, and the documentation
  recorder (taps and scrolls are captured by the library itself, and the screenshot is a pixel copy).

## Known defects found while testing

1. **Crash Reports shows raw binary.** Fixed. Recent Android process exits include the tombstone protobuf
   verbatim, so the screen prints control characters (and crashes `uiautomator` when it reads them).
   The exit record should show reason, description, time and a decoded abort message only.
2. **Swift traffic is invisible to the Kotlin network tools.** Fixed. Capture on Android hooks OkHttp and
   WebView. An app whose networking is Swift (Foundation on Android) never reaches
   them, so HTTP, GraphQL, HAR, history and thresholds look empty even while requests happen. The
   Core-based inspector (`NetworkInspectorView`) does see that traffic.
3. **Network injection cannot touch Swift networking.** Fixed; the host wraps its transport call in `NetworkInjection.apply`.
4. **A saved rewrite rule with no method never matched after a restart** (org.json read a JSON null as the string "null"). Fixed.
5. **The hang detector sampled the wrong stack.** It read the main thread after the thread had recovered, so every stall pointed at the detector itself. Fixed: the stack is sampled while the thread is still stuck.
6. **Frames per second reads 0 on an idle screen**, because the Choreographer only counts frames that draw. Left as is.
7. **The HTTP Inspector counted 4xx and 5xx responses as successes.** Fixed: like iOS, only a 2xx response without a transport error is a success.
8. **Swift `URLSession` needed a wrapper.** Fixed: DebugSwift's URL protocol is first in `URLSession.shared`'s configuration, so requests are captured and injected without host code.

Before the fix, injection rules were applied only by the OkHttp interceptor; on iOS a URL protocol
applies them to every session.

## Data plumbing (done)

Completed `DebugSwiftCore.NetworkRecord`s are fed into the Kotlin network store over JNI, so the
inspector, GraphQL, HAR, history and thresholds cover Swift traffic as well as OkHttp. The injection
rules reach Swift requests through the same path. The older Core inspector now duplicates the Kotlin
one and can be retired.

## Area by area

### Network (all dedicated)

| Feature | Rating | Remaining work |
| --- | --- | --- |
| http, graphql, har_export, webview_network, network_encryption | Dedicated | feed Swift records (above) |
| websocket | Dedicated | none beyond OkHttp-only capture |
| network_injection | Dedicated | apply rules to Swift requests |
| network_thresholds | Dedicated | count Swift requests |
| network_history | Dedicated | persist Swift records |

### Performance (all dedicated)

| Feature | Rating | Notes |
| --- | --- | --- |
| performance_overview, battery, disk | Dedicated | live charts; battery and disk keep history only while the screen is open |
| frame_drops | Dedicated | summary, sparkline and a timeline of slow frames. Reads 0 fps on an idle screen |
| hangs | Dedicated | stalls with the stack sampled while the main thread was stuck, plus Android ANR reports |
| backtraces | Dedicated | main thread or all threads |
| leaks | Dedicated | reachability heuristic with a GC recheck; confirm with the Memory Profiler |
| thread_checker | Dedicated | StrictMode on or off and the recorded violations |
| super_calls, memory_warning, performance_widget | Dedicated | |

### Interface

| Feature | Rating | Notes |
| --- | --- | --- |
| touches, view_borders, dark_mode, grid | Dedicated | toggles and settings |
| view_hierarchy | Dedicated | tree of views and Compose semantics with element detail and a highlight in the app, and "Show in 3D": the window taken apart into one layer per view and Compose element, rotated by dragging. Compose layout nodes without semantics are not listed |
| measurement | Dedicated | pick two elements, read gaps, centers and size difference in dp |
| color_palette | Dedicated | dominant colors from a pixel copy of the window; tap to copy a hex value |
| animation_control | Dedicated | sets the three system scales when `WRITE_SECURE_SETTINGS` is granted by adb; otherwise slows View animations in the app and says what is missing |
| render_tracking | Dedicated | recompositions per second and totals for the whole app; a `DebugSwiftComposeProbe` still counts one screen |
| doc_recorder | Dedicated | start recording, close the panel, use the app, capture a screenshot numbered with each tap and scroll |

### Resources (all dedicated)

| Feature | Rating | Notes |
| --- | --- | --- |
| security_audit | Dedicated | none |
| files | Dedicated | browse the app's files, cache and databases; preview text, share, delete |
| preferences, persistent_data | Dedicated | every preference store, with edit, add and delete; the combined screen links to the Keystore |
| keychain (Keystore) | Dedicated | aliases with algorithm, size and hardware backing; key material is never read |
| sqlite, core_data (Room), swift_data (object store) | Dedicated | databases, tables, paged rows and a SQL console |
| realm | Dedicated | shows what the host registers with `DebugSwiftRealmRegistry`; Realm lives on the JVM |
| cookies | Dedicated | grouped by the domains the app's WebViews reported |

### App (all dedicated)

| Feature | Rating | Notes |
| --- | --- | --- |
| console, event_bus | Dedicated | filterable lists |
| crashes | Dedicated | saved reports and process exits; binary tombstones are not printed |
| oslog_console (Logcat) | Dedicated | level and text filters |
| device_info, custom_info, custom_actions | Dedicated | key/value rows and run buttons. Host actions in Swift already have a route through `DebugTool` and `DebugActionGroup` |
| push_simulator | Dedicated | permission, send, scenarios, templates, behavior options and history; posts real notifications |
| push_token | Dedicated | shows the token the app reports with `DebugSwiftRuntime.reportPushToken` and copies it |
| deep_links | Dedicated | opens any URI as a link intent |
| location | Dedicated | mock position for the GPS, network and fused providers (the app must be the chosen mock location app) |
| loaded_libraries | Dedicated | process maps plus the native libraries packed in the APK |
| agent_debug_log | Dedicated | capture on and off, newest entries and sharing the NDJSON file |

### Outside the feature IDs

- **Floating debug button** (iOS): done on Android as `DebugFloatingButton`. The host sets `onTap` to
  open its panel; the person turns it on from the panel.
- **View debugger** (iOS): see `view_hierarchy`.
- **Custom controllers** (iOS `customControllers`): parity already exists in Fuse as `DebugTool`.

## Order of work

All of it is done: Swift network traffic, Resources, App, Performance, Interface, the floating
button, the 3D view debugger and the public API. What remains is what the table notes call out: the
Realm browser depends on the host registering its databases, and Swift WebSocket tasks are not
captured on Android.
