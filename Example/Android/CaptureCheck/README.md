# CaptureCheck

Checks DebugSwift's Android `URLSession` capture (`DebugSwiftUI/Sources/DebugSwiftUI/Network/DebugSwiftURLSessionCapture.swift`) against swift-corelibs-foundation, on an Android device or emulator:

- a protocol the host app put in its session still answers, and the request is recorded;
- downloads work with a completion handler and with a delegate;
- the session's own timeout applies;
- a large JSON body is masked before it is trimmed;
- a rewrite that lets the request through is delivered once, over a chunked or an empty body;
- a stop from inside the first callback ends the load, for injected answers and for forwarded loads.

```sh
ANDROID_SERIAL=emulator-5554 Example/Android/CaptureCheck/run.sh
```

It needs `adb`, a booted device, and the Swift Android SDK that matches the host toolchain (`skip android sdk install`). The download and timeout checks reach the network.
