# DebugSwift Example

One app for iOS and Android. Every screen is SwiftUI in the `DebugSwiftExample` module (`Sources/DebugSwiftExample`). On iOS it compiles natively; on Android [Skip Fuse](https://skip.dev) compiles the same Swift for Android and renders the SwiftUI as Compose. Both platforms open the same debug panel, the shared `DebugPanel` from `DebugSwiftUI`: from the toolbar's ladybug, from the "Open debug panel" row, from the floating ball on iOS, and from the floating button on Android (turned on in the panel).

| Path | What it is |
| --- | --- |
| `Package.swift`, `Skip.env` | The Skip package and the app's name, ids and version, shared by both hosts |
| `Sources/DebugSwiftExample/Demos` | Demos that run on both platforms |
| `Sources/DebugSwiftExample/iOS` | Demos that rely on iOS-only frameworks: MapKit, WebKit, Core Data, SwiftData, Hyperion, backtraces |
| `Sources/DebugSwiftExample/Networking` | `ExampleNetworkRules`, the injection rules the Network Injection demo turns on |
| `Darwin/Example.xcodeproj` | The iOS host and the `ExampleTests` suite |
| `Android/` | The Gradle host, its `Main.kt`, and the instrumented tests |

SwiftUI comes first. A screen that SwiftUI cannot express gets a UIKit view on iOS and an Android View or Compose view on Android; the demos that still lack the Android half are the ones under `iOS/`, listed only on iOS.

## Run it

Install Xcode, the Skip CLI (`brew install skiptools/skip/skip`), Android Studio and an Android SDK, then start an Android emulator. Open `Darwin/Example.xcodeproj` and run the `Example` scheme: the app starts on the iOS simulator, and the "Run skip gradle" build phase builds the Android app and launches it on the emulator. `SKIP_ACTION` in `Darwin/Example.xcconfig` picks what that phase does: `launch`, `build`, or `none` for iOS only.

To build only the Android app, without Xcode:

```sh
skip export --project Example --no-ios --android --arch aarch64 --dir build/skip-android
adb install -r build/skip-android/DebugSwiftExample-debug.apk
```

`make run` at the repository root builds and launches the iOS app on the booted simulator; it skips Android unless you pass `SKIP_ACTION=launch`.

## Run the tests

The iOS suite, `ExampleTests`, runs in the `Example.app` host:

```sh
cd Example
bundle exec fastlane test
```

`Android/app/src/androidTest` drives the app on a device: it checks the demo list, opens the debug panel, and looks for a console message logged from Swift, a captured request with its token masked, and a saved crash report. With an emulator or device connected, run:

```sh
cd Example/Android
ANDROID_HOME=~/Library/Android/sdk gradle connectedDebugAndroidTest
```

Set `ANDROID_SERIAL` to pick one device when several are connected. CI builds the APKs for x86_64 with `SKIP_EXPORT_ARCHS=x86_64 gradle assembleDebug assembleDebugAndroidTest`, then runs them on a Linux emulator with `run-instrumented-tests.sh`.

## Network demos on Android

The demos use plain `URLSession`, as on iOS. On Android `DebugSwiftRuntime.install` puts DebugSwift's URL protocol into `URLSession.shared`, so its requests reach the HTTP Inspector and honor Network Injection rules; the TLS demo's own session gets the same through `DebugSwiftRuntime.configure(configuration)`. The Network Injection demo's rules replace the panel's rules for Swift requests until "Make Normal Request"; the panel's rules always apply to OkHttp traffic.

## Add the debugger to an Android host app

The `DebugSwiftAndroid` product is part of the repository’s root Swift package. Add the DebugSwift repository as a Swift package dependency, add the `DebugSwiftUI` product, and use `DebugSwiftAndroidPanel()` as the app’s shared SwiftUI root. `Package.swift` and `Android/app/src/main/kotlin/Main.kt` show how Skip generates the Compose host.

Install the runtime once from the host `Application`:

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        AndroidDebugTools.install(this)
        AndroidDebugTools.registerPreferences("user_preferences")
        DebugSwiftDatabaseBrowser.registerRoomDatabase("app_database")
    }
}
```

Add `DebugSwiftOkHttpInterceptor()` to each OkHttp client whose traffic should be captured or controlled by Network Injection. Request delays, injected failures, HTTP statuses, and response modifier rules apply to requests sent through those clients. Wrap WebSocket listeners with `DebugSwiftWebSocketListener(url, listener)`. The delegate receives an instrumented `WebSocket`, so ordinary outgoing `send` calls are captured; the listener's `sendText` and `sendBinary` helpers are available when code still holds the raw socket. Install `DebugSwiftWebViewClient` on host WebViews. Android cannot intercept every networking stack globally, so clients using a different stack need an equivalent integration hook.

### Network capture by stack

Android has no process-wide hook like iOS's `URLProtocol`, so each networking stack is covered only once the host wires it in:

| Stack | Captured | Injection (delay, failure, status, rewrite) | What the host adds |
| --- | --- | --- | --- |
| OkHttp, and libraries built on it (Retrofit, Coil, Glide's OkHttp integration, Apollo Kotlin) | Method, URL, status, timing, headers, bodies | Yes | `DebugSwiftOkHttpInterceptor()` on each `OkHttpClient` |
| Ktor with the OkHttp engine | Same as OkHttp | Yes | `engine { addInterceptor(DebugSwiftOkHttpInterceptor()) }` |
| OkHttp WebSockets | Connection, frames in both directions | No | Wrap the listener in `DebugSwiftWebSocketListener(url, listener)` |
| Swift `URLSession` (Foundation on Android) | Method, URL, status, timing, headers, bodies | Yes | Nothing for `URLSession.shared`; `DebugSwiftRuntime.configure(configuration)` for a session the app creates |
| WebView | URL and host of each load only; WebViewClient exposes no status, timing or bodies | No | `DebugSwiftWebViewClient` on each WebView |
| `HttpURLConnection`, Volley, Cronet, Ktor CIO or Android engines | Not captured | No | Record each exchange yourself with `AndroidDebugTools.recordNetwork(...)`, or move the client to OkHttp |

Every captured request goes through `DebugSwiftNetworkSanitizer` before it is listed, saved or exported; set its rules from Swift with `DebugSwiftRuntime.configureNetworkSanitizer(_:)` or from Kotlin with `DebugSwiftNetworkSanitizer.configure(...)`.

The runtime also exposes host hooks for custom actions and diagnostic values (`registerAction`, `registerInfo`), FCM tokens (`reportPushToken`), location (`reportLocation`), Room databases, and Realm projections (`DebugSwiftRealmRegistry.register`). Configure request thresholds with `AndroidDebugTools.setRequestThreshold(limit, windowSeconds)`, `setRequestTracking(enabled)`, `setThresholdBlocking(enabled)`, and `setThresholdAlert(emoji, message)`. Register endpoint limits with `setEndpointRequestThreshold(endpoint, limit, windowSeconds)` and remove them with `removeEndpointRequestThreshold(endpoint)`; inspect counts and logs with `getCurrentRequestCount(endpoint)` and `getThresholdLogs()`. Forward Activity touch events to `AndroidDebugTools.recordTouch(event)` and wrap a Compose subtree in `DebugSwiftComposeProbe` to collect those interface diagnostics.

To share exported files from the Android system Sharesheet, merge the Example's `FileProvider` entry into the host app manifest and add `debugswift_file_paths.xml` under `res/xml`. Use authority `${applicationId}.debugswift.fileprovider`, disable provider export, enable URI grants, and expose only app-private `cache-path` and `files-path` locations. The Example's manifest and resource file show the exact configuration. Export actions then open the native Android Sharesheet with a read-only content URI.

### Push notification simulation

The Push Notifications tool supports local notifications without an FCM server. Add `POST_NOTIFICATIONS` to the host manifest and enable the simulator before posting. Android 13 and newer request permission at runtime:

```kotlin
AndroidDebugTools.setPushSimulationEnabled(true)
AndroidDebugTools.simulatePushNotification(
    title = "New Message",
    body = "You have a message from Alex",
    subtitle = "Inbox",
    delaySeconds = 3,
    userInfo = mapOf("type" to "message", "sender" to "Alex")
)
AndroidDebugTools.simulatePushNotificationFromTemplate("Message")
AndroidDebugTools.runPushNotificationScenario("messageFlow")
AndroidDebugTools.updatePushNotificationSetting("playSound", "false")
```

The panel's Create action accepts `title|body|delay|subtitle|badge|sound|category|key=value,key2=value2`. Scenarios are `messageFlow`, `newsUpdates`, `marketingCampaign`, `systemAlerts`, or a single `customFlow|title|body|delay`. The History page action browses all retained records in pages of 20; export includes the full history.

Kotlin hosts can also use `simulateMessagePush`, `simulateReminderPush`, `simulateNewsPush`, and `simulateMarketingPush`; manage detailed templates with `addPushNotificationTemplate` and `removePushNotificationTemplate`; and inspect, clear, remove, resend, or mark a notification interacted with through the corresponding `AndroidDebugTools` methods. Delayed local notifications run while the app process remains alive. Configuration, templates, and notification history are stored in app-private preferences.

Use `DebugSwiftRuntime.log("message")` or `AndroidDebugTools.log("message")` to add app messages to Console. The optional Agent Debug Log can be enabled in the panel; it writes NDJSON to the app-private `files/agent-debug.ndjson` and can be exported from the same screen. The Performance Widget draws live metrics inside the host Activity. Grid spacing and color are set in the Grid Overlay detail, for example `24,#663399FF`.

## Platform equivalents

The debugger category navigation, feature catalogues, device information, push token, Console, request threshold and injection settings, Security Audit, and host custom info/actions are shared SwiftUI on iOS and Android. Skip Fuse turns those views into Compose on Android. UIKit representables are reserved for native iOS inspectors and system integrations that cannot share their underlying platform APIs. Android uses Kotlin platform implementations for lifecycle, performance, storage, notifications, and Compose diagnostics.

Android Room/SQLite is the storage equivalent for Core Data and SwiftData. Android Keystore aliases replace Keychain inspection; secret key material remains non-exportable. Some platform data, such as a push token or a Realm schema projection, must be supplied by the host app through the hooks above. Network capture also requires the host networking integration described above.
