package debug.swift.android

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.ClipData
import android.content.Intent
import android.os.Build
import android.net.Uri
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import debug.swift.android.AndroidDebugTools.PushNotificationRecord
import debug.swift.android.AndroidDebugTools.PushNotificationTemplate
import debug.swift.android.AndroidDebugTools.PushScheduleResult

// Push notification simulation: templates, scheduling, history and permissions.
// Part of AndroidDebugTools: these extensions use the object's state, which lives in AndroidDebugTools.kt.

/** Structured state for the Push Notifications screen. */
fun AndroidDebugTools.pushStateJSON(): String {
    val context = appContext ?: return JSONObject().put("error", "Android runtime has not been installed.").toString()
    val permission = when {
        Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED -> "Not granted"
        !androidNotificationSettingsLoaded -> "Checking"
        androidNotificationsEnabled -> "Allowed"
        else -> "Disabled in system settings"
    }
    fun userInfo(map: Map<String, String>) = JSONObject().also { json -> map.forEach { (key, value) -> json.put(key, value) } }
    val templates = JSONArray()
    pushTemplates.forEach {
        templates.put(
            JSONObject().put("id", it.id).put("name", it.name).put("title", it.title).put("body", it.body)
                .put("subtitle", it.subtitle ?: JSONObject.NULL).put("badge", it.badge ?: JSONObject.NULL)
                .put("sound", it.sound ?: JSONObject.NULL).put("category", it.category ?: JSONObject.NULL)
                .put("userInfo", userInfo(it.userInfo)).put("isDefault", it.isDefault)
        )
    }
    val history = JSONArray()
    pushHistory.toList().take(100).forEach {
        history.put(
            JSONObject().put("id", it.id).put("title", it.title).put("body", it.body)
                .put("subtitle", it.subtitle ?: JSONObject.NULL).put("badge", it.badge ?: JSONObject.NULL)
                .put("sound", it.sound ?: JSONObject.NULL).put("category", it.category ?: JSONObject.NULL)
                .put("status", it.status).put("trigger", it.trigger)
                .put("scheduledMs", it.scheduledAtMs).put("deliveredMs", it.deliveryAtMs ?: JSONObject.NULL)
                .put("interaction", it.interactionType ?: JSONObject.NULL).put("userInfo", userInfo(it.userInfo))
        )
    }
    return JSONObject()
        .put("enabled", pushEnabled).put("permission", permission).put("channel", NOTIFICATION_CHANNEL)
        .put("showInForeground", pushShowInForeground).put("playSound", pushPlaySound).put("showBadge", pushShowBadge)
        .put("autoInteraction", pushAutoInteraction).put("interactionDelay", pushInteractionDelaySeconds)
        .put("simulateRealPush", pushSimulateRealPush).put("maxHistory", pushMaxHistoryCount)
        .put("defaultSound", pushDefaultSound)
        .put("templates", templates).put("history", history).toString()
}

fun AndroidDebugTools.pushTokenValue(): String = pushToken

internal fun AndroidDebugTools.copyPushToken(context: Context): String {
    val token = pushToken.takeIf { it.isNotBlank() && !it.startsWith("No FCM token has been reported") }
        ?: return "No FCM token is available to copy."
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager
        ?: return "Android clipboard is unavailable."
    clipboard.setPrimaryClip(ClipData.newPlainText("Push token", token))
    return "FCM token copied to the clipboard."
}

internal fun AndroidDebugTools.sendLocalNotification(context: Context, value: String = ""): String {
    val parts = value.split("|", limit = 8).map { it.trim() }
    val title = parts.getOrNull(0)?.trim()?.takeIf { it.isNotEmpty() } ?: "DebugSwift test notification"
    val message = parts.getOrNull(1)?.trim()?.takeIf { it.isNotEmpty() } ?: "Local push simulation · ${timestamp()}"
    val delayValue = parts.getOrNull(2)?.trim().orEmpty()
    val delaySeconds = delayValue.toLongOrNull() ?: if (delayValue.isBlank()) 0L else return "Delay must be a whole number of seconds."
    if (delaySeconds < 0) return "Delay must be zero or more seconds."
    val badgeValue = parts.getOrNull(4).orEmpty()
    val badge = badgeValue.toIntOrNull() ?: if (badgeValue.isBlank()) null else return "Badge must be a whole number."
    val userInfo = parsePushUserInfo(parts.getOrNull(7).orEmpty())
        ?: return "User info must use key=value pairs separated by commas."
    return schedulePushNotification(
        context,
        title,
        message,
        delaySeconds,
        parts.getOrNull(3)?.takeIf { it.isNotBlank() },
        badge,
        parts.getOrNull(5)?.takeIf { it.isNotBlank() },
        parts.getOrNull(6)?.takeIf { it.isNotBlank() },
        userInfo
    )
}

