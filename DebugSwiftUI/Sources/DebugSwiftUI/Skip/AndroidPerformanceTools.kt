package debug.swift.android

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.view.Choreographer
import android.view.ViewGroup
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

// Performance: live metrics, frame monitor, hangs, backtraces, leaks and StrictMode.
// Part of AndroidDebugTools: these extensions use the object's state, which lives in AndroidDebugTools.kt.

internal fun AndroidDebugTools.performanceSnapshot(context: Context, featureID: String): String {
    return when (featureID) {
        "memory_warning" -> "Simulated callbacks sent: $simulatedMemoryWarningCount\nThe action calls Application.onLowMemory and foreground Activity low-memory/critical-trim callbacks. Android does not let an app force the operating system to enter real memory pressure."
        "battery" -> {
            val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
            val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            val percent = if (level >= 0 && scale > 0) (level * 100 / scale) else -1
            "Battery: ${percent}%\nCharging: ${status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL}\nPower source: ${intent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0}"
        }
        "disk" -> {
            val files = context.filesDir.walkTopDown().filter { it.isFile }.toList()
            val bytes = files.sumOf { it.length() }
            val io = runCatching { File("/proc/self/io").readLines().filter { it.startsWith("read_bytes:") || it.startsWith("write_bytes:") }.joinToString("\n") }.getOrDefault("I/O counters unavailable")
            "Files directory: ${context.filesDir.absolutePath}\nFiles: ${files.size}\nApp files: ${formatBytes(bytes)}\n$io\nDatabases: ${context.databaseList().joinToString().ifEmpty { "none" }}"
        }
        "frame_drops" -> "Frames sampled: $frameCount\nSlow frames (>32ms): $slowFrameCount\nSlowest frame: ${slowestFrameMs}ms\n\nRecent slow frames:\n" + slowFrameEvents.takeLast(40).asReversed().joinToString("\n").ifEmpty { "No slow frame events captured." }
        "hangs" -> "Detected main-thread stalls: ${events.count { it.contains("main thread stalled") }}\nThreshold: ${MAIN_THREAD_STALL_MS}ms\nRecent events:\n" + events.filter { it.contains("main thread stalled") }.takeLast(20).joinToString("\n").ifEmpty { "No stalls detected." } + "\n\nAndroid process ANRs:\n${platformExitHistory(context, android.app.ApplicationExitInfo.REASON_ANR)}"
        "backtraces" -> backtraces.takeLast(20).asReversed().joinToString("\n\n").ifEmpty { "No backtraces captured. Use Capture to save the current thread stack." }
        "performance_widget" -> {
            val enabled = synchronized(enabledTools) { "performance_widget" in enabledTools }
            if (!enabled) "Performance widget is disabled. Enable it to show live metrics over the host app."
            else "Widget is active in the host app window.\nCPU: ${"%.1f".format(cpuUsagePercent)}%\nFrames/s: $framesPerSecond\nSlow frames: $slowFrameCount"
        }
        "leaks" -> {
            val candidates = destroyedActivities.filter {
                SystemClock.elapsedRealtime() - it.destroyedAtMs >= 5_000L && it.reference.get() != null
            }
            "Destroyed Activities still reachable after 5s: ${candidates.size}\n" +
                candidates.joinToString("\n") { it.className }.ifEmpty { "No retained Activity candidates detected." } +
                "\n\nThis is a reachability heuristic; force a GC or use Android Studio's Memory Profiler to confirm a leak."
        }
        "thread_checker" -> "Current thread: ${Thread.currentThread().name}\nUI thread: ${Looper.myLooper() == Looper.getMainLooper()}\nStrictMode: ${if ("thread_checker" in enabledTools) "enabled" else "disabled"}\nRecent violations:\n" + threadViolations.takeLast(30).asReversed().joinToString("\n\n").ifEmpty { "No StrictMode violations recorded." }
        "super_calls" -> "Android reports missing required Activity super calls with SuperNotCalledException. Recent captured crashes: ${crashRecords.count { it.contains("SuperNotCalledException") }}"
        else -> {
            val runtime = Runtime.getRuntime()
            val used = runtime.totalMemory() - runtime.freeMemory()
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val memory = ActivityManager.MemoryInfo().also(manager::getMemoryInfo)
            val cpu = Process.getElapsedCpuTime()
            cpuUsagePercent = cpuUsage(cpu)
            "CPU usage: ${"%.1f".format(cpuUsagePercent)}%\nProcess memory: ${formatBytes(used)} / ${formatBytes(runtime.maxMemory())}\nNative heap: ${formatBytes(Debug.getNativeHeapAllocatedSize())}\nSystem available memory: ${formatBytes(memory.availMem)}\nCPU time: ${cpu}ms\nFrames sampled: $frameCount (${slowFrameCount} slow)"
        }
    }
}

