package debug.swift.android

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Debug
import android.os.Process
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.util.Date
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject
import okhttp3.Call

// App tools: crash capture, Logcat, device info, events and the agent debug log.
// Part of AndroidDebugTools: these extensions use the object's state, which lives in AndroidDebugTools.kt.

/**
 * Writes `agent-snapshot.json` next to the agent log: app, device, current resource use and the
 * latest requests, written by DebugSwiftCore's `AgentSnapshot` (Documentation/AGENT-SNAPSHOT.md).
 * Stored records are already sanitized, so their URLs go out as they are.
 */
fun AndroidDebugTools.writeAgentSnapshot(): JSONObject {
    val context = appContext ?: return JSONObject().put("error", "Android runtime has not been installed.")
    val sample = JSONObject(performanceSampleJSON())
    val packageInfo = runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull()
    val build = packageInfo?.let { if (Build.VERSION.SDK_INT >= 28) it.longVersionCode else @Suppress("DEPRECATION") it.versionCode.toLong() }
    val network = JSONArray()
    networkRecords.toList().filter { it.source == "http" }.takeLast(50).forEach { record ->
        network.put(JSONObject()
            .put("method", record.method)
            .put("url", record.url)
            .put("status", record.status)
            .put("durationMs", record.durationMs)
            .apply { if (record.error.isNotEmpty()) put("error", record.error) })
    }
    val logFile = File(context.filesDir, AGENT_LOG_FILENAME)
    // DebugSwiftCore builds the file, so both platforms write the same `AgentSnapshot`.
    val input = JSONObject()
        .put("app", JSONObject()
            .put("bundleId", context.packageName)
            .put("version", packageInfo?.versionName.orEmpty())
            .put("build", build?.toString().orEmpty()))
        .put("device", JSONObject()
            .put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
            .put("osVersion", "Android ${Build.VERSION.RELEASE}"))
        .put("metrics", JSONObject()
            .put("cpuPercent", sample.optDouble("cpuPercent", 0.0))
            .put("memoryBytes", sample.optLong("usedMemory").toDouble())
            .put("fps", sample.optDouble("fps", 0.0)))
        .put("network", network)
        .put("agentLog", JSONObject()
            .put("path", logFile.absolutePath)
            .put("enabled", agentLogEnabled)
            .put("sessionId", agentLogSessionID))
    val snapshot = JSONObject(DebugSwiftCoreBridge.call("agent.snapshot", input.toString())).optString("json")
    val file = File(context.filesDir, "agent-snapshot.json")
    return runCatching {
        file.writeText(snapshot)
        appendAgentEntry(
            kind = "lifecycle",
            location = "AgentDebugLog.writeSnapshot",
            message = "agent snapshot written",
            data = mapOf("path" to file.absolutePath)
        )
        JSONObject().put("path", file.absolutePath).put("message", "Snapshot written to ${file.name}.")
    }.getOrElse { JSONObject().put("error", "Could not write the snapshot: ${it.message}") }
}

/** Structured state for the Agent Debug Log screen: capture state, file and the latest entries. */
fun AndroidDebugTools.agentLogStateJSON(): String {
    val context = appContext ?: return JSONObject().put("error", "Android runtime has not been installed.").toString()
    val file = File(context.filesDir, AGENT_LOG_FILENAME)
    val entries = JSONArray()
    runCatching { file.readLines(Charsets.UTF_8).takeLast(80).asReversed() }.getOrDefault(emptyList()).forEach { line ->
        val entry = runCatching { JSONObject(line) }.getOrNull() ?: return@forEach
        entries.put(
            JSONObject().put("time", entry.optLong("timestamp")).put("kind", entry.optString("kind"))
                .put("location", entry.optString("location")).put("message", entry.optString("message"))
        )
    }
    return JSONObject().put("enabled", agentLogEnabled).put("session", agentLogSessionID).put("path", file.absolutePath)
        .put("size", if (file.exists()) file.length() else 0L).put("entries", entries).toString()
}

internal fun AndroidDebugTools.logcatSnapshot(): String {
    val result = runCatching {
        val process = ProcessBuilder("logcat", "-d", "-t", "500", "--pid=${Process.myPid()}")
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().use { it.readText() }
        val exitCode = process.waitFor()
        if (exitCode != 0) return "Android Logcat is unavailable (exit $exitCode):\n${output.takeLast(8_000)}"
        output
    }.getOrElse { return "Android Logcat is unavailable: ${it.message ?: it.javaClass.simpleName}" }
    val filtered = result.lineSequence()
        .filter { logcatFilter.isBlank() || it.contains(logcatFilter, ignoreCase = true) }
        .toList()
        .takeLast(300)
        .joinToString("\n")
        .takeLast(128_000)
    val filterSummary = logcatFilter.takeIf { it.isNotBlank() }?.let { "\nFilter: $it" }.orEmpty()
    return "Android Logcat records for this process PID ${Process.myPid()}$filterSummary\n\n" +
        filtered.ifEmpty { "No matching Logcat records are currently available." }
}