internal fun AndroidDebugTools.parsePushUserInfo(value: String): Map<String, String>? {
    if (value.isBlank()) return emptyMap()
    val result = linkedMapOf<String, String>()
    for (entry in value.split(",")) {
        val pair = entry.split("=", limit = 2)
        if (pair.size != 2 || pair[0].isBlank()) return null
        result[pair[0].trim()] = pair[1].trim()
    }
    return result
}

internal fun AndroidDebugTools.ensureNotificationChannel(context: Context) {
    if (Build.VERSION.SDK_INT >= 26) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel(NOTIFICATION_CHANNEL, "DebugSwift tests", NotificationManager.IMPORTANCE_DEFAULT))
    }
}

internal fun AndroidDebugTools.loadPushState(context: Context) {
    if (pushStateLoaded) return
    synchronized(this) {
        if (pushStateLoaded) return
        val preferences = context.getSharedPreferences(PUSH_STATE_PREFS, Context.MODE_PRIVATE)
        pushEnabled = false
        readPushConfiguration(preferences)
        runCatching {
            val historyJSON = JSONArray(preferences.getString("history", "[]") ?: "[]")
            for (index in 0 until historyJSON.length()) {
                val json = historyJSON.getJSONObject(index)
                pushHistory.add(json.toPushRecord())
            }
        }
        runCatching {
            val templateJSON = JSONArray(preferences.getString("templates", "") ?: "")
            for (index in 0 until templateJSON.length()) {
                pushTemplates.add(templateJSON.getJSONObject(index).toPushTemplate())
            }
        }
        if (pushTemplates.isEmpty()) {
            pushTemplates.addAll(defaultPushTemplates())
            savePushTemplates(context)
        }
        pushHistory.replaceAll { record ->
            if (record.status == "Scheduled") record.copy(status = "Failed") else record
        }
        savePushHistory(context)
        pushStateLoaded = true
    }
}

internal fun AndroidDebugTools.defaultPushTemplates() = listOf(
    PushNotificationTemplate("message", "Message", "New Message", "You have a new message from {{sender}}", null, null, null, null, mapOf("type" to "message", "sender" to "John Doe"), true),
    PushNotificationTemplate("news", "News Update", "Breaking News", "{{headline}}", "{{category}}", null, null, null, mapOf("type" to "news", "headline" to "Major technology breakthrough announced", "category" to "Technology"), true),
    PushNotificationTemplate("reminder", "Reminder", "Reminder", "Don't forget: {{task}}", null, 1, null, null, mapOf("type" to "reminder", "task" to "your task"), true),
    PushNotificationTemplate("marketing", "Marketing", "Special Offer! 🎉", "Get {{discount}}% off your next purchase", "Limited time offer", 1, null, null, mapOf("type" to "marketing", "discount" to "50"), true),
    PushNotificationTemplate("system", "System Alert", "System Notification", "{{message}}", null, null, "default", null, mapOf("type" to "system", "message" to "System alert"), true)
)

internal fun AndroidDebugTools.pushPreferences(context: Context) =
    context.getSharedPreferences(PUSH_STATE_PREFS, Context.MODE_PRIVATE)

/** The push options as saved, read when the push state loads (at launch, and by `push.reloadState` in tests). */
internal fun AndroidDebugTools.readPushConfiguration(preferences: android.content.SharedPreferences) {
    pushShowInForeground = preferences.getBoolean("showInForeground", true)
    pushPlaySound = preferences.getBoolean("playSound", true)
    pushShowBadge = preferences.getBoolean("showBadge", true)
    pushAutoInteraction = preferences.getBoolean("autoInteraction", false)
    // Saved as text so any accepted delay comes back exactly; older versions saved a Float.
    pushInteractionDelaySeconds = preferences.getString("interactionDelaySeconds", null)
        ?.toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 }
        ?: preferences.getFloat("interactionDelay", 3f).toDouble()
    pushSimulateRealPush = preferences.getBoolean("simulateRealPush", false)
    pushDefaultSound = preferences.getString("defaultSound", "default") ?: "default"
    // Any positive limit the configuration accepts comes back as it was.
    pushMaxHistoryCount = preferences.getInt("maxHistoryCount", 100).coerceAtLeast(1)
}