/** One reading of the live metrics, for the Performance screens. */
fun AndroidDebugTools.performanceSampleJSON(): String {
    val context = appContext ?: return JSONObject().put("error", "Android runtime has not been installed.").toString()
    val runtime = Runtime.getRuntime()
    val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    val memory = ActivityManager.MemoryInfo().also(manager::getMemoryInfo)
    val cpu = Process.getElapsedCpuTime()
    cpuUsagePercent = cpuUsage(cpu)
    val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
    val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
    val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
    val plugged = battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
    val io = runCatching {
        File("/proc/self/io").readLines().associate { it.substringBefore(':') to it.substringAfter(':').trim().toLongOrNull() }
    }.getOrDefault(emptyMap())
    val appFiles = context.filesDir.walkTopDown().filter { it.isFile }.toList()
    return JSONObject()
        .put("cpuPercent", cpuUsagePercent)
        .put("usedMemory", runtime.totalMemory() - runtime.freeMemory())
        .put("maxMemory", runtime.maxMemory())
        .put("nativeHeap", Debug.getNativeHeapAllocatedSize())
        .put("systemAvailable", memory.availMem)
        .put("systemTotal", memory.totalMem)
        .put("lowMemory", memory.lowMemory)
        .put("fps", framesPerSecond)
        .put("frames", frameCount)
        .put("slowFrames", slowFrameCount)
        .put("slowestFrameMs", slowestFrameMs)
        .put("batteryPercent", if (level >= 0 && scale > 0) level * 100 / scale else -1)
        .put("charging", status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL)
        .put("plugged", when (plugged) { BatteryManager.BATTERY_PLUGGED_AC -> "AC"; BatteryManager.BATTERY_PLUGGED_USB -> "USB"; BatteryManager.BATTERY_PLUGGED_WIRELESS -> "Wireless"; else -> "Battery" })
        .put("readBytes", io["read_bytes"] ?: 0L)
        .put("writeBytes", io["write_bytes"] ?: 0L)
        .put("appFileCount", appFiles.size)
        .put("appFileBytes", appFiles.sumOf { it.length() })
        .toString()
}

/** Structured data for one Performance screen: frames, hangs, backtraces, leaks, threads, supercalls, memory. */
fun AndroidDebugTools.performanceDetailJSON(kind: String): String {
    val context = appContext ?: return JSONObject().put("error", "Android runtime has not been installed.").toString()
    val result = JSONObject()
    when (kind) {
        "frames" -> {
            val events = JSONArray()
            slowFrameEvents.takeLast(200).asReversed().forEach { line ->
                val parts = line.split(" · ")
                events.put(JSONObject().put("time", parts.firstOrNull().orEmpty()).put("ms", parts.getOrNull(1)?.removeSuffix("ms")?.toLongOrNull() ?: 0L))
            }
            result.put("frames", frameCount).put("slow", slowFrameCount).put("slowest", slowestFrameMs).put("events", events)
        }
        "hangs" -> {
            val stalls = JSONArray()
            events.filter { it.contains("main thread stalled") }.takeLast(50).asReversed().forEach { event ->
                val first = event.substringBefore('\n')
                stalls.put(
                    JSONObject().put("time", first.substringBefore(" main thread"))
                        .put("ms", first.substringAfter("stalled for ").removeSuffix("ms").toLongOrNull() ?: 0L)
                        .put("stack", event.substringAfter('\n', ""))
                )
            }
            result.put("thresholdMs", MAIN_THREAD_STALL_MS).put("stalls", stalls)
        }
        "backtraces" -> {
            val captures = JSONArray()
            backtraces.takeLast(30).asReversed().forEach { capture ->
                captures.put(JSONObject().put("title", capture.substringBefore('\n')).put("stack", capture.substringAfter('\n', "")))
            }
            result.put("captures", captures)
        }
        "leaks" -> {
            val now = SystemClock.elapsedRealtime()
            val candidates = JSONArray()
            destroyedActivities.filter { now - it.destroyedAtMs >= 5_000L && it.reference.get() != null }.forEach {
                candidates.put(JSONObject().put("id", System.identityHashCode(it).toString(16)).put("className", it.className).put("ageSeconds", (now - it.destroyedAtMs) / 1000))
            }
            result.put("destroyed", destroyedActivities.size).put("candidates", candidates)
        }
        "threads" -> {
            val violations = JSONArray()
            threadViolations.takeLast(50).asReversed().forEach { violation ->
                violations.put(JSONObject().put("title", violation.substringBefore('\n')).put("stack", violation.substringAfter('\n', "")))
            }
            result.put("enabled", synchronized(enabledTools) { "thread_checker" in enabledTools }).put("violations", violations)
        }
        "supercalls" -> {
            val crashes = JSONArray()
            crashRecords.filter { it.contains("SuperNotCalledException") }.takeLast(20).asReversed().forEach { crashes.put(it.take(4_000)) }
            result.put("crashes", crashes)
        }
        "memory" -> {
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val memory = ActivityManager.MemoryInfo().also(manager::getMemoryInfo)
            result.put("simulated", simulatedMemoryWarningCount).put("systemAvailable", memory.availMem)
                .put("systemTotal", memory.totalMem).put("lowMemory", memory.lowMemory)
        }
        else -> result.put("error", "Unknown performance view: $kind")
    }
    return result.toString()
}

