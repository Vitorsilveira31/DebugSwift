package debug.swift.android

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.ClipData
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.net.Uri
import android.util.Log
import android.view.Choreographer
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.MimeTypeMap
import android.security.keystore.KeyInfo
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.lang.ref.WeakReference
import java.security.KeyStore
import java.security.KeyFactory
import java.security.PrivateKey
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.zip.ZipFile
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.io.IOException
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONArray
import org.json.JSONObject
import okhttp3.WebSocket
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.roundToInt

/** Android implementations for platform services that have no UIKit equivalent. */
object AndroidDebugTools {
    internal const val TAG = "DebugSwift"
    internal const val PREFS = "debugswift.android"
    internal const val MAX_RECORDS = 500
    internal const val MAX_NETWORK_HISTORY_RECORDS = 10_000
    internal const val NETWORK_HISTORY_RETENTION_MS = 7L * 24 * 60 * 60 * 1_000
    internal const val MAX_WEBSOCKET_CONNECTIONS = 200
    internal const val MAX_WEBSOCKET_FRAMES = 1000
    internal const val MAIN_THREAD_STALL_MS = 700L
    internal const val NOTIFICATION_CHANNEL = "debugswift_local_tests"
    internal const val PUSH_HISTORY_PAGE_SIZE = 20
    internal const val PUSH_STATE_PREFS = "DebugSwift.PushNotifications"
    internal const val THRESHOLD_STATE_PREFS = "DebugSwift.NetworkThreshold"
    internal const val NETWORK_INJECTION_STATE_PREFS = "DebugSwift.NetworkInjection"
    internal const val PUSH_NOTIFICATION_ID_EXTRA = "debugswift_notification_id"
    internal const val AGENT_LOG_FILENAME = "agent-debug.ndjson"
    internal const val MAX_AGENT_LOG_BYTES = 5L * 1024L * 1024L