internal fun AndroidDebugTools.appSnapshot(context: Context, featureID: String): String {
    return when (featureID) {
        "crashes" -> "Saved crash reports:\n" + crashRecords.takeLast(20).asReversed().joinToString("\n\n") { it }.ifEmpty { "No uncaught crash reports saved by DebugSwift." } + "\n\nRecent Android process exits:\n${platformExitHistory(context)}"
        "console" -> JSONArray().also { entries -> consoleRecords.forEach { entries.put(it) } }.toString()
        "oslog_console" -> logcatSnapshot()
        "push_token" -> pushToken
        "push_simulator" -> pushNotificationSnapshot(context)
        "custom_actions" -> synchronized(customActions) { customActions.keys.toList() }.joinToString("\n").ifEmpty { "No custom actions registered by the host app." }
        "custom_info" -> synchronized(customInfo) { customInfo.entries.joinToString("\n") { "${it.key}: ${it.value}" } }.ifEmpty { "No host diagnostic values registered." }
        "deep_links" -> lastIntentDescription.ifEmpty { "No deep-link intent received. Call reportIntent(intent) from your host Activity." }
        "loaded_libraries" -> {
            val appInfo = context.applicationInfo
            val dexFiles = (listOf(appInfo.sourceDir) + appInfo.splitSourceDirs.orEmpty()).joinToString("\n")
            "App package: ${context.packageName}\nInstalled DEX files:\n$dexFiles\nNative library directory: ${appInfo.nativeLibraryDir}\nSupported ABIs: ${Build.SUPPORTED_ABIS.joinToString()}\nNative heap: ${formatBytes(Debug.getNativeHeapAllocatedSize())}\nClass loader: ${context.classLoader.javaClass.name}"
        }
        "location" -> lastLocation
        "event_bus" -> events.takeLast(100).asReversed().joinToString("\n").ifEmpty { "No diagnostic events published yet." }
        "agent_debug_log" -> agentDebugLogSnapshot(context)
        "device_info" -> deviceInfo(context)
        else -> deviceInfo(context)
    }
}

/** Installs or removes DebugSwift's crash handler to match `crashCaptureEnabled`. */
internal fun AndroidDebugTools.applyCrashCapture() {
    synchronized(this) {
        if (crashCaptureEnabled) {
            if (crashHandler == null && appContext != null) installCrashHandler()
        } else {
            val installed = crashHandler ?: return
            // A handler the app installed after ours may still call ours: from now on it only forwards.
            crashHandlerActive?.set(false)
            crashHandlerActive = null
            // Put the app's own handler back, unless someone installed another one after ours.
            if (Thread.getDefaultUncaughtExceptionHandler() === installed) {
                Thread.setDefaultUncaughtExceptionHandler(handlerBeforeCrashCapture)
            }
            crashHandler = null
            handlerBeforeCrashCapture = null
        }
    }
}

internal fun AndroidDebugTools.installCrashHandler() {
    val original = Thread.getDefaultUncaughtExceptionHandler()
    handlerBeforeCrashCapture = original
    val active = java.util.concurrent.atomic.AtomicBoolean(true)
    crashHandlerActive = active
    val handler = Thread.UncaughtExceptionHandler { thread, error ->
        if (!active.get()) {
            original?.uncaughtException(thread, error)
            return@UncaughtExceptionHandler
        }
        val writer = StringWriter()
        error.printStackTrace(PrintWriter(writer))
        val record = "${timestamp()} · ${thread.name}\n${writer}"
        crashRecords.add(record)
        trim(crashRecords)
        appContext?.let { context ->
            runCatching { File(context.filesDir, "debugswift-crash-${System.currentTimeMillis()}.txt").writeText(record) }
        }
        appendAgentEntry(
            kind = "crash",
            location = thread.name,
            message = error.message ?: error.javaClass.name,
            data = mapOf("exception" to error.javaClass.name, "stackTrace" to writer.toString()),
            writeImmediately = true
        )
        publishEvent("app", "Uncaught ${error.javaClass.simpleName}")
        original?.uncaughtException(thread, error)
    }
    crashHandler = handler
    Thread.setDefaultUncaughtExceptionHandler(handler)
}

internal fun AndroidDebugTools.loadCrashHistory(context: Context) {
    context.filesDir.listFiles()
        ?.filter { it.isFile && it.name.startsWith("debugswift-crash-") }
        ?.sortedBy { it.lastModified() }
        ?.takeLast(20)
        ?.forEach { file ->
            runCatching { crashRecords.add(file.readText().take(256_000)) }
        }
    trim(crashRecords)
}