/** Saves the call stacks of the main thread, or of every thread, for the Backtraces screen. */
fun AndroidDebugTools.captureBacktrace(allThreads: Boolean, label: String? = null): String {
    val (record, count) = captureBacktraceRecord(allThreads, label)
    return if (record.isEmpty()) "No thread to capture." else "Captured $count thread${if (count == 1) "" else "s"}."
}

/** Captures and stores one backtrace, and returns the stored text with the number of threads. */
internal fun AndroidDebugTools.captureBacktraceRecord(allThreads: Boolean, label: String?): Pair<String, Int> {
    val stacks = Thread.getAllStackTraces()
    val selected = if (allThreads) stacks.entries.sortedBy { it.key.name } else stacks.entries.filter { it.key === Looper.getMainLooper().thread }
    val body = selected.joinToString("\n\n") { (thread, frames) ->
        "Thread ${thread.name} (${thread.state})\n" + frames.joinToString("\n") { "    at $it" }
    }
    val scope = if (allThreads) "All ${selected.size} threads" else "Main thread"
    val record = "${timestamp()} · ${label?.let { "$it · $scope" } ?: scope}\n$body"
    backtraces.add(record)
    trim(backtraces)
    publishEvent("performance", "Backtrace captured")
    return record to selected.size
}

fun AndroidDebugTools.clearBacktraces() {
    backtraces.clear()
}

/** Collects garbage, then reports how many destroyed Activities a GC could not free. */
fun AndroidDebugTools.collectGarbageAndRecheck(): String {
    System.gc()
    Runtime.getRuntime().gc()
    Thread.sleep(400)
    val retained = destroyedActivities.count { it.reference.get() != null && SystemClock.elapsedRealtime() - it.destroyedAtMs >= 5_000L }
    return if (retained == 0) "Garbage collected. No destroyed Activity is still held." else "Garbage collected. $retained destroyed Activit${if (retained == 1) "y is" else "ies are"} still held."
}

/** Blocks the main thread so the hang detector has something to report. */
fun AndroidDebugTools.simulateMainThreadStall(milliseconds: Long): String {
    val duration = milliseconds.coerceIn(100, 5_000)
    mainHandler.post { Thread.sleep(duration) }
    return "Blocking the main thread for ${duration}ms."
}

/** Writes a file on the main thread, a StrictMode disk-write violation, to try the thread checker. */
fun AndroidDebugTools.triggerThreadViolation(): String {
    mainHandler.post {
        runCatching { File(appContext?.cacheDir, "debugswift-strictmode-probe.txt").writeText("probe ${System.currentTimeMillis()}") }
    }
    return if (synchronized(enabledTools) { "thread_checker" in enabledTools }) "Wrote a file on the main thread." else "Wrote a file on the main thread. Turn the checker on first to see it recorded."
}

