package debug.swift.android

/**
 * The Android runtime's way into DebugSwiftCore, the Swift logic iOS uses. One JNI function takes an
 * operation and JSON arguments and answers JSON, so Kotlin keeps no copy of that logic. The Swift side
 * is `DebugSwiftUI/Android/DebugSwiftCoreBridge.swift`, in the module's native library.
 */
object DebugSwiftCoreBridge {
    init {
        // Loading an already loaded library only registers it for this class loader, which JNI
        // needs to find the function.
        System.loadLibrary("DebugSwiftUI")
    }

    @JvmStatic
    external fun call(operation: String, arguments: String): String
}