internal fun AndroidDebugTools.persistPushConfiguration(context: Context) {
    pushPreferences(context).edit()
        .putBoolean("showInForeground", pushShowInForeground)
        .putBoolean("playSound", pushPlaySound)
        .putBoolean("showBadge", pushShowBadge)
        .putBoolean("autoInteraction", pushAutoInteraction)
        .putString("interactionDelaySeconds", pushInteractionDelaySeconds.toString())
        .putBoolean("simulateRealPush", pushSimulateRealPush)
        .putString("defaultSound", pushDefaultSound)
        .putInt("maxHistoryCount", pushMaxHistoryCount)
        .apply()
}

internal fun AndroidDebugTools.jsonObjectToStringMap(json: JSONObject?): Map<String, String> {
    if (json == null) return emptyMap()
    return json.keys().asSequence().associateWith { key -> json.optString(key) }
}

internal fun AndroidDebugTools.pushRecordJSON(record: PushNotificationRecord) = JSONObject().apply {
    put("id", record.id)
    put("title", record.title)
    put("body", record.body)
    put("subtitle", record.subtitle ?: JSONObject.NULL)
    put("badge", record.badge ?: JSONObject.NULL)
    put("sound", record.sound ?: JSONObject.NULL)
    put("category", record.category ?: JSONObject.NULL)
    put("userInfo", JSONObject(record.userInfo))
    put("scheduledAtMs", record.scheduledAtMs)
    put("deliveryAtMs", record.deliveryAtMs ?: JSONObject.NULL)
    put("status", record.status)
    put("trigger", record.trigger)
    put("interactionType", record.interactionType ?: JSONObject.NULL)
}

internal fun AndroidDebugTools.pushTemplateJSON(template: PushNotificationTemplate) = JSONObject().apply {
    put("id", template.id)
    put("name", template.name)
    put("title", template.title)
    put("body", template.body)
    put("subtitle", template.subtitle ?: JSONObject.NULL)
    put("badge", template.badge ?: JSONObject.NULL)
    put("sound", template.sound ?: JSONObject.NULL)
    put("category", template.category ?: JSONObject.NULL)
    put("userInfo", JSONObject(template.userInfo))
    put("isDefault", template.isDefault)
}

internal fun AndroidDebugTools.savePushHistory(context: Context) {
    val json = JSONArray()
    pushHistory.take(pushMaxHistoryCount).forEach { json.put(pushRecordJSON(it)) }
    pushPreferences(context).edit().putString("history", json.toString()).apply()
}

internal fun AndroidDebugTools.savePushTemplates(context: Context) {
    val json = JSONArray()
    pushTemplates.forEach { json.put(pushTemplateJSON(it)) }
    pushPreferences(context).edit().putString("templates", json.toString()).apply()
}

internal fun AndroidDebugTools.notificationsPermissionGranted(context: Context): Boolean =
    (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED) &&
        (!androidNotificationSettingsLoaded || androidNotificationsEnabled)

internal fun AndroidDebugTools.refreshNotificationSettings(context: Context) {
    notificationExecutor.execute {
        androidNotificationsEnabled = runCatching { NotificationManagerCompat.from(context).areNotificationsEnabled() }.getOrDefault(false)
        androidNotificationSettingsLoaded = true
    }
}

internal fun AndroidDebugTools.requestNotificationPermission(context: Context): String {
    if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
        val activity = foregroundActivity.get()
        if (activity != null) {
            activity.runOnUiThread {
                if (context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    activity.requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 5081)
                }
            }
            return "Android notification permission requested. Grant it, then try the action again."
        }
        return "Android notification permission is not granted. Open the host app and request it from an Activity."
    }
    if (androidNotificationSettingsLoaded && !androidNotificationsEnabled) {
        return "Notifications are disabled for this app. Choose Open notification settings to enable them."
    }
    return ""
}

/** `persist = false` leaves writing configuration and history to the caller, once for a whole update. */
internal fun AndroidDebugTools.togglePushSimulation(context: Context, persist: Boolean = true): String {
    pushEnabled = !pushEnabled
    if (persist) persistPushConfiguration(context)
    if (pushEnabled) {
        refreshNotificationSettings(context)
        publishEvent("app", "Push notification simulation enabled")
        val permissionMessage = requestNotificationPermission(context)
        return if (permissionMessage.isEmpty()) "Push notification simulation enabled. Android notification permission is available."
        else "Push notification simulation enabled.\n$permissionMessage"
    }
    pendingPushNotifications.values.forEach { it.cancel(true) }
    pendingPushNotifications.clear()
    pushScheduleOwners.clear()
    pushHistory.filter { it.status == "Scheduled" }.forEach { record ->
        notificationExecutor.execute { NotificationManagerCompat.from(context).cancel(record.id.hashCode()) }
        updatePushNotification(context, record.id, "Dismissed", persist = persist)
    }
    publishEvent("app", "Push notification simulation disabled")
    return "Push notification simulation disabled. Pending local notifications were cancelled."
}