internal fun AndroidDebugTools.simulateMemoryWarning(): String {
    val application = appContext?.applicationContext as? Application
    val activity = foregroundActivity.get()
    if (application == null && activity == null) return "No Android Application or foreground Activity is available."

    mainHandler.post {
        simulatedMemoryWarningCount += 1
        runCatching { application?.onLowMemory() }
        runCatching { application?.onTrimMemory(android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) }
        if (activity != null) {
            runCatching { activity.onLowMemory() }
            runCatching { activity.onTrimMemory(android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) }
        }
        publishEvent("performance", "Android low-memory callbacks simulated")
    }
    return "Sent low-memory and critical-trim callbacks to the Application and foreground Activity. This does not create real OS memory pressure."
}

internal fun AndroidDebugTools.startAnrWatchdog() {
    scheduler.scheduleAtFixedRate({
        val posted = SystemClock.uptimeMillis()
        val handled = java.util.concurrent.atomic.AtomicBoolean(false)
        // The stack that explains a stall is the one the main thread has while it is still stuck, so
        // sample it from this thread once the threshold passes. Reading it after the main thread
        // recovers would only show the watchdog itself.
        val stuckStack = java.util.concurrent.atomic.AtomicReference<String?>(null)
        scheduler.schedule({
            if (!handled.get()) {
                stuckStack.set(Looper.getMainLooper().thread.stackTrace.take(25).joinToString("\n"))
            }
        }, MAIN_THREAD_STALL_MS, TimeUnit.MILLISECONDS)
        mainHandler.post {
            handled.set(true)
            val delay = SystemClock.uptimeMillis() - posted
            if (delay > MAIN_THREAD_STALL_MS) {
                val stack = stuckStack.get() ?: "The main thread recovered before a stack could be sampled."
                val event = "${timestamp()} main thread stalled for ${delay}ms\n$stack"
                events.add(event)
                trim(events)
                Log.w(TAG, event)
            }
            val showWidget = synchronized(enabledTools) { "performance_widget" in enabledTools }
            if (showWidget) {
                cpuUsagePercent = cpuUsage()
                val currentFrames = frameCount
                framesPerSecond = (currentFrames - previousFrameCount).coerceAtLeast(0)
                previousFrameCount = currentFrames
                debugOverlay?.invalidate()
            }
        }
    }, 1, 1, TimeUnit.SECONDS)
}

fun AndroidDebugTools.recordComposeRender() {
    composeRenderCount++
}

internal fun AndroidDebugTools.cpuUsage(currentCpuMs: Long = Process.getElapsedCpuTime()): Double {
    return synchronized(this) {
        val now = SystemClock.elapsedRealtime()
        val elapsed = now - previousWallTimeMs
        val cpu = currentCpuMs - previousCpuTimeMs
        previousWallTimeMs = now
        previousCpuTimeMs = currentCpuMs
        if (elapsed <= 0L || cpu < 0L) return cpuUsagePercent
        return ((cpu.toDouble() / elapsed) * 100.0 / Runtime.getRuntime().availableProcessors()).coerceIn(0.0, 100.0)
    }
}

internal fun AndroidDebugTools.startFrameMonitor() {
    if (Looper.myLooper() != Looper.getMainLooper()) {
        mainHandler.post { startFrameMonitor() }
        return
    }
    Choreographer.getInstance().postFrameCallback(object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (lastFrameNanos != 0L) {
                val intervalMs = (frameTimeNanos - lastFrameNanos) / 1_000_000L
                frameCount++
                if (intervalMs > 32) {
                    slowFrameCount++
                    slowestFrameMs = maxOf(slowestFrameMs, intervalMs)
                    slowFrameEvents.add("${timestamp()} · ${intervalMs}ms")
                    trim(slowFrameEvents)
                    if (slowFrameCount == 1L || slowFrameCount % 30L == 0L) publishEvent("performance", "Slow frame: ${intervalMs}ms")
                }
            }
            lastFrameNanos = frameTimeNanos
            Choreographer.getInstance().postFrameCallback(this)
        }
    })
}