internal fun AndroidDebugTools.deviceInfo(context: Context): String {
    val packageInfo = if (Build.VERSION.SDK_INT >= 33) {
        context.packageManager.getPackageInfo(context.packageName, android.content.pm.PackageManager.PackageInfoFlags.of(0))
    } else {
        @Suppress("DEPRECATION") context.packageManager.getPackageInfo(context.packageName, 0)
    }
    val display = context.resources.displayMetrics
    val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    val memoryInfo = ActivityManager.MemoryInfo().also(activityManager::getMemoryInfo)
    @Suppress("DEPRECATION")
    val versionCode = if (Build.VERSION.SDK_INT >= 28) packageInfo.longVersionCode else packageInfo.versionCode.toLong()
    return "App: ${context.packageName}\nVersion: ${packageInfo.versionName ?: "unknown"} ($versionCode)\nAndroid: ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})\nDevice: ${Build.MANUFACTURER} ${Build.MODEL}\nHardware: ${Build.HARDWARE}\nDisplay: ${display.widthPixels} × ${display.heightPixels} @ ${display.densityDpi}dpi\nSystem memory: ${formatBytes(memoryInfo.totalMem)}"
}

internal fun AndroidDebugTools.platformExitHistory(context: Context, reasonFilter: Int? = null): String {
    if (Build.VERSION.SDK_INT < 30) return "Android does not expose historical process exit details on this version."
    val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    val exits = manager.getHistoricalProcessExitReasons(context.packageName, 0, 10)
        .filter { reasonFilter == null || it.reason == reasonFilter }
    return exits.joinToString("\n\n") { exit ->
        val reason = when (exit.reason) {
            android.app.ApplicationExitInfo.REASON_ANR -> "ANR"
            android.app.ApplicationExitInfo.REASON_CRASH -> "Java/Kotlin crash"
            android.app.ApplicationExitInfo.REASON_CRASH_NATIVE -> "Native crash"
            android.app.ApplicationExitInfo.REASON_LOW_MEMORY -> "Low memory"
            android.app.ApplicationExitInfo.REASON_USER_REQUESTED -> "User requested"
            else -> "Reason ${exit.reason}"
        }
        val trace = runCatching { exit.traceInputStream?.bufferedReader()?.use { it.readText().take(32_000) } }.getOrNull()
        "${Date(exit.timestamp)} · $reason · ${exit.status}\n${exit.description.orEmpty()}" +
            (trace?.takeIf { it.isNotBlank() }?.let { "\n$it" } ?: "")
    }.ifEmpty { "No matching process exit records reported by Android." }
}

internal fun AndroidDebugTools.publishEvent(domain: String, message: String) {
    val eventTimestamp = System.currentTimeMillis()
    events.add("${timestamp()} [$domain] $message")
    trim(events)
    val kind = when {
        domain == "network" -> "network"
        message.startsWith("Activity ") || message.startsWith("Intent ") -> "lifecycle"
        else -> "event"
    }
    appendAgentEntry(
        kind = kind,
        location = domain,
        message = message,
        data = mapOf("domain" to domain),
        timestampMs = eventTimestamp
    )
}

internal fun AndroidDebugTools.agentDebugLogSnapshot(context: Context): String {
    val file = File(context.filesDir, AGENT_LOG_FILENAME)
    val recentEntries = runCatching { file.readLines(Charsets.UTF_8).takeLast(20) }.getOrDefault(emptyList())
    return "Capture: ${if (agentLogEnabled) "ON" else "OFF"}\n" +
        "Session: $agentLogSessionID\n" +
        "Path: ${file.absolutePath}\n" +
        "Size: ${formatBytes(file.length())}\n" +
        "Recent entries:\n" + recentEntries.joinToString("\n").ifEmpty { "No records yet. Enable capture to collect events." }
}

internal fun AndroidDebugTools.appendAgentEntry(
    kind: String,
    location: String,
    message: String,
    data: Map<String, Any?> = emptyMap(),
    timestampMs: Long = System.currentTimeMillis(),
    writeImmediately: Boolean = false
) {
    if (!agentLogEnabled) return
    val context = appContext ?: return
    val payload = org.json.JSONObject()
        .put("sessionId", agentLogSessionID)
        .put("location", location)
        .put("message", message.take(16_000))
        .put("kind", kind)
        .put("hypothesisId", "")
        .put("runId", "debugswift-android")
        .put("timestamp", timestampMs)
    if (data.isNotEmpty()) {
        val dataJSON = org.json.JSONObject()
        data.forEach { (key, value) -> dataJSON.put(key, value) }
        payload.put("data", dataJSON)
    }
    val line = payload.toString() + "\n"
    val writeRecord = {
        runCatching {
            val file = File(context.filesDir, AGENT_LOG_FILENAME)
            if (file.length() + line.toByteArray(Charsets.UTF_8).size > MAX_AGENT_LOG_BYTES) {
                val previous = File(context.filesDir, "$AGENT_LOG_FILENAME.previous")
                previous.delete()
                file.renameTo(previous)
            }
            file.appendText(line, Charsets.UTF_8)
        }
    }
    if (writeImmediately) writeRecord() else persistenceExecutor.execute { writeRecord() }
}

/** Whether a console line passes the host's `ignoredLogs` and `onlyLogs` filters. */
internal fun AndroidDebugTools.consoleAccepts(message: String): Boolean {
    if (consoleIgnoredLogs.any { it.isNotEmpty() && message.contains(it) }) return false
    val only = consoleOnlyLogs.filter { it.isNotEmpty() }
    return only.isEmpty() || only.any { message.contains(it) }
}