internal fun AndroidDebugTools.pushNotificationSnapshot(context: Context, showAllHistory: Boolean = false): String {
    val permission = when {
        Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED -> "Not granted"
        !androidNotificationSettingsLoaded -> "Checking Android notification settings"
        androidNotificationsEnabled -> "Allowed"
        else -> "Disabled in system settings"
    }
    val pageCount = ((pushHistory.size + PUSH_HISTORY_PAGE_SIZE - 1) / PUSH_HISTORY_PAGE_SIZE).coerceAtLeast(1)
    pushHistoryPage = pushHistoryPage.coerceIn(1, pageCount)
    val firstIndex = (pushHistoryPage - 1) * PUSH_HISTORY_PAGE_SIZE
    val pageRecords = if (showAllHistory) pushHistory.toList() else pushHistory.drop(firstIndex).take(PUSH_HISTORY_PAGE_SIZE)
    val history = pageRecords.joinToString("\n\n") { record ->
        val scheduled = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault()).format(Date(record.scheduledAtMs))
        val delivered = record.deliveryAtMs?.let { "\nDelivered: ${SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date(it))}" }.orEmpty()
        val metadata = buildList {
            record.subtitle?.let { add("Subtitle: $it") }
            record.badge?.let { add("Badge: $it") }
            record.sound?.let { add("Sound: $it") }
            if (record.userInfo.isNotEmpty()) add("User info: ${record.userInfo.entries.joinToString { "${it.key}=${it.value}" }}")
        }.joinToString("\n")
        "${record.status} · ${record.title}\n${record.body}${if (metadata.isEmpty()) "" else "\n$metadata"}\nTrigger: ${record.trigger}\nScheduled: $scheduled${delivered}\nID: ${record.id}"
    }.ifEmpty { "No simulated notifications yet." }
    val templates = pushTemplates.joinToString("\n") { "${it.name}: ${it.title} — ${it.body}" }.ifEmpty { "No templates configured." }
    val pageLabel = if (showAllHistory) "all pages" else "page $pushHistoryPage/$pageCount"
    return "Simulation: ${if (pushEnabled) "Enabled" else "Disabled"}\nNotification permission: $permission\nChannel: $NOTIFICATION_CHANNEL\n\nConfiguration\nShow in foreground: $pushShowInForeground\nPlay sound: $pushPlaySound\nShow badge: $pushShowBadge\nAuto interaction: $pushAutoInteraction (${pushInteractionDelaySeconds}s)\nSimulate real push: $pushSimulateRealPush\nDefault sound: $pushDefaultSound\nMax history: $pushMaxHistoryCount\n\nTemplates\n$templates\n\nNotification history (${pushHistory.size}) · $pageLabel\n$history${if (showAllHistory) "" else "\n\nUse History page with a page number to browse older notifications."}"
}

internal fun AndroidDebugTools.addPushRecord(context: Context, record: PushNotificationRecord) {
    synchronized(pushHistory) {
        pushHistory.add(0, record)
        pushHistoryPage = 1
        while (pushHistory.size > pushMaxHistoryCount) pushHistory.removeAt(pushHistory.lastIndex)
        savePushHistory(context)
    }
}

internal fun AndroidDebugTools.updatePushNotification(context: Context, id: String, status: String, interactionType: String? = null, persist: Boolean = true) {
    synchronized(pushHistory) {
        val index = pushHistory.indexOfFirst { it.id == id }
        if (index < 0) return
        val old = pushHistory[index]
        pushHistory[index] = old.copy(
            status = status,
            deliveryAtMs = if (status == "Delivered" || status == "Interacted") old.deliveryAtMs ?: System.currentTimeMillis() else old.deliveryAtMs,
            interactionType = interactionType ?: old.interactionType
        )
        if (persist) savePushHistory(context)
    }
    publishEvent("app", "Notification $id status: $status")
}

internal fun AndroidDebugTools.schedulePushNotification(
    context: Context,
    title: String,
    body: String,
    delaySeconds: Long = 0,
    subtitle: String? = null,
    badge: Int? = null,
    sound: String? = null,
    category: String? = null,
    userInfo: Map<String, String> = emptyMap(),
    requestedID: String? = null
): String = schedulePush(context, title, body, delaySeconds, subtitle, badge, sound, category, userInfo, requestedID).message