    @Volatile internal var appContext: Context? = null
    @Volatile internal var foregroundActivity = WeakReference<Activity>(null)
    internal val mainHandler = Handler(Looper.getMainLooper())
    internal val scheduler = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "DebugSwiftMonitor").apply { isDaemon = true }
    }
    internal val persistenceExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "DebugSwiftHistory").apply { isDaemon = true }
    }
    internal val networkRecords = CopyOnWriteArrayList<NetworkRecord>()
    internal val networkHistoryRecords = CopyOnWriteArrayList<NetworkRecord>()
    @Volatile internal var currentNetworkSessionID = UUID.randomUUID().toString()
    internal val webSocketRecords = CopyOnWriteArrayList<String>()
    internal val webSocketConnections = CopyOnWriteArrayList<WebSocketConnectionRecord>()
    internal val webSocketByInstance = ConcurrentHashMap<WebSocket, String>()
    internal val activeWebSockets = ConcurrentHashMap<String, WebSocket>()
    internal val legacyWebSocketIDs = ConcurrentHashMap<String, String>()
    @Volatile internal var selectedWebSocketConnectionID = ""
    @Volatile internal var selectedWebSocketFrameID = ""
    @Volatile internal var webSocketFilter = ""
    @Volatile internal var webSocketDirectionFilter = ""
    internal val consoleRecords = CopyOnWriteArrayList<String>()
    internal val crashRecords = CopyOnWriteArrayList<String>()
    internal val backtraces = CopyOnWriteArrayList<String>()
    internal val threadViolations = CopyOnWriteArrayList<String>()
    internal val events = CopyOnWriteArrayList<String>()
    internal val slowFrameEvents = CopyOnWriteArrayList<String>()
    internal val recentTouches = CopyOnWriteArrayList<Pair<Float, Float>>()
    internal val recordedInteractions = CopyOnWriteArrayList<RecordedInteraction>()
    internal val pushHistory = CopyOnWriteArrayList<PushNotificationRecord>()
    internal val pushTemplates = CopyOnWriteArrayList<PushNotificationTemplate>()
    internal val pendingPushNotifications = ConcurrentHashMap<String, ScheduledFuture<*>>()
    /** Which scheduled delivery owns each notification id; see `schedulePush`. */
    internal val pushScheduleOwners = ConcurrentHashMap<String, Any>()
    internal val notificationExecutor = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "DebugSwiftNotifications").apply { isDaemon = true }
    }
    internal val registeredPreferences = CopyOnWriteArrayList<String>()
    internal val customInfo = linkedMapOf<String, String>()
    internal val customActions = linkedMapOf<String, () -> Unit>()
    internal val enabledTools = mutableSetOf("network_injection")
    internal val agentLogSessionID = UUID.randomUUID().toString()
    @Volatile internal var agentLogEnabled = false
    @Volatile internal var logcatFilter = ""
    internal val destroyedActivities = CopyOnWriteArrayList<DestroyedActivity>()
    internal val webViewHosts = CopyOnWriteArrayList<String>()
    internal var debugOverlay: DebugOverlay? = null
    @Volatile internal var activeTouchStart: Pair<Float, Float>? = null
    @Volatile internal var currentFilePath = "files"
    internal val gridColors = listOf(Color.RED, Color.BLUE, Color.GREEN, Color.YELLOW, Color.WHITE, Color.GRAY)
    @Volatile internal var gridSpacingDp = 28f
    @Volatile internal var gridOpacity = 0.5f
    @Volatile internal var gridColorIndex = 0
    @Volatile internal var gridColor = gridColors[0]
    @Volatile internal var simulatedMemoryWarningCount = 0
    internal var lastLocation = "No location has been reported by the host app."
    internal var pushToken = "No FCM token has been reported by the host app."
    @Volatile internal var pushStateLoaded = false
    @Volatile internal var pushEnabled = false
    @Volatile internal var pushShowInForeground = true
    @Volatile internal var pushPlaySound = true
    @Volatile internal var pushShowBadge = true
    @Volatile internal var pushAutoInteraction = false
    @Volatile internal var pushInteractionDelaySeconds = 3.0
    @Volatile internal var pushSimulateRealPush = false
    @Volatile internal var pushDefaultSound = "default"
    @Volatile internal var pushMaxHistoryCount = 100
    @Volatile internal var appInForeground = false
    @Volatile internal var pushHistoryPage = 1
    @Volatile internal var androidNotificationsEnabled = true
    @Volatile internal var androidNotificationSettingsLoaded = false
    @Volatile internal var thresholdTrackingEnabled = false
    internal var thresholdLimit = 1000
    internal var thresholdWindowMs = 60_000L
    internal var thresholdStartMs = 0L
    internal var thresholdCount = 0
    @Volatile internal var thresholdBlockRequests = false
    @Volatile internal var thresholdAlertEmoji = "⚠️"
    @Volatile internal var thresholdAlertMessage = "Request limit exceeded!"
    internal data class EndpointThresholdLimit(val limit: Int, val windowMs: Long)
    internal data class EndpointThresholdCount(val timestamps: java.util.ArrayDeque<Long> = java.util.ArrayDeque())
    internal data class ThresholdBreachRecord(
        val timestampMs: Long,
        val requestCount: Int,
        val limit: Int,
        val endpoint: String,
        val message: String
    )
    internal val endpointThresholdLimits = ConcurrentHashMap<String, EndpointThresholdLimit>()
    internal val endpointThresholdCounts = ConcurrentHashMap<String, EndpointThresholdCount>()
    internal val thresholdRequestTimes = java.util.ArrayDeque<Long>()
    internal val thresholdBreaches = CopyOnWriteArrayList<ThresholdBreachRecord>()
    @Volatile internal var networkFilter = ""
    @Volatile internal var networkInjectionEnabled = true
    @Volatile internal var requestDelayMs = 0L
    internal val failNextRequest = AtomicBoolean(false)
    @Volatile internal var httpErrorCode = 0
    internal val responseRewrites = CopyOnWriteArrayList<Pair<Regex, String>>()
    internal val blockedURLPatterns = CopyOnWriteArrayList<Regex>()

    data class NetworkRewriteRule(
        val id: String,
        val urlPattern: String,
        val responseBody: String,
        val responseStatusCode: Int?,
        val httpMethod: String?,
        val isEnabled: Boolean,
        val matchType: String
    )

    data class NetworkFailure(
        val failureType: String,
        val statusCode: Int? = null,
        val customDomain: String = "",
        val customCode: Int = 0,
        val customDescription: String = ""
    )

    internal data class DelayInjectionSettings(
        val isEnabled: Boolean = false,
        val fixedDelay: Double? = null,
        val minDelay: Double = 1.0,
        val maxDelay: Double = 3.0,
        val urlPatterns: List<String> = emptyList(),
        val httpMethods: List<String> = emptyList()
    )

    internal data class FailureInjectionSettings(
        val isEnabled: Boolean = false,
        val failureRate: Double = 0.5,
        val failureType: String = "timeout",
        val customStatusCodes: List<Int> = listOf(400, 401, 403, 404, 500, 502, 503),
        val urlPatterns: List<String> = emptyList(),
        val httpMethods: List<String> = emptyList(),
        val customDomain: String = "DebugSwift.CustomNetworkError",
        val customCode: Int = -1,
        val customDescription: String = "Injected custom network error."
    )

    internal data class RewriteInjectionSettings(
        val isEnabled: Boolean = false,
        val rules: List<NetworkRewriteRule> = emptyList(),
        val autoEnableOnRun: Boolean = false,
        val shortCircuitEnabled: Boolean = true,
        val multipleMatchEnabled: Boolean = false
    )

    internal data class NetworkInjectionSettings(
        val delay: DelayInjectionSettings = DelayInjectionSettings(),
        val failure: FailureInjectionSettings = FailureInjectionSettings(),
        val rewrite: RewriteInjectionSettings = RewriteInjectionSettings()
    )

    /** Every change goes through the object's monitor (the writers are @Synchronized) and bumps the version. */
    @Volatile internal var networkInjectionSettings = NetworkInjectionSettings()
        set(value) {
            field = value
            networkInjectionVersion.incrementAndGet()
        }
    internal val networkInjectionVersion = java.util.concurrent.atomic.AtomicLong(0)

    data class NetworkRecord(
        val timestamp: Long,
        val method: String,
        val url: String,
        val status: Int,
        val durationMs: Long,
        val requestBytes: Long,
        val responseBytes: Long,
        val requestHeaders: Map<String, List<String>>,
        val responseHeaders: Map<String, List<String>>,
        val requestBody: String,
        val responseBody: String,
        val decryptedResponseBody: String,
        val error: String,
        val graphqlOperation: String,
        val source: String,
        val id: String = UUID.randomUUID().toString(),
        val sessionID: String = currentNetworkSessionID
    )

    internal val networkReplayClient by lazy { OkHttpClient() }

    internal class WebSocketConnectionRecord(
        val id: String,
        val url: String,
        val createdAtMs: Long = System.currentTimeMillis()
    ) {
        @Volatile var status: String = "Connecting"
        @Volatile var statusDetail: String = ""
        @Volatile var lastActivityAtMs: Long = createdAtMs
        val unreadFrameCount = AtomicInteger(0)
        val frames = CopyOnWriteArrayList<WebSocketFrameRecord>()

        fun isActive(): Boolean = status == "Connecting" || status == "Connected" || status == "Closing"
    }

    internal data class WebSocketFrameRecord(
        val id: String,
        val timestampMs: Long,
        val direction: String,
        val type: String,
        val payload: ByteArray
    )

    internal data class PushNotificationRecord(
        val id: String,
        val title: String,
        val body: String,
        val subtitle: String?,
        val badge: Int?,
        val sound: String?,
        val category: String?,
        val userInfo: Map<String, String>,
        val scheduledAtMs: Long,
        val deliveryAtMs: Long?,
        val status: String,
        val trigger: String,
        val interactionType: String?
    )

    internal data class PushNotificationTemplate(
        val id: String,
        val name: String,
        val title: String,
        val body: String,
        val subtitle: String?,
        val badge: Int?,
        val sound: String?,
        val category: String?,
        val userInfo: Map<String, String>,
        val isDefault: Boolean
    )

    internal data class RecordedInteraction(
        val kind: String,
        val startX: Float,
        val startY: Float,
        val endX: Float,
        val endY: Float
    )

    internal data class DestroyedActivity(
        val className: String,
        val destroyedAtMs: Long,
        val reference: WeakReference<Activity>
    )

    fun install(context: Context) {
        val applicationContext = context.applicationContext
        if (appContext === applicationContext) return
        appContext = applicationContext
        loadThresholdSettings(applicationContext)
        loadNetworkInjectionSettings(applicationContext)
        loadPushState(applicationContext)
        restoreAppearanceOverride(applicationContext)
        // The retention window decides which saved requests load, so it is read first.
        networkHistoryRetentionMs = applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getLong(HISTORY_RETENTION_KEY, NETWORK_HISTORY_RETENTION_MS)
        loadNetworkHistory(applicationContext)
        loadCrashHistory(applicationContext)
        registerLifecycleCallbacks(applicationContext)
        seedForegroundActivity()
        DebugSwiftRecomposition.start()
        if (crashCaptureEnabled) installCrashHandler()
        startAnrWatchdog()
        startFrameMonitor()
        notificationExecutor.execute { ensureNotificationChannel(applicationContext) }
        refreshNotificationSettings(applicationContext)
        log("DebugSwift Android runtime installed on ${Build.MANUFACTURER} ${Build.MODEL}")
    }

    /** What the tools attach to a window that has come to the front. */
    internal fun prepareWindow(activity: Activity) {
        runCatching { DebugSwiftTouchCapture.install(activity) }
        runCatching { DebugSwiftFloatingButton.attach(activity) }
    }

    /** Saved uncaught-exception reports, newest first. */
    fun crashReportsNewestFirst(): List<String> = crashRecords.toList().asReversed()

    fun composeProbeCount(): Long = composeRenderCount

    fun frameTotal(): Long = frameCount

    /** The Activity in front, for tools that inspect or draw over the window. */
    fun foregroundActivityOrNull(): Activity? = foregroundActivity.get()

    /** The installed application context, for tools that live outside this object. */
    fun contextOrNull(): Context? = appContext

    fun webViewHostNames(): List<String> = webViewHosts.toList()

    /** Every preference file the app owns, minus DebugSwift's own state. */
    fun preferenceStoreNames(context: Context): List<String> {
        val onDisk = File(context.applicationInfo.dataDir, "shared_prefs").listFiles().orEmpty()
            .filter { it.isFile && it.extension.equals("xml", ignoreCase = true) }
            .map { it.nameWithoutExtension }
        return (registeredPreferences + onDisk).filterNot(::isDebugSwiftPreferenceStore).distinct().sorted()
    }

    internal fun isDebugSwiftPreferenceStore(name: String): Boolean =
        name == PREFS || name.startsWith("DebugSwift.") || name.startsWith("debugswift.")

    /** Any app preference store can be edited; DebugSwift's own state cannot. */
    internal fun isEditablePreferenceStore(context: Context, name: String): Boolean =
        name.isNotBlank() && !isDebugSwiftPreferenceStore(name) && name in preferenceStoreNames(context)

    /**
     * The lifecycle callbacks only report Activities that resume after they are registered. When the
     * runtime starts after the first screen is already up, look the resumed Activity up directly.
     * Best effort: it reads framework internals, and does nothing if the platform hides them.
     */
    internal fun seedForegroundActivity() {
        if (foregroundActivity.get() != null) return
        runCatching {
            val threadClass = Class.forName("android.app.ActivityThread")
            val thread = threadClass.getMethod("currentActivityThread").invoke(null)
            val records = (threadClass.getDeclaredField("mActivities").apply { isAccessible = true }.get(thread) as Map<*, *>).values
            for (record in records) {
                val recordClass = record?.javaClass ?: continue
                val paused = recordClass.getDeclaredField("paused").apply { isAccessible = true }.getBoolean(record)
                val activity = recordClass.getDeclaredField("activity").apply { isAccessible = true }.get(record) as? Activity
                if (!paused && activity != null) {
                    foregroundActivity = WeakReference(activity)
                    mainHandler.post { prepareWindow(activity) }
                    return
                }
            }
        }
    }

    fun registerPreferences(name: String) {
        if (name.isNotBlank() && name != PREFS && name !in registeredPreferences) {
            registeredPreferences.add(name)
        }
    }

    fun registerInfo(key: String, value: String) {
        synchronized(customInfo) { customInfo[key] = value }
        publishEvent("app", "Custom info updated: $key")
    }

    /**
     * Tests only: runs once, right after the next `network.injection.get` has read the rules and
     * before the caller patches them, to write the rules in between as another writer could.
     */
    val afterInjectionRead = java.util.concurrent.atomic.AtomicReference<(() -> Unit)?>(null)

    fun registerAction(title: String, action: () -> Unit) {
        synchronized(customActions) { customActions[title] = action }
    }

    fun reportPushToken(token: String) {
        pushToken = token
        log("FCM registration token received from host app")
    }

    @JvmStatic
    fun setPushSimulationEnabled(enabled: Boolean): String {
        val context = appContext ?: return "Android runtime has not been installed."
        if (pushEnabled == enabled) return "Push notification simulation is already ${if (enabled) "enabled" else "disabled"}."
        return togglePushSimulation(context)
    }

    @JvmStatic
    fun isPushSimulationEnabled(): Boolean = pushEnabled

    @JvmStatic
    fun simulatePushNotification(
        title: String,
        body: String,
        delaySeconds: Long = 0,
        subtitle: String? = null,
        badge: Int? = null,
        sound: String? = null,
        category: String? = null,
        userInfo: Map<String, String> = emptyMap()
    ): String {
        val context = appContext ?: return "Android runtime has not been installed."
        return schedulePushNotification(context, title, body, delaySeconds, subtitle, badge, sound, category, userInfo)
    }

    @JvmStatic
    fun simulateMessagePush(sender: String, message: String): String =
        simulatePushNotification("New Message", message, subtitle = "From $sender", userInfo = mapOf("type" to "message", "sender" to sender))

    @JvmStatic
    fun simulateReminderPush(task: String, delaySeconds: Long = 0): String =
        simulatePushNotification("Reminder", "Don't forget: $task", delaySeconds, badge = 1, userInfo = mapOf("type" to "reminder", "task" to task))

    @JvmStatic
    fun simulateNewsPush(headline: String, category: String = "General"): String =
        simulatePushNotification("Breaking News", headline, subtitle = category, userInfo = mapOf("type" to "news", "category" to category))

    @JvmStatic
    fun simulateMarketingPush(title: String, offer: String, discount: String? = null): String {
        val info = mutableMapOf("type" to "marketing", "offer" to offer)
        if (discount != null) info["discount"] = discount
        return simulatePushNotification(title, offer, subtitle = discount?.let { "$it% off" }, badge = 1, userInfo = info)
    }

    @JvmStatic
    fun simulatePushNotificationFromTemplate(name: String, delaySeconds: Long = 0): String {
        val context = appContext ?: return "Android runtime has not been installed."
        return simulatePushTemplate(context, "$name|$delaySeconds")
    }

    @JvmStatic
    fun runPushNotificationScenario(name: String): String {
        val context = appContext ?: return "Android runtime has not been installed."
        return runPushScenario(context, name)
    }

    @JvmStatic
    fun updatePushNotificationSetting(name: String, value: String): String {
        val context = appContext ?: return "Android runtime has not been installed."
        return setPushConfiguration(context, "$name=$value")
    }

    @JvmStatic
    fun addPushNotificationTemplate(
        name: String,
        title: String,
        body: String,
        subtitle: String? = null,
        badge: Int? = null,
        sound: String? = null,
        category: String? = null,
        userInfo: Map<String, String> = emptyMap()
    ): String {
        val context = appContext ?: return "Android runtime has not been installed."
        if (name.isBlank() || title.isBlank() || body.isBlank()) return "Template name, title, and body cannot be empty."
        return storePushTemplate(context, PushNotificationTemplate(UUID.randomUUID().toString(), name, title, body, subtitle, badge, sound, category, userInfo, false))
    }

    @JvmStatic
    fun removePushNotificationTemplate(name: String): String {
        val context = appContext ?: return "Android runtime has not been installed."
        return removePushTemplate(context, name)
    }

    @JvmStatic
    fun clearPushNotificationHistory(): String = clearPushHistory()

    @JvmStatic
    fun removeSimulatedPushNotification(id: String): String {
        val context = appContext ?: return "Android runtime has not been installed."
        return removePushNotification(context, id)
    }

    @JvmStatic
    fun simulatePushNotificationInteraction(id: String): String {
        val context = appContext ?: return "Android runtime has not been installed."
        return interactWithPushNotification(context, id)
    }

    @JvmStatic
    fun simulateForegroundPushNotification(id: String): String {
        if (pushHistory.none { it.id == id }) return "No simulated notification with ID '$id'."
        publishEvent("app", "Simulated foreground notification: $id")
        return "Foreground notification simulation recorded for $id."
    }

    @JvmStatic
    fun simulateBackgroundPushNotification(id: String): String {
        val context = appContext ?: return "Android runtime has not been installed."
        if (pushHistory.none { it.id == id }) return "No simulated notification with ID '$id'."
        updatePushNotification(context, id, "Delivered")
        publishEvent("app", "Simulated background notification: $id")
        return "Background notification simulation recorded for $id."
    }

    @JvmStatic
    fun pushNotificationSnapshot(): String {
        val context = appContext ?: return "Android runtime has not been installed."
        return pushNotificationSnapshot(context)
    }

    fun reportLocation(latitude: Double, longitude: Double, accuracyMeters: Float) {
        lastLocation = "Latitude: $latitude\nLongitude: $longitude\nAccuracy: ${accuracyMeters}m"
        publishEvent("app", "Location updated")
    }

    fun snapshot(featureID: String): String {
        val context = appContext ?: return "Android runtime has not been installed. Call AndroidDebugTools.install(application) from the host app."
        return when (featureID) {
            "http", "websocket", "network_injection", "network_thresholds", "graphql", "network_encryption", "har_export", "webview_network", "network_history" -> networkSnapshot(featureID)
            "performance_overview", "performance_widget", "battery", "disk", "memory_warning", "frame_drops", "hangs", "backtraces", "leaks", "thread_checker", "super_calls" -> performanceSnapshot(context, featureID)
            "view_hierarchy", "grid", "touches", "view_borders", "animation_control", "dark_mode", "render_tracking", "doc_recorder", "measurement", "color_palette" -> interfaceSnapshot(context, featureID)
            "files", "preferences", "keychain", "persistent_data", "database", "realm", "core_data", "swift_data", "http_cookies", "security_audit" -> resourcesSnapshot(context, featureID)
            "crashes", "console", "oslog_console", "device_info", "push_token", "push_simulator", "custom_actions", "custom_info", "deep_links", "loaded_libraries", "location", "event_bus", "agent_debug_log" -> appSnapshot(context, featureID)
            else -> "Unknown DebugSwift tool: $featureID"
        }
    }

    @JvmStatic
    fun securityAuditSnapshot(): String {
        val context = appContext ?: return JSONObject()
            .put("findings", JSONArray())
            .put("summary", "Android runtime has not been installed.")
            .toString()
        return securityAuditSnapshotJSON(context)
    }

    fun perform(featureID: String, actionID: String, value: String = ""): String {
        val context = appContext ?: return "Android runtime has not been installed."
        return when (actionID) {
            "clear" -> clear(featureID)
            "clear_push_history" -> if (value.trim() == "CLEAR") clearPushHistory() else "Type CLEAR to remove notification history."
            "capture" -> capture(featureID)
            "toggle" -> if (featureID == "dark_mode") toggleDarkMode(context) else toggle(featureID)
            "export" -> export(featureID, context)
            "notify" -> sendLocalNotification(context, value)
            "simulate_template" -> simulatePushTemplate(context, value)
            "run_scenario" -> runPushScenario(context, value)
            "set_notification_config" -> setPushConfiguration(context, value)
            "add_template" -> addPushTemplate(context, value)
            "remove_template" -> removePushTemplate(context, value)
            "remove_notification" -> removePushNotification(context, value)
            "interact_notification" -> interactWithPushNotification(context, value)
            "resend_notification" -> resendPushNotification(context, value)
            "delete_console_entry" -> {
                val index = value.toIntOrNull()
                if (featureID != "console" || index == null || index !in consoleRecords.indices) {
                    "Console entry no longer exists."
                } else {
                    consoleRecords.removeAt(index)
                    "Console entry removed."
                }
            }
            "history_page" -> showPushHistoryPage(context, value)
            "open_notification_settings" -> openNotificationSettings(context)
            "refresh" -> snapshot(featureID)
            "set_delay" -> value.toLongOrNull()?.let { setRequestDelay(it); "Request delay set to ${requestDelayMs}ms." } ?: "Enter the delay in milliseconds."
            "inject_failure" -> { failNextNetworkRequest(); "The next instrumented HTTP request will fail." }
            "set_http_error" -> value.toIntOrNull()?.let { setHTTPErrorInjection(it); "HTTP error injection set to ${injectedHTTPError().takeIf { code -> code != 0 } ?: "off"}." } ?: "Enter an HTTP status code from 400 to 599."
            "rewrite_response" -> {
                val parts = value.split("=>", limit = 2)
                if (parts.size != 2 || parts.first().isBlank()) "Enter a URL regex followed by => and the replacement body."
                else { addResponseRewrite(parts.first(), parts.last()); "Response rewrite rule added." }
            }
            "block_url" -> if (value.isBlank()) "Enter a URL regex to block." else {
                runCatching { blockedURLPatterns.add(Regex(value)); "URL block rule added." }.getOrElse { "Invalid URL pattern: ${it.message}" }
            }
            "set_threshold" -> {
                val parts = value.split(",", limit = 2).map { it.trim() }
                if (parts.size != 2) "Enter request limit,window seconds."
                else {
                    val limit = parts[0].toIntOrNull()
                    val window = parts[1].toIntOrNull()
                    if (limit == null || window == null) "Both threshold values must be numbers."
                    else { setRequestThreshold(limit, window); "Request threshold set to $limit per ${window}s." }
                }
            }
            "set_threshold_tracking" -> value.toBooleanStrictOrNull()?.let {
                setRequestTracking(it)
                "Request tracking ${if (it) "enabled" else "disabled"}."
            } ?: "Set request tracking to true or false."
            "set_threshold_blocking" -> value.toBooleanStrictOrNull()?.let {
                setThresholdBlocking(it)
                "Request blocking ${if (it) "enabled" else "disabled"}."
            } ?: "Set request blocking to true or false."
            "clear_threshold_history" -> clearThresholdHistory()
            "filter_requests" -> {
                networkFilter = value.trim()
                networkSnapshot(featureID)
            }
            "select_request" -> selectNetworkRequest(featureID, value)
            "filter_websockets" -> {
                webSocketFilter = value.trim()
                selectedWebSocketFrameID = ""
                webSocketSnapshot()
            }
            "select_connection" -> selectWebSocketConnection(value)
            "select_frame" -> selectWebSocketFrame(value)
            "filter_sent" -> { webSocketDirectionFilter = "Sent"; selectedWebSocketFrameID = ""; webSocketSnapshot() }
            "filter_received" -> { webSocketDirectionFilter = "Received"; selectedWebSocketFrameID = ""; webSocketSnapshot() }
            "filter_all_frames" -> { webSocketDirectionFilter = ""; selectedWebSocketFrameID = ""; webSocketSnapshot() }
            "copy_url" -> copyWebSocketURL(context)
            "copy_payload" -> copyWebSocketPayload(context)
            "close_connection" -> closeSelectedWebSocketConnection()
            "clear_frames" -> clearSelectedWebSocketFrames()
            "back_connections" -> {
                selectedWebSocketConnectionID = ""
                selectedWebSocketFrameID = ""
                webSocketDirectionFilter = ""
                webSocketSnapshot()
            }
            "send_frame" -> sendWebSocketFrame(value, resendSelected = false)
            "resend_frame" -> sendWebSocketFrame(value, resendSelected = true)
            "filter_logs" -> {
                logcatFilter = value.trim()
                logcatSnapshot()
            }
            "browse_files" -> {
                currentFilePath = value.trim().ifEmpty { "files" }
                browseFiles(context, currentFilePath)
            }
            "register_key" -> {
                val separator = value.lastIndexOf(':')
                val pattern = value.substringBeforeLast(':').trim()
                val encodedKey = value.substringAfterLast(':').trim()
                val key = runCatching { android.util.Base64.decode(encodedKey, android.util.Base64.DEFAULT) }.getOrNull()
                if (separator <= 0 || pattern.isBlank() || key == null) "Enter a URL regex followed by ':' and a base64 AES key."
                else if (DebugSwiftNetworkConfig.registerAESKey(pattern, key)) {
                    "URL matched by '$pattern' can now decrypt base64 AES-GCM response bodies (nonce + ciphertext)."
                } else "AES key must contain 16, 24, or 32 bytes and the URL pattern must be valid."
            }
            "clear_keys" -> {
                DebugSwiftNetworkConfig.clearAESKeys()
                "Response decryption keys cleared from this process."
            }
            "set_decryption_enabled" -> value.toBooleanStrictOrNull()?.let {
                DebugSwiftNetworkConfig.setDecryptionEnabled(it)
                "Response decryption ${if (it) "enabled" else "disabled"}. New captured responses use this setting."
            } ?: "Set response decryption to true or false."
            "set_preference" -> writePreference(context, value)
            "delete_preference" -> deletePreference(context, value)
            "clear_preferences" -> clearPreferenceStore(context, value)
            "reset_dark_mode" -> resetDarkMode(context)
            "set_grid" -> setGridOptions(value)
            "simulate_memory_warning" -> simulateMemoryWarning()
            "run_query" -> {
                val parts = value.split("|", limit = 2)
                if (parts.size != 2) "Enter databaseName|SELECT ..."
                else DebugSwiftDatabaseBrowser.query(context, parts[0].trim(), parts[1].trim())
            }
            "run_custom" -> {
                val action = synchronized(customActions) { customActions[value] }
                if (action == null) "No registered action named '$value'." else runCatching { action(); "Action '$value' completed." }.getOrElse { "Action failed: ${it.message}" }
            }
            "copy_token" -> copyPushToken(context)
            "report_info" -> {
                val parts = value.split("=", limit = 2)
                if (parts.size != 2 || parts[0].isBlank()) "Enter name=value."
                else { registerInfo(parts[0].trim(), parts[1]); "Diagnostic value saved." }
            }
            "open_animation_settings" -> runCatching {
                context.startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                "Opened Android Developer options. Change the window, transition, or animator duration scales there."
            }.getOrElse { "Could not open Android Developer options: ${it.message}" }
            else -> "Action '$actionID' is not available for $featureID."
        }
    }

    fun log(message: String, priority: Int = Log.DEBUG, tag: String = TAG) {
        if (!consoleCaptureEnabled || !consoleAccepts(message)) {
            Log.println(priority, tag, message)
            return
        }
        val line = "${timestamp()} ${priorityName(priority)} $tag: $message"
        consoleRecords.add(line)
        trim(consoleRecords)
        appendAgentEntry(
            kind = "console",
            location = tag,
            message = message,
            data = mapOf("priority" to priorityName(priority))
        )
        Log.println(priority, tag, message)
        publishEvent("app", message)
    }

    fun recordNetwork(
        method: String,
        url: String,
        status: Int,
        durationMs: Long,
        requestBytes: Long,
        responseBytes: Long,
        requestBody: String,
        responseBody: String,
        error: String = "",
        requestHeaders: Map<String, List<String>> = emptyMap(),
        responseHeaders: Map<String, List<String>> = emptyMap(),
        source: String = "http",
        decryptedResponseBody: String? = null
    ) {
        if (!networkAccepts(url)) return
        if (source == "webview" && !webViewCaptureEnabled) return
        val graphOperation = graphqlOperation(requestBody)
        // Mask before storing: the list, the history file, HAR, cURL and the agent log all read
        // this record. Only replay needs the original request, so it stays in memory alone.
        val masked = DebugSwiftNetworkSanitizer.sanitize(
            url = url,
            requestHeaders = requestHeaders,
            responseHeaders = responseHeaders,
            requestBody = requestBody,
            responseBody = responseBody,
            decryptedResponseBody = decryptedResponseBody?.takeIf { it.isNotEmpty() }
                ?: DebugSwiftNetworkConfig.decryptResponse(url, responseBody).orEmpty()
        )
        val record = NetworkRecord(
                System.currentTimeMillis(), method, masked.url, status, durationMs,
                requestBytes, responseBytes,
                masked.requestHeaders, masked.responseHeaders,
                masked.requestBody.take(32_000),
                masked.responseBody.take(64_000),
                masked.decryptedResponseBody.take(64_000),
                error, graphOperation, source
            )
        rememberReplayRequest(record.id, ReplayRequest(url, requestHeaders, requestBody))
        networkRecords.add(record)
        // The WebView limit first, so a new WebView record does not push out an HTTP one.
        if (source == "webview") trimWebViewRecords()
        trim(networkRecords)
        if (isPersistableNetworkRecord(record)) {
            networkHistoryRecords.add(record)
            trimNetworkHistory()
            persistNetworkHistory()
        }
        appendAgentEntry(
            kind = "network",
            location = "OkHttp/$source",
            message = "$method ${masked.url} ($status)",
            data = mapOf(
                "method" to method,
                "url" to masked.url,
                "status" to status,
                "durationMs" to durationMs,
                "requestBytes" to requestBytes,
                "responseBytes" to responseBytes,
                "error" to error
            )
        )
        recordThresholdRequest(url)
        publishEvent("network", "$method ${masked.url} ($status, ${durationMs}ms)")
    }

    /** The unmasked request behind a stored record, kept in memory only so replay can resend it. */
    internal data class ReplayRequest(
        val url: String,
        val headers: Map<String, List<String>>,
        val body: String
    )

    internal val replayRequests = object : LinkedHashMap<String, ReplayRequest>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ReplayRequest>?): Boolean = size > 500
    }

    @JvmStatic
    fun networkInjectionSettingsJSON(): String = networkInjectionSettingsJSONObject(networkInjectionSettings).toString()

    @JvmStatic
    @Synchronized
    fun applyNetworkInjectionSettingsJSON(json: String): String = applyNetworkInjectionSettings(json, resetTransientState = true)

    @JvmStatic
    fun setRequestTracking(enabled: Boolean) {
        synchronized(this) {
            thresholdTrackingEnabled = enabled
            thresholdStartMs = SystemClock.elapsedRealtime()
            thresholdCount = 0
            endpointThresholdCounts.clear()
            thresholdRequestTimes.clear()
        }
        persistThresholdSettings()
    }

    @JvmStatic
    fun setThresholdBlocking(enabled: Boolean) {
        thresholdBlockRequests = enabled
        persistThresholdSettings()
    }

    @JvmStatic
    fun setThresholdAlert(emoji: String, message: String) {
        thresholdAlertEmoji = emoji
        thresholdAlertMessage = message
        persistThresholdSettings()
    }

    @JvmStatic
    fun setEndpointRequestThreshold(endpoint: String, limit: Int, windowSeconds: Int) {
        if (endpoint.isBlank() || limit <= 0 || windowSeconds <= 0) return
        endpointThresholdLimits[endpoint] = EndpointThresholdLimit(limit, windowSeconds * 1000L)
        persistThresholdSettings()
    }

    @JvmStatic
    fun removeEndpointRequestThreshold(endpoint: String) {
        endpointThresholdLimits.remove(endpoint)
        endpointThresholdCounts.remove(endpoint)
        persistThresholdSettings()
    }

    @JvmStatic
    fun clearThresholdHistory(): String {
        synchronized(this) {
            thresholdStartMs = SystemClock.elapsedRealtime()
            thresholdCount = 0
            endpointThresholdCounts.clear()
            thresholdRequestTimes.clear()
        }
        thresholdBreaches.clear()
        publishEvent("network", "Request threshold history cleared")
        return "Request threshold history cleared."
    }

    @JvmStatic
    fun getCurrentRequestCount(endpoint: String? = null): Int = synchronized(this) {
        val now = SystemClock.elapsedRealtime()
        val window = endpoint?.let { endpointThresholdLimits[it]?.windowMs } ?: thresholdWindowMs
        if (endpoint == null) {
            thresholdRequestTimes.count { now - it <= window }
        } else {
            endpointThresholdCounts[endpoint]?.timestamps?.count { now - it <= window } ?: 0
        }
    }

    @JvmStatic
    fun getThresholdLogs(): String {
        val config = synchronized(this) {
            val now = SystemClock.elapsedRealtime()
            thresholdCount = thresholdRequestTimes.count { now - it <= thresholdWindowMs }
            listOf(thresholdLimit, thresholdWindowMs / 1000L, thresholdTrackingEnabled, thresholdBlockRequests, thresholdCount)
        }
        val endpoints = endpointThresholdLimits.entries.sortedBy { it.key }.joinToString("\n") { (endpoint, value) ->
            "- $endpoint: ${value.limit} per ${value.windowMs / 1000L}s"
        }
        val breaches = thresholdBreaches.takeLast(10).joinToString("\n") { breach ->
            "- ${Date(breach.timestampMs)}: ${breach.message}"
        }
        return buildString {
            append("=== Network Request Threshold Logs ===\n\n")
            append("Configuration:\n")
            append("- Global Threshold: ${config[0]} requests per ${config[1]}s\n")
            append("- Tracking Enabled: ${config[2]}\n")
            append("- Request Blocking: ${config[3]}\n\n")
            append("Endpoint Thresholds:\n")
            if (endpoints.isNotEmpty()) append(endpoints).append('\n')
            append("\nCurrent Request Count: ${config[4]}\n\n")
            append("Breach History:\n")
            if (breaches.isNotEmpty()) append(breaches).append('\n')
        }
    }

    /** The last event recorded, by its down time, event time and action. */
    internal var lastTouch: Triple<Long, Long, Int>? = null

    fun recordTouch(event: MotionEvent) {
        // When another library wraps the window callback after DebugSwift, a later install wraps it
        // again, and each event reaches here twice: record it once.
        val identity = Triple(event.downTime, event.eventTime, event.actionMasked)
        if (identity == lastTouch) return
        lastTouch = identity
        val point = localTouchPosition(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                activeTouchStart = point
                recentTouches.add(point)
            }
            MotionEvent.ACTION_MOVE -> recentTouches.add(point)
            MotionEvent.ACTION_UP -> {
                recentTouches.add(point)
                val start = activeTouchStart ?: point
                val dx = point.first - start.first
                val dy = point.second - start.second
                val density = appContext?.resources?.displayMetrics?.density ?: 1f
                val threshold = 24f * density
                val kind = if (dx * dx + dy * dy >= threshold * threshold) "scroll" else "tap"
                if (documentationRecording) {
                    recordedInteractions.add(RecordedInteraction(kind, start.first, start.second, point.first, point.second))
                    trim(recordedInteractions)
                }
                appendAgentEntry(
                    kind = "event",
                    location = "Interface/$kind",
                    message = if (kind == "tap") "Tap recorded" else "Scroll gesture recorded",
                    data = mapOf("x" to point.first, "y" to point.second, "startX" to start.first, "startY" to start.second)
                )
                activeTouchStart = null
            }
            MotionEvent.ACTION_CANCEL -> activeTouchStart = null
        }
        while (recentTouches.size > 24) recentTouches.removeAt(0)
        debugOverlay?.invalidate()
    }

    /** Sockets whose rows the history clear removed: their later callbacks do not bring the rows back. */
    internal val clearedWebSockets: MutableSet<WebSocket> =
        java.util.Collections.synchronizedSet(java.util.Collections.newSetFromMap(java.util.WeakHashMap<WebSocket, Boolean>()))

    internal fun clear(featureID: String): String {
        when (featureID) {
            "http" -> {
                networkRecords.removeAll { it.source == "http" }
                networkFilter = ""
                persistNetworkHistory()
                publishEvent("network", "HTTP history cleared")
                return "HTTP history cleared."
            }
            "graphql" -> {
                networkRecords.removeAll { it.graphqlOperation.isNotBlank() }
                persistNetworkHistory()
                publishEvent("network", "GraphQL history cleared")
                return "GraphQL history cleared."
            }
            "webview_network" -> {
                networkRecords.removeAll { it.source == "webview" }
                webViewHosts.clear()
                persistNetworkHistory()
                publishEvent("network", "WebView history cleared")
                return "WebView history cleared."
            }
            "websocket" -> {
                return clearWebSocketHistory()
            }
            "har_export" -> {
                networkRecords.removeAll { it.source == "http" }
                networkFilter = ""
                persistNetworkHistory()
                publishEvent("network", "HTTP history cleared")
                return "HTTP history cleared."
            }
            "network_history" -> {
                networkHistoryRecords.clear()
                currentNetworkSessionID = UUID.randomUUID().toString()
                persistNetworkHistory()
                publishEvent("network", "Saved network sessions cleared")
                return "Saved network sessions cleared."
            }
            "console" -> consoleRecords.clear()
            "agent_debug_log" -> {
                persistenceExecutor.execute {
                    File(appContext!!.filesDir, AGENT_LOG_FILENAME).delete()
                    File(appContext!!.filesDir, "$AGENT_LOG_FILENAME.previous").delete()
                }
                return "Agent debug log cleared."
            }
            "crashes" -> {
                crashRecords.clear()
                appContext?.filesDir?.listFiles()?.filter { it.name.startsWith("debugswift-crash-") }?.forEach { it.delete() }
            }
            "backtraces" -> backtraces.clear()
            "thread_checker" -> threadViolations.clear()
            "event_bus" -> events.clear()
            "frame_drops", "hangs" -> {
                events.removeAll { it.contains("frame") || it.contains("main thread stalled") }
                slowFrameEvents.clear()
                frameCount = 0
                slowFrameCount = 0
                slowestFrameMs = 0
            }
            "doc_recorder" -> {
                recordedInteractions.clear()
                recentTouches.clear()
                lastRecordingPath = ""
            }
            "color_palette" -> lastPalette = emptyList()
            "push_simulator" -> return clearPushHistory()
            else -> {
                return "$featureID has no history to clear."
            }
        }
        publishEvent("app", "$featureID history cleared")
        return "$featureID history cleared."
    }

    internal fun capture(featureID: String): String {
        when (featureID) {
            "backtraces" -> {
                val trace = Throwable("DebugSwift backtrace at ${timestamp()}").stackTraceToString()
                backtraces.add(trace)
                trim(backtraces)
                publishEvent("performance", "Backtrace captured")
                return trace
            }
            "view_hierarchy", "measurement" -> return captureHierarchy()
            "doc_recorder" -> return captureScreenshot(annotateTouches = true)
            "color_palette" -> return capturePalette()
            "push_simulator" -> return sendLocalNotification(appContext!!)
            "http", "websocket", "network_history" -> return networkSnapshot(featureID)
            "crashes" -> return crashRecords.lastOrNull() ?: "No crash record is available. Crashes are saved when the process handles an uncaught exception."
            else -> {
                publishEvent("performance", "Manual capture requested for $featureID")
                return "Capture recorded at ${timestamp()}.\n\n${snapshot(featureID)}"
            }
        }
    }

    internal fun toggle(featureID: String): String {
        if (featureID == "push_simulator") return togglePushSimulation(appContext!!)
        val enabled = synchronized(enabledTools) {
            if (featureID in enabledTools) {
                enabledTools.remove(featureID)
                false
            } else {
                enabledTools.add(featureID)
                true
            }
        }
        when (featureID) {
            "grid", "touches", "view_borders", "performance_widget" -> updateOverlay()
            "agent_debug_log" -> if (enabled) {
                agentLogEnabled = true
            }
            "thread_checker" -> reconcileStrictMode()
            "network_thresholds" -> setThresholdBlocking(enabled)
            "network_injection" -> {
                networkInjectionEnabled = enabled
                if (!enabled) clearInjectionRules()
            }
        }
        publishEvent("interface", "$featureID ${if (enabled) "enabled" else "disabled"}")
        if (featureID == "agent_debug_log" && !enabled) agentLogEnabled = false
        return "$featureID ${if (enabled) "enabled" else "disabled"}."
    }

    internal fun export(featureID: String, context: Context): String {
        val file = when (featureID) {
            "http" -> exportHar("http")
            "graphql" -> exportHar("graphql")
            "websocket" -> exportWebSockets(context)
            "har_export", "network_history" -> exportHar()
            "backtraces" -> File(context.cacheDir, "debugswift-backtraces-${System.currentTimeMillis()}.txt").apply { writeText(backtraces.joinToString("\n\n")) }
            "event_bus" -> File(context.cacheDir, "debugswift-events-${System.currentTimeMillis()}.txt").apply { writeText(events.joinToString("\n")) }
            "realm" -> File(context.cacheDir, "debugswift-realm-${System.currentTimeMillis()}.txt").apply { writeText(snapshot(featureID)) }
            "console" -> File(context.cacheDir, "debugswift-console-${System.currentTimeMillis()}.txt").apply { writeText(consoleRecords.joinToString("\n")) }
            "oslog_console" -> File(context.cacheDir, "debugswift-logcat-${System.currentTimeMillis()}.txt").apply { writeText(logcatSnapshot()) }
            "network_thresholds" -> File(context.cacheDir, "debugswift-network-thresholds-${System.currentTimeMillis()}.txt").apply { writeText(getThresholdLogs()) }
            "network_injection" -> File(context.cacheDir, "debugswift-rewrite-rules-${System.currentTimeMillis()}.csv").apply { writeText(networkInjectionRulesCSV()) }
            "agent_debug_log" -> File(context.filesDir, AGENT_LOG_FILENAME).takeIf { it.exists() }
            "crashes" -> File(context.cacheDir, "debugswift-crashes-${System.currentTimeMillis()}.txt").apply { writeText(crashRecords.joinToString("\n\n")) }
            "files" -> exportCurrentFile(context)
            "preferences", "persistent_data" -> File(context.cacheDir, "debugswift-${featureID}-${System.currentTimeMillis()}.txt").apply { writeText(snapshot(featureID)) }
            "push_simulator" -> File(context.cacheDir, "debugswift-push-notifications-${System.currentTimeMillis()}.txt").apply { writeText(pushNotificationSnapshot(context, showAllHistory = true)) }
            "color_palette" -> File(context.cacheDir, "debugswift-palette-${System.currentTimeMillis()}.txt").apply { writeText(lastPalette.joinToString("\n")) }
            "database", "core_data", "swift_data" -> File(context.cacheDir, "debugswift-resources-${System.currentTimeMillis()}.txt").apply { writeText(snapshot(featureID)) }
            "doc_recorder" -> File(lastRecordingPath).takeIf { lastRecordingPath.isNotEmpty() && it.exists() }
            else -> null
        }
        return file?.let { shareExport(it, context) } ?: "Nothing to export for $featureID."
    }

    internal fun shareExport(file: File, context: Context): String {
        if (!file.isFile) return "Export file is unavailable."
        val activity = foregroundActivity.get() ?: return "Exported ${file.name}, but no foreground Activity is available to share it."
        return runCatching {
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.debugswift.fileprovider",
                file
            )
            val mimeType = MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(file.extension.lowercase(Locale.ROOT))
                ?: "application/octet-stream"
            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                clipData = ClipData.newUri(context.contentResolver, file.name, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(sendIntent, "Share ${file.name}")
            if (Looper.myLooper() == Looper.getMainLooper()) {
                activity.startActivity(chooser)
            } else {
                mainHandler.post { activity.startActivity(chooser) }
            }
            "Sharing ${file.name}."
        }.getOrElse { error ->
            Log.e(TAG, "Unable to share exported file ${file.name}", error)
            "Exported ${file.name}, but sharing failed. Add the DebugSwift FileProvider to the host app manifest."
        }
    }

    internal fun registerLifecycleCallbacks(context: Context) {
        val application = context as? Application ?: return
        application.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, savedInstanceState: android.os.Bundle?) {
                publishEvent("app", "Activity created: ${activity.javaClass.simpleName}")
            }

            override fun onActivityStarted(activity: Activity) {
                publishEvent("app", "Activity started: ${activity.javaClass.simpleName}")
            }

            override fun onActivityResumed(activity: Activity) {
                val previous = foregroundActivity.get()
                foregroundActivity = WeakReference(activity)
                appInForeground = true
                appContext?.let(::refreshNotificationSettings)
                if (previous !== activity) updateOverlay()
                prepareWindow(activity)
                publishEvent("app", "Activity resumed: ${activity.javaClass.simpleName}")
            }

            override fun onActivityPaused(activity: Activity) {
                if (foregroundActivity.get() === activity) appInForeground = false
                publishEvent("app", "Activity paused: ${activity.javaClass.simpleName}")
            }

            override fun onActivityStopped(activity: Activity) {
                publishEvent("app", "Activity stopped: ${activity.javaClass.simpleName}")
            }

            override fun onActivitySaveInstanceState(activity: Activity, outState: android.os.Bundle) = Unit

            override fun onActivityDestroyed(activity: Activity) {
                destroyedActivities.add(DestroyedActivity(activity.javaClass.name, SystemClock.elapsedRealtime(), WeakReference(activity)))
                while (destroyedActivities.size > 100) destroyedActivities.removeAt(0)
                if (foregroundActivity.get() === activity) {
                    debugOverlay?.detach()
                    debugOverlay = null
                    foregroundActivity.clear()
                }
                publishEvent("app", "Activity destroyed: ${activity.javaClass.simpleName}")
            }
        })
    }

    /** Off when the host passed `.crashManager` to `DebugSwift().setup(disable:)`. */
    @Volatile var crashCaptureEnabled = true
    internal var crashHandler: Thread.UncaughtExceptionHandler? = null
    /** Whether the installed handler still records; it outlives being replaced if a newer handler calls it. */
    internal var crashHandlerActive: java.util.concurrent.atomic.AtomicBoolean? = null
    internal var handlerBeforeCrashCapture: Thread.UncaughtExceptionHandler? = null

    @Volatile internal var frameCount = 0L
    @Volatile internal var slowFrameCount = 0L
    @Volatile internal var slowestFrameMs = 0L
    @Volatile internal var lastFrameNanos = 0L
    @Volatile internal var lastRecordingPath = ""
    @Volatile internal var documentationRecording = false
    @Volatile internal var lastPalette: List<String> = emptyList()
    @Volatile internal var composeRenderCount = 0L
    @Volatile internal var cpuUsagePercent = 0.0
    @Volatile internal var framesPerSecond = 0L
    internal var previousFrameCount = 0L
    internal var previousCpuTimeMs = 0L
    internal var previousWallTimeMs = 0L

    @Synchronized internal fun cpuUsage(currentCpuMs: Long = Process.getElapsedCpuTime()): Double {
        val now = SystemClock.elapsedRealtime()
        val elapsed = now - previousWallTimeMs
        val cpu = currentCpuMs - previousCpuTimeMs
        previousWallTimeMs = now
        previousCpuTimeMs = currentCpuMs
        if (elapsed <= 0L || cpu < 0L) return cpuUsagePercent
        return ((cpu.toDouble() / elapsed) * 100.0 / Runtime.getRuntime().availableProcessors()).coerceIn(0.0, 100.0)
    }

    internal class DebugOverlay(context: Context) : View(context) {
        private val gridPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = gridColor; strokeWidth = 1f }
        private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(90, 255, 90, 90); style = Paint.Style.STROKE; strokeWidth = 1f }
        private val touchPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(180, 255, 210, 60); style = Paint.Style.FILL }
        private val widgetBackgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(220, 24, 26, 32) }
        private val widgetTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = 13 * resources.displayMetrics.density
            typeface = android.graphics.Typeface.create("monospace", android.graphics.Typeface.NORMAL)
        }
        private val density = resources.displayMetrics.density
        private var observedDecor = WeakReference<ViewGroup>(null)
        private var globalLayoutListener: android.view.ViewTreeObserver.OnGlobalLayoutListener? = null

        fun attachTo(decor: ViewGroup) {
            observedDecor = WeakReference(decor)
            layout(0, 0, decor.width, decor.height)
            decor.overlay.add(this)
            val listener = android.view.ViewTreeObserver.OnGlobalLayoutListener {
                observedDecor.get()?.let { root -> layout(0, 0, root.width, root.height) }
            }
            globalLayoutListener = listener
            decor.viewTreeObserver.addOnGlobalLayoutListener(listener)
        }

        fun detach() {
            val decor = observedDecor.get()
            if (decor != null) {
                decor.overlay.remove(this)
                val listener = globalLayoutListener
                if (listener != null && decor.viewTreeObserver.isAlive) {
                    decor.viewTreeObserver.removeOnGlobalLayoutListener(listener)
                }
            }
            globalLayoutListener = null
            observedDecor.clear()
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val active: Set<String> = synchronized(enabledTools) { enabledTools.toSet() }
            if ("grid" in active) {
                gridPaint.color = Color.argb(
                    (gridOpacity * 255).roundToInt().coerceIn(0, 255),
                    Color.red(gridColor),
                    Color.green(gridColor),
                    Color.blue(gridColor)
                )
                val spacing = (gridSpacingDp * density).coerceAtLeast(1f)
                var x = 0f
                while (x < width) { canvas.drawLine(x, 0f, x, height.toFloat(), gridPaint); x += spacing }
                var y = 0f
                while (y < height) { canvas.drawLine(0f, y, width.toFloat(), y, gridPaint); y += spacing }
            }
            if ("view_borders" in active) drawViewBorders(canvas, this)
            if ("touches" in active) recentTouches.forEach { (x, y) -> canvas.drawCircle(x, y, 8 * density, touchPaint) }
            if ("performance_widget" in active) {
                val runtime = Runtime.getRuntime()
                val used = runtime.totalMemory() - runtime.freeMemory()
                val lines = listOf(
                    "CPU ${"%.1f".format(cpuUsagePercent)}%",
                    "MEM ${formatBytes(used)}",
                    "FPS $framesPerSecond  ·  slow $slowFrameCount"
                )
                val left = 14 * density
                val top = 72 * density
                val padding = 10 * density
                val lineHeight = 18 * density
                val boxWidth = lines.maxOf { widgetTextPaint.measureText(it) } + padding * 2
                val boxHeight = lineHeight * lines.size + padding * 2
                canvas.drawRoundRect(left, top, left + boxWidth, top + boxHeight, 8 * density, 8 * density, widgetBackgroundPaint)
                lines.forEachIndexed { index, line ->
                    canvas.drawText(line, left + padding, top + padding + lineHeight * (index + 1), widgetTextPaint)
                }
            }
        }

        private fun drawViewBorders(canvas: Canvas, root: View) {
            fun walk(view: View) {
                if (view !== this@DebugOverlay && view.width > 0 && view.height > 0) {
                    val rect = Rect()
                    if (view.getGlobalVisibleRect(rect)) canvas.drawRect(rect, borderPaint)
                }
                if (view is ViewGroup) for (index in 0 until view.childCount) walk(view.getChildAt(index))
            }
            val activityRoot = (context as? Activity)?.window?.decorView
            if (activityRoot != null) walk(activityRoot)
        }
    }

    @Volatile internal var lastCaptureMessage = ""

    internal fun JSONObject.toPushRecord() = PushNotificationRecord(
        id = optString("id", UUID.randomUUID().toString()),
        title = optString("title"),
        body = optString("body"),
        subtitle = optString("subtitle").takeUnless { isNull("subtitle") || it.isBlank() },
        badge = if (isNull("badge")) null else optInt("badge"),
        sound = optString("sound").takeUnless { isNull("sound") || it.isBlank() },
        category = optString("category").takeUnless { isNull("category") || it.isBlank() },
        userInfo = jsonObjectToStringMap(optJSONObject("userInfo")),
        scheduledAtMs = optLong("scheduledAtMs", System.currentTimeMillis()),
        deliveryAtMs = if (isNull("deliveryAtMs")) null else optLong("deliveryAtMs"),
        status = optString("status", "Scheduled"),
        trigger = optString("trigger", "Immediate"),
        interactionType = optString("interactionType").takeUnless { isNull("interactionType") || it.isBlank() }
    )

    internal fun JSONObject.toPushTemplate() = PushNotificationTemplate(
        id = optString("id", UUID.randomUUID().toString()),
        name = optString("name"),
        title = optString("title"),
        body = optString("body"),
        subtitle = optString("subtitle").takeUnless { isNull("subtitle") || it.isBlank() },
        badge = if (isNull("badge")) null else optInt("badge"),
        sound = optString("sound").takeUnless { isNull("sound") || it.isBlank() },
        category = optString("category").takeUnless { isNull("category") || it.isBlank() },
        userInfo = jsonObjectToStringMap(optJSONObject("userInfo")),
        isDefault = optBoolean("isDefault", false)
    )

    /** What scheduling a simulated notification did: `accepted` only when it was queued. */
    internal class PushScheduleResult(val accepted: Boolean, val message: String)

    internal data class SecurityAuditFinding(
        val severity: String,
        val source: String,
        val key: String,
        val message: String
    )

    internal data class SecurityAuditReport(
        val findings: List<SecurityAuditFinding>,
        val summary: String,
        val scannedDetails: String
    ) {
        fun findings(forSeverity: String): List<SecurityAuditFinding> =
            findings.filter { it.severity == forSeverity }
    }

    internal var previousThreadPolicy: android.os.StrictMode.ThreadPolicy? = null
    internal var previousVmPolicy: android.os.StrictMode.VmPolicy? = null
    /** True while the installed StrictMode policies are DebugSwift's. Main thread only. */
    internal var strictModeOwned = false

    /** DebugSwiftCore's label for a GraphQL body ("Query: GetUser"), the one iOS lists; "" otherwise. */
    internal fun graphqlOperation(body: String): String {
        if (body.isBlank()) return ""
        return JSONObject(DebugSwiftCoreBridge.call("graphql.label", JSONObject().put("body", body).toString())).optString("label")
    }

    internal fun safeValue(value: Any?): String = when (value) {
        is String -> if (value.length > 200) value.take(200) + "…" else value
        is Set<*> -> value.joinToString()
        else -> value.toString()
    }

    internal fun formatBytes(bytes: Long): String = when {
        bytes >= 1_000_000_000 -> "%.2f GB".format(bytes / 1_000_000_000.0)
        bytes >= 1_000_000 -> "%.2f MB".format(bytes / 1_000_000.0)
        bytes >= 1_000 -> "%.1f KB".format(bytes / 1_000.0)
        else -> "$bytes B"
    }

    internal fun timestamp(): String = SimpleDateFormat("HH:mm:ss.SSS", Locale.getDefault()).format(Date())

    internal fun timestampAt(timestampMs: Long): String = SimpleDateFormat("HH:mm:ss.SSS", Locale.getDefault()).format(Date(timestampMs))

    internal fun priorityName(priority: Int): String = when (priority) {
        Log.ERROR -> "ERROR"
        Log.WARN -> "WARN"
        Log.INFO -> "INFO"
        Log.DEBUG -> "DEBUG"
        Log.VERBOSE -> "TRACE"
        else -> "LOG"
    }

    internal fun <T> trim(records: CopyOnWriteArrayList<T>) {
        while (records.size > MAX_RECORDS) records.removeAt(0)
    }

    // MARK: - Host API

    // Options the Swift `DebugSwift` API sets on Android, named after their iOS counterparts.
    @Volatile var consoleIgnoredLogs: List<String> = emptyList()
    @Volatile var consoleOnlyLogs: List<String> = emptyList()
    @Volatile var networkIgnoredURLs: List<String> = emptyList()
    @Volatile var networkOnlyURLs: List<String> = emptyList()
    @Volatile var webSocketMonitoringEnabled = true
    @Volatile var webViewCaptureEnabled = true
    @Volatile var webViewMaxStoredRequests = 1000
    /** Off when the host passed `.console` to `DebugSwift().setup(disable:)`; Logcat still gets the line. */
    @Volatile var consoleCaptureEnabled = true
    internal const val HISTORY_RETENTION_KEY = "network_history_retention_ms"

    /** Keeps the newest `webViewMaxStoredRequests` WebView records; HTTP records are not affected. */
    internal fun trimWebViewRecords() {
        val webView = networkRecords.filter { it.source == "webview" }
        val excess = webView.size - webViewMaxStoredRequests
        if (excess > 0) {
            val dropped = webView.take(excess).map { it.id }.toSet()
            networkRecords.removeAll { it.id in dropped }
        }
    }
    @Volatile internal var strictModeFlashScreen = false
    @Volatile internal var strictModeLog = false
    @Volatile internal var strictModeIgnoredClasses: Set<String> = emptySet()
    @Volatile internal var superCallIgnoredClasses: Set<String> = emptySet()
    @Volatile internal var networkHistoryRetentionMs = NETWORK_HISTORY_RETENTION_MS

    internal fun stringList(array: JSONArray?): List<String> =
        if (array == null) emptyList() else (0 until array.length()).map { array.optString(it) }

    /**
     * The Swift `DebugSwift` API on Android: one JSON operation per iOS call, reached through
     * `DebugSwiftNativeBridge.resource("host.<operation>", arguments)`.
     */
    fun hostAPI(operation: String, arguments: String): String {
        val args = runCatching { JSONObject(arguments.ifBlank { "{}" }) }.getOrElse { JSONObject() }
        val context = appContext
        fun ok(message: String = "") = JSONObject().put("ok", true).put("message", message).toString()
        fun fail(message: String) = JSONObject().put("ok", false).put("message", message).toString()
        return when (operation) {
            // Console
            "console.messages" -> JSONArray(consoleRecords.toList()).toString()
            "console.remove" -> {
                val index = args.optInt("index", -1)
                if (index in consoleRecords.indices) consoleRecords.removeAt(index)
                ok()
            }
            "console.clear" -> { consoleRecords.clear(); ok() }
            "console.filters" -> {
                consoleIgnoredLogs = stringList(args.optJSONArray("ignored"))
                consoleOnlyLogs = stringList(args.optJSONArray("only"))
                ok()
            }
            "console.enabled" -> { consoleCaptureEnabled = args.optBoolean("enabled", true); ok() }
            "crash.enabled" -> {
                crashCaptureEnabled = args.optBoolean("enabled", true)
                applyCrashCapture()
                ok()
            }
            "console.share" -> ok(context?.let { export("console", it) } ?: "Android runtime has not been installed.")

            // Network
            "network.filters" -> {
                networkIgnoredURLs = stringList(args.optJSONArray("ignored"))
                networkOnlyURLs = stringList(args.optJSONArray("only"))
                ok()
            }
            "network.clearHistory" -> ok(clear("http"))
            "network.clearWebSockets" -> ok(clearWebSocketHistory())
            "network.clearAll" -> {
                clear("http")
                clear("webview_network")
                clearWebSocketHistory()
                networkHistoryRecords.clear()
                persistNetworkHistory()
                ok("All network data cleared.")
            }
            "network.sessionHistory" -> {
                val days = args.optInt("retentionDays", 7).coerceIn(1, 365)
                networkHistoryRetentionMs = days * 24L * 60 * 60 * 1_000
                context?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)?.edit()
                    ?.putLong(HISTORY_RETENTION_KEY, networkHistoryRetentionMs)?.apply()
                trimNetworkHistory()
                // Rewrite the file now, so requests outside the new window cannot come back after a restart.
                persistNetworkHistory()
                ok()
            }
            "network.threshold.get" -> {
                val now = SystemClock.elapsedRealtime()
                val endpoints = JSONArray()
                endpointThresholdLimits.entries.sortedBy { it.key }.forEach { (endpoint, config) ->
                    endpoints.put(JSONObject().put("endpoint", endpoint).put("limit", config.limit).put("timeWindow", config.windowMs / 1000.0))
                }
                val breaches = JSONArray()
                thresholdBreaches.toList().forEach { breach ->
                    breaches.put(JSONObject()
                        .put("timestamp", breach.timestampMs)
                        .put("requestCount", breach.requestCount)
                        .put("threshold", breach.limit)
                        .put("endpoint", breach.endpoint.ifBlank { null } ?: JSONObject.NULL)
                        .put("message", breach.message))
                }
                val count = synchronized(this) { thresholdRequestTimes.count { now - it <= thresholdWindowMs } }
                JSONObject()
                    .put("isEnabled", thresholdTrackingEnabled)
                    .put("limit", thresholdLimit)
                    .put("timeWindow", thresholdWindowMs / 1000.0)
                    .put("shouldBlockRequests", thresholdBlockRequests)
                    .put("currentRequestCount", count)
                    .put("endpointLimits", endpoints)
                    .put("breaches", breaches)
                    .toString()
            }
            "network.threshold.set" -> {
                setRequestThreshold(args.optInt("limit", thresholdLimit), args.optDouble("timeWindow", thresholdWindowMs / 1000.0).toInt().coerceAtLeast(1))
                ok()
            }
            "network.threshold.tracking" -> { setRequestTracking(args.optBoolean("enabled")); ok() }
            "network.threshold.blocking" -> { setThresholdBlocking(args.optBoolean("enabled")); ok() }
            "network.threshold.alert" -> { setThresholdAlert(args.optString("emoji", "⚠️"), args.optString("message")); ok() }
            "network.threshold.endpoint" -> {
                setEndpointRequestThreshold(args.optString("endpoint"), args.optInt("limit"), args.optDouble("timeWindow", 60.0).toInt().coerceAtLeast(1))
                ok()
            }
            "network.threshold.count" ->
                JSONObject().put("count", getCurrentRequestCount(args.optString("endpoint").ifBlank { null })).toString()
            "network.threshold.clear" -> ok(clearThresholdHistory())
            "network.threshold.logs" -> JSONObject().put("logs", getThresholdLogs()).toString()
            "network.threshold.export" -> ok(context?.let { export("network_thresholds", it) } ?: "Android runtime has not been installed.")

            // Network injection: the current rules. Swift's injection calls read them, then send
            // `network.injection.patch` with the fields the call sets.
            "network.injection.get" -> {
                val reply = JSONObject()
                    .put("version", networkInjectionVersion.get())
                    .put("settings", JSONObject(networkInjectionSettingsJSON()))
                    .toString()
                afterInjectionRead.getAndSet(null)?.invoke()
                reply
            }
            // Writes the given fields of each section (delay, failure, rewrite) into the current rules,
            // under the same monitor as every other writer: fields the caller did not change, such as
            // rules an import just wrote, are kept.
            "network.injection.patch" -> synchronized(this) {
                val current = JSONObject(networkInjectionSettingsJSON())
                val sections = args.optJSONObject("sections") ?: JSONObject()
                sections.keys().forEach { name ->
                    val fields = sections.optJSONObject(name) ?: return@forEach
                    val section = current.optJSONObject(name) ?: JSONObject().also { current.put(name, it) }
                    fields.keys().forEach { field -> section.put(field, fields.get(field)) }
                }
                val message = applyNetworkInjectionSettings(current.toString(), resetTransientState = false)
                if (message == "Network injection settings applied.") ok(message) else fail(message)
            }
            "network.history.reload" -> {
                val ctx = context ?: return fail("Android runtime has not been installed.")
                networkHistoryRecords.clear()
                loadNetworkHistory(ctx)
                ok()
            }
            "network.injection.csv" -> JSONObject().put("csv", networkInjectionRulesCSV()).toString()

            // WebSocket
            "websocket.state" -> JSONObject()
                .put("enabled", webSocketMonitoringEnabled)
                .put("active", activeWebSockets.size)
                .put("unread", webSocketConnections.sumOf { it.unreadFrameCount.get() })
                .toString()
            "websocket.enabled" -> { webSocketMonitoringEnabled = args.optBoolean("enabled", true); ok() }
            "websocket.clearFrames" -> {
                val url = args.optString("url")
                webSocketConnections.filter { it.url == url }.forEach { connection ->
                    connection.frames.clear()
                    connection.unreadFrameCount.set(0)
                }
                ok()
            }

            // WebView
            "webview.config" -> {
                if (args.has("enabled")) webViewCaptureEnabled = args.optBoolean("enabled")
                if (args.has("maxStoredRequests")) {
                    webViewMaxStoredRequests = args.optInt("maxStoredRequests").coerceAtLeast(1)
                    trimWebViewRecords()
                }
                JSONObject().put("enabled", webViewCaptureEnabled).put("maxStoredRequests", webViewMaxStoredRequests).toString()
            }

            // Performance
            "performance.backtrace.capture" -> {
                val (record, _) = captureBacktraceRecord(args.optBoolean("allThreads", false), args.optString("label").ifBlank { null })
                backtraceJSON(record).toString()
            }
            "performance.backtraces" -> JSONArray().also { array -> backtraces.toList().forEach { array.put(backtraceJSON(it)) } }.toString()
            "performance.backtraces.clear" -> { clearBacktraces(); ok() }
            "performance.threads" -> {
                val violations = JSONArray()
                threadViolations.toList().forEach { violation ->
                    violations.put(JSONObject().put("title", violation.substringBefore('\n')).put("stack", violation.substringAfter('\n', "")))
                }
                JSONObject().put("enabled", synchronized(enabledTools) { "thread_checker" in enabledTools }).put("violations", violations).toString()
            }
            "performance.threads.enabled" -> {
                val enabled = args.optBoolean("enabled")
                synchronized(enabledTools) { if (enabled) enabledTools.add("thread_checker") else enabledTools.remove("thread_checker") }
                reconcileStrictMode()
                ok()
            }
            "performance.threads.options" -> {
                if (args.has("flashScreen")) strictModeFlashScreen = args.optBoolean("flashScreen")
                if (args.has("log")) strictModeLog = args.optBoolean("log")
                if (args.has("ignored")) strictModeIgnoredClasses = stringList(args.optJSONArray("ignored")).toSet()
                // Reinstalls the policy with the new options if the checker is on when this runs.
                reconcileStrictMode(reinstall = true)
                ok()
            }
            "performance.threads.clear" -> { threadViolations.clear(); ok() }
            "performance.supercalls" -> {
                val array = JSONArray()
                crashRecords.filter { it.contains("SuperNotCalledException") }
                    .filter { record -> superCallIgnoredClasses.none { record.contains(it) } }
                    .forEach { array.put(it.take(4_000)) }
                array.toString()
            }
            "performance.supercalls.ignored" -> { superCallIgnoredClasses = stringList(args.optJSONArray("classes")).toSet(); ok() }
            "performance.supercalls.clear" -> { crashRecords.removeAll { it.contains("SuperNotCalledException") }; ok() }
            "performance.leaks" -> performanceDetailJSON("leaks")

            // Resources
            "resources.registerDatabase" -> { DebugSwiftDatabaseBrowser.registerRoomDatabase(args.optString("name")); ok() }
            "resources.registerPreferences" -> { registerPreferences(args.optString("name")); ok() }

            // Interface
            "interface.compose" -> JSONObject()
                .put("renders", composeRenderCount)
                .put("frames", frameCount)
                .put("slowFrames", slowFrameCount)
                .toString()
            "interface.compose.clear" -> { composeRenderCount = 0L; ok() }
            "interface.viewDebugger3D" -> ok(DebugSwiftViewDebugger3D.show())

            // App
            "app.snapshot" -> writeAgentSnapshot().toString()
            "app.agentLog" -> {
                val enabled = args.optBoolean("enabled")
                synchronized(enabledTools) { if (enabled) enabledTools.add("agent_debug_log") else enabledTools.remove("agent_debug_log") }
                agentLogEnabled = enabled
                ok()
            }
            "push.state" -> pushStateJSON()
            "push.enabled" -> ok(setPushSimulationEnabled(args.optBoolean("enabled")))
            "push.simulate" -> {
                val ctx = context ?: return fail("Android runtime has not been installed.")
                val info = args.optJSONObject("userInfo")
                val userInfo = info?.keys()?.asSequence()?.associateWith { info.optString(it) } ?: emptyMap()
                val result = schedulePush(
                    ctx,
                    args.optString("title"),
                    args.optString("body"),
                    args.optDouble("delay", 0.0).toLong(),
                    args.optString("subtitle").ifEmpty { null },
                    if (args.isNull("badge") || !args.has("badge")) null else args.optInt("badge"),
                    args.optString("sound").ifEmpty { null },
                    args.optString("category").ifEmpty { null },
                    userInfo,
                    requestedID = args.optString("id").ifBlank { null }
                )
                if (result.accepted) ok(result.message) else fail(result.message)
            }
            "push.template" -> ok(simulatePushNotificationFromTemplate(args.optString("name"), args.optDouble("delay", 0.0).toLong()))
            "push.interact" -> ok(simulatePushNotificationInteraction(args.optString("id")))
            "push.foreground" -> ok(simulateForegroundPushNotification(args.optString("id")))
            "push.background" -> ok(simulateBackgroundPushNotification(args.optString("id")))
            "push.addTemplate" -> {
                val ctx = context ?: return fail("Android runtime has not been installed.")
                val info = args.optJSONObject("userInfo")
                val userInfo = info?.keys()?.asSequence()?.associateWith { info.optString(it) } ?: emptyMap()
                val name = args.optString("name")
                if (name.isBlank() || args.optString("title").isBlank() || args.optString("body").isBlank()) {
                    return fail("Template name, title, and body cannot be empty.")
                }
                // The id the caller chose is the one stored, so removeTemplate(id:) finds the template.
                val template = PushNotificationTemplate(
                    args.optString("id").ifBlank { UUID.randomUUID().toString() },
                    name,
                    args.optString("title"),
                    args.optString("body"),
                    args.optString("subtitle").ifEmpty { null },
                    if (args.isNull("badge") || !args.has("badge")) null else args.optInt("badge"),
                    args.optString("sound").ifEmpty { null },
                    args.optString("category").ifEmpty { null },
                    userInfo,
                    false
                )
                storePushTemplate(ctx, template).let { if (it.endsWith("added.")) ok(it) else fail(it) }
            }
            "push.removeTemplate" -> {
                val ctx = context ?: return fail("Android runtime has not been installed.")
                val id = args.optString("id")
                val template = pushTemplates.firstOrNull { it.id == id } ?: return fail("No notification template with id '$id'.")
                // Names are unique, so removing by this template's name removes exactly this one.
                removePushTemplate(ctx, template.name).let { if (it.endsWith("removed.")) ok(it) else fail(it) }
            }
            "push.clearHistory" -> ok(clearPushNotificationHistory())
            "push.remove" -> removeSimulatedPushNotification(args.optString("id")).let { if (it.startsWith("Removed")) ok(it) else fail(it) }
            "push.config" -> {
                val ctx = context ?: return fail("Android runtime has not been installed.")
                // Check every option first, with no side effect; apply them (and the switch) only if all pass.
                val options = args.keys().asSequence().filter { it != "isEnabled" }.associateWith { args.get(it).toString() }
                val rejected = options.mapNotNull { (key, value) -> pushConfigurationError(key, value) }
                if (rejected.isNotEmpty()) return fail(rejected.joinToString(" "))
                // Apply in memory, the switch included, then write configuration and history once.
                options.forEach { (key, value) -> setPushConfiguration(ctx, "$key=$value", persist = false) }
                val toggles = args.has("isEnabled") && args.optBoolean("isEnabled") != pushEnabled
                if (toggles) togglePushSimulation(ctx, persist = false)
                if (options.isNotEmpty() || toggles) {
                    persistPushConfiguration(ctx)
                    savePushHistory(ctx)
                }
                ok("Notification configuration updated.")
            }
            "push.reloadState" -> {
                // Tests: forget the push state and load it again from what was saved, as a restart does.
                val ctx = context ?: return fail("Android runtime has not been installed.")
                synchronized(this) {
                    pushStateLoaded = false
                    pushHistory.clear()
                    pushTemplates.clear()
                    loadPushState(ctx)
                }
                ok()
            }
            "push.scenario" -> ok(runPushNotificationScenario(args.optString("name")))
            "push.token" -> { reportPushToken(args.optString("token")); ok() }

            else -> JSONObject().put("error", "Unknown host operation: $operation").toString()
        }
    }

    @Volatile internal var lastIntentDescription = ""

    fun reportIntent(intent: Intent?) {
        val notificationID = intent?.getStringExtra(PUSH_NOTIFICATION_ID_EXTRA)
        if (notificationID != null && pushHistory.any { it.id == notificationID }) {
            appContext?.let { updatePushNotification(it, notificationID, "Interacted", "Tap") }
            publishEvent("app", "Simulated notification opened the host app")
        }
        lastIntentDescription = intent?.data?.toString() ?: intent?.action ?: "No URI or action on the last intent."
        publishEvent("app", "Intent received: $lastIntentDescription")
    }
}