internal fun AndroidDebugTools.updateOverlay() {
    val activity = foregroundActivity.get() ?: return
    activity.runOnUiThread {
        val enabled = synchronized(enabledTools) { enabledTools.any { it == "grid" || it == "touches" || it == "view_borders" || it == "performance_widget" } }
        val decor = activity.window.decorView as? ViewGroup ?: return@runOnUiThread
        val previous = debugOverlay
        previous?.detach()
        debugOverlay = if (enabled) DebugOverlay(activity).also { overlay ->
            overlay.attachTo(decor)
        } else null
    }
}

/**
 * Makes StrictMode match the thread checker's switch, on the main thread and with the state as
 * it is when that runs, so a change made in between is not undone. `reinstall` applies new options
 * to a policy DebugSwift already installed.
 */
internal fun AndroidDebugTools.reconcileStrictMode(reinstall: Boolean = false) {
    if (Looper.myLooper() != Looper.getMainLooper()) {
        mainHandler.post { reconcileStrictMode(reinstall) }
        return
    }
    val wanted = synchronized(enabledTools) { "thread_checker" in enabledTools }
    when {
        wanted && (!strictModeOwned || reinstall) -> enableStrictMode()
        !wanted && strictModeOwned -> disableStrictMode()
    }
}

internal fun AndroidDebugTools.enableStrictMode() {
    if (Looper.myLooper() != Looper.getMainLooper()) {
        mainHandler.post { enableStrictMode() }
        return
    }
    // Keep the app's own policies once, to put them back when the checker is turned off.
    if (!strictModeOwned) {
        previousThreadPolicy = android.os.StrictMode.getThreadPolicy()
        previousVmPolicy = android.os.StrictMode.getVmPolicy()
    }
    val threadPolicy = android.os.StrictMode.ThreadPolicy.Builder()
            .detectAll()
    if (strictModeFlashScreen) threadPolicy.penaltyFlashScreen()
    if (strictModeLog) threadPolicy.penaltyLog()
    if (Build.VERSION.SDK_INT >= 28) {
        threadPolicy.penaltyListener(java.util.concurrent.Executor { command -> mainHandler.post(command) }) { violation ->
            val stack = violation.stackTraceToString()
            if (strictModeIgnoredClasses.any { stack.contains(it) }) return@penaltyListener
            val detail = "${timestamp()} ${violation.javaClass.simpleName}\n$stack"
            threadViolations.add(detail)
            trim(threadViolations)
            publishEvent("performance", "StrictMode ${violation.javaClass.simpleName}")
        }
    } else {
        threadPolicy.penaltyLog()
    }
    android.os.StrictMode.setThreadPolicy(threadPolicy.build())
    val vmPolicy = android.os.StrictMode.VmPolicy.Builder().detectAll()
    if (Build.VERSION.SDK_INT >= 28) {
        vmPolicy.penaltyListener(java.util.concurrent.Executor { command -> mainHandler.post(command) }) { violation ->
            val detail = "${timestamp()} VM ${violation.javaClass.simpleName}\n${violation.stackTraceToString()}"
            threadViolations.add(detail)
            trim(threadViolations)
            publishEvent("performance", "StrictMode VM ${violation.javaClass.simpleName}")
        }
    } else {
        vmPolicy.penaltyLog()
    }
    android.os.StrictMode.setVmPolicy(vmPolicy.build())
    strictModeOwned = true
}

internal fun AndroidDebugTools.disableStrictMode() {
    if (Looper.myLooper() != Looper.getMainLooper()) {
        mainHandler.post { disableStrictMode() }
        return
    }
    // Only put back what DebugSwift replaced; an app policy DebugSwift never touched stays.
    if (!strictModeOwned) return
    android.os.StrictMode.setThreadPolicy(previousThreadPolicy ?: android.os.StrictMode.ThreadPolicy.LAX)
    android.os.StrictMode.setVmPolicy(previousVmPolicy ?: android.os.StrictMode.VmPolicy.LAX)
    previousThreadPolicy = null
    previousVmPolicy = null
    strictModeOwned = false
}

internal fun AndroidDebugTools.backtraceJSON(capture: String): JSONObject {
    val title = capture.substringBefore('\n')
    return JSONObject()
        .put("id", capture.hashCode().toUInt().toString(16) + "-" + title.hashCode().toUInt().toString(16))
        .put("title", title)
        .put("stack", capture.substringAfter('\n', ""))
}