internal fun AndroidDebugTools.schedulePush(
    context: Context,
    title: String,
    body: String,
    delaySeconds: Long = 0,
    subtitle: String? = null,
    badge: Int? = null,
    sound: String? = null,
    category: String? = null,
    userInfo: Map<String, String> = emptyMap(),
    requestedID: String? = null
): PushScheduleResult {
    fun rejected(message: String) = PushScheduleResult(false, message)
    if (!pushEnabled) return rejected("Enable push notification simulation before creating a notification.")
    // The caller's id is kept, as on iOS, so removing or interacting by that id finds it. It is
    // trimmed here as removal and interaction trim it, so all three agree.
    val callerID = requestedID?.trim()?.takeIf { it.isNotEmpty() }
    if (callerID != null && (pushHistory.any { it.id == callerID } || pushScheduleOwners.containsKey(callerID))) {
        return rejected("A simulated notification with id '$callerID' already exists.")
    }
    if (delaySeconds < 0) return rejected("Delay must be zero or more seconds.")
    val permissionMessage = requestNotificationPermission(context)
    if (permissionMessage.isNotEmpty()) return rejected(permissionMessage)
    val boundedDelay = delaySeconds.coerceAtMost(86_400L)
    val id = callerID ?: UUID.randomUUID().toString()
    // Owns `id` until this delivery runs or is cancelled. A delivery that no longer owns it (its
    // history was cleared and the id scheduled again) does nothing, so it never removes, posts
    // or marks the newer notification.
    val owner = Any()
    pushScheduleOwners[id] = owner
    val record = PushNotificationRecord(
        id = id,
        title = title,
        body = body,
        subtitle = subtitle,
        badge = badge,
        sound = sound,
        category = category,
        userInfo = userInfo,
        scheduledAtMs = System.currentTimeMillis(),
        deliveryAtMs = null,
        status = "Scheduled",
        trigger = if (boundedDelay == 0L) "Immediate" else "In ${boundedDelay}s",
        interactionType = null
    )
    addPushRecord(context, record)
    val deliver = Runnable {
        if (!pushScheduleOwners.remove(id, owner)) return@Runnable
        pendingPushNotifications.remove(id)
        if (!pushEnabled) {
            updatePushNotification(context, id, "Dismissed")
            return@Runnable
        }
        if (!notificationsPermissionGranted(context)) {
            updatePushNotification(context, id, "Failed")
            return@Runnable
        }
        val shouldShow = pushShowInForeground || !appInForeground
        if (shouldShow) {
            runCatching {
                val soundName = sound ?: if (pushPlaySound) pushDefaultSound else "silent"
                val channelID = notificationChannelID(context, soundName)
                val launchIntent = foregroundActivity.get()?.let { activity -> Intent(context, activity.javaClass) }
                    ?: context.packageManager.getLaunchIntentForPackage(context.packageName)
                    ?: Intent()
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                launchIntent.putExtra(PUSH_NOTIFICATION_ID_EXTRA, id)
                launchIntent.putExtra("debugswift_notification_title", title)
                launchIntent.putExtra("debugswift_notification_body", body)
                launchIntent.putExtra("debugswift_notification_user_info", JSONObject(userInfo).toString())
                val pendingIntent = PendingIntent.getActivity(
                    context,
                    id.hashCode(),
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
                )
                val notification = NotificationCompat.Builder(context, channelID)
                    .setSmallIcon(android.R.drawable.ic_dialog_info)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setSubText(subtitle)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                    .setContentIntent(pendingIntent)
                    .setAutoCancel(true)
                    .setNumber(if (pushShowBadge) badge ?: 0 else 0)
                    .setSound(resolveNotificationSound(context, soundName))
                    .setCategory(category?.takeIf { it.isNotBlank() } ?: NotificationCompat.CATEGORY_MESSAGE)
                    .build()
                NotificationManagerCompat.from(context).notify(id.hashCode(), notification)
            }.onFailure { error ->
                updatePushNotification(context, id, "Failed")
                log("Could not post local notification: ${error.message}", Log.ERROR)
            }
        }
        if (pushHistory.any { it.id == id && it.status != "Failed" }) {
            updatePushNotification(context, id, "Delivered")
            publishEvent("app", "Local test notification posted: $title")
            if (pushAutoInteraction) {
                mainHandler.postDelayed({
                    if (pushHistory.any { it.id == id && it.status == "Delivered" }) {
                        updatePushNotification(context, id, "Interacted", "Tap")
                    }
                }, (pushInteractionDelaySeconds.coerceAtLeast(0.0) * 1_000).toLong())
            }
        }
    }
    if (boundedDelay == 0L) {
        notificationExecutor.execute(deliver)
        return PushScheduleResult(true, "Local notification queued for immediate delivery: $title.")
    }
    pendingPushNotifications[id] = notificationExecutor.schedule(deliver, boundedDelay, TimeUnit.SECONDS)
    return PushScheduleResult(true, "Local notification scheduled in $boundedDelay seconds (ID: $id).")
}

