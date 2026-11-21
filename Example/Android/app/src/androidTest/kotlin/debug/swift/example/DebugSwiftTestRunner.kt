package debug.swift.example

import android.app.Application
import androidx.test.runner.AndroidJUnitRunner

/**
 * Thrown on a background thread by the crash test. The app's DebugSwift handler records it and
 * then calls the handler that was installed before it; this runner makes that earlier handler
 * swallow the probe, so the test process survives while every other uncaught exception still
 * reaches the instrumentation and fails the run.
 */
class CrashProbe(message: String) : RuntimeException(message)

class DebugSwiftTestRunner : AndroidJUnitRunner() {
    override fun callApplicationOnCreate(app: Application) {
        val instrumentationHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            if (error !is CrashProbe) instrumentationHandler?.uncaughtException(thread, error)
        }
        // Application.onCreate runs AndroidDebugTools.install, which wraps the handler set above.
        super.callApplicationOnCreate(app)
    }
}