/** Shared request injection configuration for host OkHttp clients. */
object DebugSwiftNetworkConfig {
    val decryptors = CopyOnWriteArrayList<String>()
    private val encryptionKeys = mutableMapOf<String, SecretKey>()
    @Volatile private var decryptionEnabled = false

    /** Read the settings currently used by DebugSwiftOkHttpInterceptor. */
    fun networkInjectionSettingsJSON(): String = AndroidDebugTools.networkInjectionSettingsJSON()

    /** Apply the same JSON configuration edited by the shared Network Injection screen. */
    fun applyNetworkInjectionSettingsJSON(json: String): String = AndroidDebugTools.applyNetworkInjectionSettingsJSON(json)

    fun isDecryptionEnabled(): Boolean = decryptionEnabled

    fun setDecryptionEnabled(enabled: Boolean) {
        decryptionEnabled = enabled
    }

    fun decryptionSettingsJSON(): String = JSONObject()
        .put("isEnabled", decryptionEnabled)
        .put("patterns", JSONArray(decryptors.sorted()))
        .toString()

    fun performDecryptionAction(actionID: String, value: String): String = when (actionID) {
        "set_enabled" -> value.toBooleanStrictOrNull()?.let {
            setDecryptionEnabled(it)
            "Response decryption ${if (it) "enabled" else "disabled"}. New captured responses use this setting."
        } ?: "Set response decryption to true or false."
        "register_key" -> {
            val separator = value.lastIndexOf(':')
            val pattern = value.substringBeforeLast(':').trim()
            val encodedKey = value.substringAfterLast(':').trim()
            val key = runCatching {
                android.util.Base64.decode(encodedKey, android.util.Base64.DEFAULT)
            }.getOrNull()
            if (separator <= 0 || pattern.isBlank() || key == null) {
                "Enter a URL regex followed by ':' and a base64 AES key."
            } else if (registerAESKey(pattern, key)) {
                "AES-GCM key registered for URL regex '$pattern'."
            } else {
                "Enter a valid URL regex and a base64 AES key containing 16, 24, or 32 bytes."
            }
        }
        "clear_keys" -> {
            clearAESKeys()
            "Response decryption keys cleared from this process."
        }
        else -> "Unknown response decryption action: $actionID."
    }