internal fun AndroidDebugTools.resolveNotificationSound(context: Context, soundName: String): Uri? {
    if (soundName.equals("silent", ignoreCase = true) || soundName.isBlank()) return null
    if (soundName == "default") return android.provider.Settings.System.DEFAULT_NOTIFICATION_URI
    val resourceID = context.resources.getIdentifier(soundName, "raw", context.packageName)
    return if (resourceID != 0) Uri.parse("android.resource://${context.packageName}/$resourceID")
    else android.provider.Settings.System.DEFAULT_NOTIFICATION_URI
}

internal fun AndroidDebugTools.notificationChannelID(context: Context, soundName: String): String {
    if (Build.VERSION.SDK_INT < 26) return NOTIFICATION_CHANNEL
    val safeSound = soundName.lowercase(Locale.ROOT).replace(Regex("[^a-z0-9_]+"), "_").take(24).ifEmpty { "default" }
    val badgeSuffix = if (pushShowBadge) "_badge" else "_no_badge"
    val channelID = "${NOTIFICATION_CHANNEL}_${safeSound}$badgeSuffix"
    val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (manager.getNotificationChannel(channelID) == null) {
        val silent = soundName.equals("silent", ignoreCase = true)
        val channel = NotificationChannel(channelID, "DebugSwift tests${if (silent) " (silent)" else ""}${if (pushShowBadge) "" else " (no badge)"}", if (silent) NotificationManager.IMPORTANCE_LOW else NotificationManager.IMPORTANCE_DEFAULT)
        channel.setSound(resolveNotificationSound(context, soundName), null)
        channel.setShowBadge(pushShowBadge)
        manager.createNotificationChannel(channel)
    }
    return channelID
}

internal fun AndroidDebugTools.simulatePushTemplate(context: Context, value: String): String {
    val parts = value.split("|", limit = 2).map { it.trim() }
    val name = parts.firstOrNull().orEmpty()
    if (name.isBlank()) return "Enter a template name, optionally followed by |delay seconds."
    val template = pushTemplates.firstOrNull { it.name.equals(name, ignoreCase = true) }
        ?: return "No notification template named '$name'. Available: ${pushTemplates.joinToString { it.name }}"
    val delayValue = parts.getOrNull(1).orEmpty()
    val delay = delayValue.toLongOrNull() ?: if (delayValue.isBlank()) 0L else return "Template delay must be a whole number of seconds."
    if (delay < 0) return "Delay must be zero or more seconds."
    fun render(text: String?) = text?.replace(Regex("\\{\\{([^{}]+)\\}\\}")) { match -> template.userInfo[match.groupValues[1]].orEmpty() }
    return schedulePushNotification(
        context,
        render(template.title).orEmpty(),
        render(template.body).orEmpty(),
        delay,
        render(template.subtitle),
        template.badge,
        template.sound,
        template.category,
        template.userInfo
    )
}

internal fun AndroidDebugTools.runPushScenario(context: Context, value: String): String {
    val parts = value.split("|", limit = 4).map { it.trim() }
    val scenario = parts.firstOrNull().orEmpty().lowercase(Locale.ROOT).replace(Regex("[^a-z]"), "")
    val notifications = when (scenario) {
        "messageflow" -> listOf(
            Triple("New Message", "You have a message from John", 0L),
            Triple("Message Delivered", "Your message was delivered", 3L),
            Triple("John is typing...", "John is composing a message", 6L)
        )
        "newsupdates" -> listOf(
            Triple("Breaking News", "Major technology breakthrough announced", 0L),
            Triple("Sports Update", "Championship game ends in overtime", 5L),
            Triple("Weather Alert", "Severe weather warning in your area", 10L)
        )
        "marketingcampaign" -> listOf(
            Triple("Welcome Offer!", "Get 50% off your first purchase", 0L),
            Triple("Cart Reminder", "You have items waiting in your cart", 300L),
            Triple("Flash Sale! ⚡", "24-hour flash sale starts now", 600L)
        )
        "systemalerts" -> listOf(
            Triple("Security Alert", "New login from unknown device", 0L),
            Triple("Backup Complete", "Your data has been backed up successfully", 2L),
            Triple("Update Available", "A new app update is available", 4L)
        )
        "customflow" -> {
            if (parts.size < 3) return "For customFlow, enter customFlow|title|message|delay seconds."
            val delayValue = parts.getOrNull(3).orEmpty()
            val delay = delayValue.toLongOrNull() ?: if (delayValue.isBlank()) 0L else return "Delay must be a whole number of seconds."
            if (delay < 0) return "Delay must be zero or more seconds."
            return schedulePushNotification(context, parts[1], parts[2], delay)
                .let { "Custom flow: $it" }
        }
        else -> return "Choose messageFlow, newsUpdates, marketingCampaign, systemAlerts, or customFlow|title|message|delay."
    }
    if (!pushEnabled) return "Enable push notification simulation before running a scenario."
    val permissionMessage = requestNotificationPermission(context)
    if (permissionMessage.isNotEmpty()) return permissionMessage
    val results = notifications.map { (title, body, delay) -> schedulePushNotification(context, title, body, delay) }
    return "Scenario '${parts[0]}' started.\n" + results.joinToString("\n")
}

/** Why `setPushConfiguration` would reject this option, or null when it accepts it. Changes nothing. */
internal fun AndroidDebugTools.pushConfigurationError(name: String, raw: String): String? {
    val key = name.lowercase(Locale.ROOT).replace("_", "").replace("-", "")
    val bool = raw.trim().toBooleanStrictOrNull()
    return when (key) {
        "showinforeground", "playsound", "showbadge", "autointeraction", "simulaterealpush" ->
            if (bool == null) "$name must be true or false." else null
        // The same range NotificationConfiguration allows on iOS; the panel offers a few presets of it.
        "interactiondelay" ->
            if (raw.trim().toDoubleOrNull()?.let { it.isFinite() && it >= 0 } == true) null else "interactionDelay must be a number of seconds, 0 or more."
        "defaultsound" -> if (raw.isBlank()) "defaultSound cannot be empty. Use default, silent, or a raw resource name." else null
        "maxhistorycount" ->
            if ((raw.trim().toIntOrNull() ?: 0) > 0) null else "maxHistoryCount must be a whole number above 0."
        else -> "Unknown notification option '$name'."
    }
}

internal fun AndroidDebugTools.setPushConfiguration(context: Context, value: String, persist: Boolean = true): String {
    val parts = value.split("=", limit = 2).map { it.trim() }
    if (parts.size != 2 || parts[0].isBlank()) {
        return "Set one option at a time: showInForeground=true, playSound=true, showBadge=true, autoInteraction=false, interactionDelay=3, simulateRealPush=false, defaultSound=default, maxHistoryCount=100."
    }
    val key = parts[0].lowercase(Locale.ROOT).replace("_", "").replace("-", "")
    val raw = parts[1]
    val bool = raw.toBooleanStrictOrNull()
    when (key) {
        "showinforeground" -> pushShowInForeground = bool ?: return "showInForeground must be true or false."
        "playsound" -> pushPlaySound = bool ?: return "playSound must be true or false."
        "showbadge" -> pushShowBadge = bool ?: return "showBadge must be true or false."
        "autointeraction" -> pushAutoInteraction = bool ?: return "autoInteraction must be true or false."
        "interactiondelay" -> pushInteractionDelaySeconds = raw.toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 } ?: return "interactionDelay must be a number of seconds, 0 or more."
        "simulaterealpush" -> pushSimulateRealPush = bool ?: return "simulateRealPush must be true or false."
        "defaultsound" -> {
            if (raw.isBlank()) return "defaultSound cannot be empty. Use default, silent, or a raw resource name."
            pushDefaultSound = raw
        }
        "maxhistorycount" -> pushMaxHistoryCount = raw.toIntOrNull()?.takeIf { it > 0 } ?: return "maxHistoryCount must be a whole number above 0."
        else -> return "Unknown notification option '${parts[0]}'."
    }
    if (persist) {
        persistPushConfiguration(context)
        savePushHistory(context)
    }
    return "Notification configuration updated: ${parts[0]}=$raw."
}