    fun registerAESKey(urlPattern: String, encodedKey: ByteArray): Boolean {
        if (encodedKey.size !in listOf(16, 24, 32)) {
            AndroidDebugTools.log("AES key for '$urlPattern' must contain 16, 24, or 32 bytes", Log.ERROR)
            return false
        }
        runCatching { Regex(urlPattern) }.onFailure {
            AndroidDebugTools.log("Invalid URL pattern '$urlPattern': ${it.message}", Log.ERROR)
            return false
        }
        synchronized(encryptionKeys) {
            encryptionKeys[urlPattern] = SecretKeySpec(encodedKey.copyOf(), "AES")
        }
        if (urlPattern !in decryptors) decryptors.add(urlPattern)
        return true
    }

    fun clearAESKeys() {
        synchronized(encryptionKeys) { encryptionKeys.clear() }
        decryptors.clear()
    }

    fun decryptResponse(url: String, encodedBody: String): String? {
        if (!decryptionEnabled) return null
        val encrypted = runCatching {
            android.util.Base64.decode(encodedBody.trim(), android.util.Base64.DEFAULT)
        }.getOrNull() ?: return null
        if (encrypted.size <= 12) return null
        val matchingPatterns = synchronized(encryptionKeys) {
            encryptionKeys.keys.filter { pattern ->
                runCatching { Regex(pattern, RegexOption.IGNORE_CASE).containsMatchIn(url) }.getOrDefault(false)
            }
        }
        for (pattern in matchingPatterns) {
            val cleartext = decryptAESGCM(pattern, encrypted.copyOfRange(0, 12), encrypted.copyOfRange(12, encrypted.size))
            if (cleartext != null) return cleartext.toString(Charsets.UTF_8)
        }
        return null
    }

    fun decryptAESGCM(urlPattern: String, nonce: ByteArray, ciphertext: ByteArray): ByteArray? {
        val key = synchronized(encryptionKeys) { encryptionKeys[urlPattern] } ?: return null
        return runCatching {
            val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(javax.crypto.Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, nonce))
            cipher.doFinal(ciphertext)
        }.getOrNull()
    }
}