internal fun AndroidDebugTools.addPushTemplate(context: Context, value: String): String {
    val parts = value.split("|", limit = 8).map { it.trim() }
    if (parts.size < 3 || parts[0].isBlank() || parts[1].isBlank() || parts[2].isBlank()) {
        return "Enter name|title|body|subtitle|badge|sound|category|key=value,... to add a template."
    }
    val badgeValue = parts.getOrNull(4).orEmpty()
    val badge = badgeValue.toIntOrNull() ?: if (badgeValue.isBlank()) null else return "Badge must be a whole number."
    val userInfo = parsePushUserInfo(parts.getOrNull(7).orEmpty())
        ?: return "User info must use key=value pairs separated by commas."
    val template = PushNotificationTemplate(
        UUID.randomUUID().toString(),
        parts[0],
        parts[1],
        parts[2],
        parts.getOrNull(3)?.takeIf { it.isNotBlank() },
        badge,
        parts.getOrNull(5)?.takeIf { it.isNotBlank() },
        parts.getOrNull(6)?.takeIf { it.isNotBlank() },
        userInfo,
        false
    )
    return storePushTemplate(context, template)
}

internal fun AndroidDebugTools.storePushTemplate(context: Context, template: PushNotificationTemplate): String {
    if (pushTemplates.any { it.name.equals(template.name, ignoreCase = true) }) return "A template named '${template.name}' already exists."
    // Ids are unique too, so removeTemplate(id:) always finds the template it was given.
    if (pushTemplates.any { it.id == template.id }) return "A template with id '${template.id}' already exists."
    pushTemplates.add(template)
    savePushTemplates(context)
    publishEvent("app", "Push notification template added: ${template.name}")
    return "Notification template '${template.name}' added."
}

internal fun AndroidDebugTools.removePushTemplate(context: Context, value: String): String {
    val name = value.trim()
    if (name.isBlank()) return "Enter a notification template name to remove."
    val template = pushTemplates.firstOrNull { it.name.equals(name, ignoreCase = true) }
        ?: return "No notification template named '$name'."
    if (template.isDefault) return "Default notification templates cannot be removed."
    pushTemplates.remove(template)
    savePushTemplates(context)
    publishEvent("app", "Push notification template removed: ${template.name}")
    return "Notification template '${template.name}' removed."
}

internal fun AndroidDebugTools.clearPushHistory(): String {
    val context = appContext ?: return "Android runtime has not been installed."
    pushHistory.clear()
    savePushHistory(context)
    publishEvent("app", "Push notification history cleared")
    return "Push notification history cleared."
}

internal fun AndroidDebugTools.removePushNotification(context: Context, value: String): String {
    val id = value.trim()
    if (id.isBlank()) return "Enter the notification ID shown in its history entry."
    val record = pushHistory.firstOrNull { it.id == id } ?: return "No simulated notification with ID '$id'."
    pendingPushNotifications.remove(id)?.cancel(true)
    pushScheduleOwners.remove(id)
    notificationExecutor.execute { NotificationManagerCompat.from(context).cancel(id.hashCode()) }
    pushHistory.remove(record)
    savePushHistory(context)
    return "Removed notification '${record.title}' from history."
}

internal fun AndroidDebugTools.interactWithPushNotification(context: Context, value: String): String {
    val id = value.trim()
    if (pushHistory.none { it.id == id }) return "Enter a notification ID from history."
    updatePushNotification(context, id, "Interacted", "Tap")
    return "Interaction recorded for notification $id."
}

internal fun AndroidDebugTools.resendPushNotification(context: Context, value: String): String {
    val id = value.trim()
    val record = pushHistory.firstOrNull { it.id == id }
        ?: return "Enter a notification ID from history."
    return schedulePushNotification(context, record.title, record.body, subtitle = record.subtitle, badge = record.badge, sound = record.sound, category = record.category, userInfo = record.userInfo)
}

internal fun AndroidDebugTools.showPushHistoryPage(context: Context, value: String): String {
    val requestedPage = value.trim().toIntOrNull()
        ?: return "Enter a history page number from 1 to ${((pushHistory.size + PUSH_HISTORY_PAGE_SIZE - 1) / PUSH_HISTORY_PAGE_SIZE).coerceAtLeast(1)}."
    val lastPage = ((pushHistory.size + PUSH_HISTORY_PAGE_SIZE - 1) / PUSH_HISTORY_PAGE_SIZE).coerceAtLeast(1)
    if (requestedPage !in 1..lastPage) return "History page must be between 1 and $lastPage."
    pushHistoryPage = requestedPage
    return pushNotificationSnapshot(context)
}

internal fun AndroidDebugTools.openNotificationSettings(context: Context): String = runCatching {
    val intent = if (Build.VERSION.SDK_INT >= 26) {
        Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName)
    } else {
        Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
    }
    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    context.startActivity(intent)
    "Opened Android notification settings for ${context.packageName}."
}.getOrElse { "Could not open notification settings: ${it.message}" }
