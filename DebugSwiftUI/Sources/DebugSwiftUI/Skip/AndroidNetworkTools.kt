package debug.swift.android

import android.content.Context
import android.content.ClipData
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.io.IOException
import org.json.JSONArray
import org.json.JSONObject
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import debug.swift.android.AndroidDebugTools.NetworkRecord

// Network capture: records, history, the inspector screens, HAR export and replay.
// Part of AndroidDebugTools: these extensions use the object's state, which lives in AndroidDebugTools.kt.

fun AndroidDebugTools.exportHar(featureID: String = "network_history"): File? {
    val context = appContext ?: return null
    val entries = org.json.JSONArray()
    val records = when (featureID) {
        "http" -> networkRecords.filter { it.source == "http" }
        "graphql" -> networkRecords.filter { it.source == "http" && it.graphqlOperation.isNotBlank() }
        "har_export" -> networkRecords.filter { it.source == "http" }
        "webview_network" -> networkRecords.filter { it.source == "webview" }
        "network_history" -> liveHistoryRecords()
        else -> networkRecords.toList()
    }
    // DebugSwiftCore writes the HAR, as on iOS; the records are already masked.
    records.forEach { record ->
        entries.put(
            org.json.JSONObject()
                .put("method", record.method)
                .put("url", record.url)
                .put("startedAt", record.timestamp)
                .put("durationMs", record.durationMs)
                .put("status", record.status)
                .put("requestHeaders", headersJSON(record.requestHeaders))
                .put("responseHeaders", headersJSON(record.responseHeaders))
                .put("requestBody", record.requestBody)
                .put("responseBody", record.responseBody)
        )
    }
    val reply = JSONObject(DebugSwiftCoreBridge.call("har.encode", JSONObject().put("records", entries).toString()))
    val file = File(context.cacheDir, "debugswift-${System.currentTimeMillis()}.har")
    file.writeText(reply.optString("json"))
    publishEvent("resources", "Exported ${entries.length()} network requests to ${file.name}")
    return file
}

internal fun AndroidDebugTools.exportWebSockets(context: Context): File =
    File(context.cacheDir, "debugswift-websocket-${System.currentTimeMillis()}.txt").apply {
        writeText(webSocketConnections.sortedByDescending { it.createdAtMs }.joinToString("\n\n") { connection ->
            buildString {
                appendLine("${connection.url}\nStatus: ${connection.status}")
                appendLine("Started: ${Date(connection.createdAtMs)}")
                appendLine("Last activity: ${Date(connection.lastActivityAtMs)}")
                append(connection.frames.sortedBy { it.timestampMs }.joinToString("\n\n") { frame ->
                    webSocketFrameSnapshot(connection, frame, forExport = true)
                }.ifEmpty { "No frames recorded." })
            }
        }.ifEmpty { webSocketRecords.joinToString("\n\n") })
    }

internal fun AndroidDebugTools.loadNetworkHistory(context: Context) {
    val file = File(context.filesDir, "debugswift-network-history.json")
    if (!file.isFile) return
    runCatching {
        val rows = org.json.JSONObject(file.readText()).optJSONArray("requests") ?: return
        val cutoff = System.currentTimeMillis() - networkHistoryRetentionMs
        for (index in 0 until rows.length()) {
            val row = rows.getJSONObject(index)
            // Files written before capture was masked hold raw values; mask them on load.
            val masked = DebugSwiftNetworkSanitizer.sanitize(
                url = row.optString("url"),
                requestHeaders = decodeHeaders(row.optJSONObject("requestHeaders")),
                responseHeaders = decodeHeaders(row.optJSONObject("responseHeaders")),
                requestBody = row.optString("requestBody"),
                responseBody = row.optString("responseBody"),
                decryptedResponseBody = row.optString("decryptedResponseBody")
            )
            val record = NetworkRecord(
                    timestamp = row.optLong("timestamp"),
                    method = row.optString("method"),
                    url = masked.url,
                    status = row.optInt("status"),
                    durationMs = row.optLong("durationMs"),
                    requestBytes = row.optLong("requestBytes"),
                    responseBytes = row.optLong("responseBytes"),
                    requestHeaders = masked.requestHeaders,
                    responseHeaders = masked.responseHeaders,
                    requestBody = masked.requestBody,
                    responseBody = masked.responseBody,
                    decryptedResponseBody = masked.decryptedResponseBody.take(64_000),
                    error = row.optString("error"),
                    graphqlOperation = row.optString("graphqlOperation"),
                    source = row.optString("source", "http"),
                    id = row.optString("id").ifBlank { UUID.randomUUID().toString() },
                    sessionID = row.optString("sessionID").ifBlank { "legacy-session" }
                )
            if (record.timestamp >= cutoff && isPersistableNetworkRecord(record)) {
                networkHistoryRecords.add(record)
            }
        }
        trimNetworkHistory()
        // Rewrite the file so raw values from older versions do not stay on disk.
        persistNetworkHistory()
    }.onFailure { error ->
        log("Could not read saved network history: ${error.message}", Log.WARN)
    }
}

internal fun AndroidDebugTools.persistNetworkHistory() {
    val context = appContext ?: return
    val cutoff = System.currentTimeMillis() - networkHistoryRetentionMs
    val snapshot = networkHistoryRecords.filter { it.timestamp >= cutoff }
        .takeLast(MAX_NETWORK_HISTORY_RECORDS)
    persistenceExecutor.execute {
        runCatching {
            val rows = org.json.JSONArray()
            snapshot.forEach { record ->
                rows.put(org.json.JSONObject()
                    .put("timestamp", record.timestamp)
                    .put("method", record.method)
                    .put("url", record.url)
                    .put("status", record.status)
                    .put("durationMs", record.durationMs)
                    .put("requestBytes", record.requestBytes)
                    .put("responseBytes", record.responseBytes)
                    .put("requestHeaders", encodeHeaders(record.requestHeaders))
                    .put("responseHeaders", encodeHeaders(record.responseHeaders))
                    .put("requestBody", record.requestBody.take(8_000))
                    .put("responseBody", record.responseBody.take(16_000))
                    .put("decryptedResponseBody", record.decryptedResponseBody.take(16_000))
                    .put("error", record.error)
                    .put("graphqlOperation", record.graphqlOperation)
                    .put("source", record.source)
                    .put("id", record.id)
                    .put("sessionID", record.sessionID))
            }
            val target = File(context.filesDir, "debugswift-network-history.json")
            val temporary = File(context.filesDir, "debugswift-network-history.tmp")
            temporary.writeText(org.json.JSONObject().put("requests", rows).toString())
            if (!temporary.renameTo(target)) {
                target.writeText(temporary.readText())
                temporary.delete()
            }
        }
    }
}

internal fun AndroidDebugTools.isPersistableNetworkRecord(record: NetworkRecord): Boolean {
    if (record.source != "http") return false
    val contentType = headerValue(record.responseHeaders, "Content-Type")?.lowercase(Locale.ROOT).orEmpty()
    val contentDisposition = headerValue(record.responseHeaders, "Content-Disposition")?.lowercase(Locale.ROOT).orEmpty()
    val fileMarkers = listOf(
        "image/", "video/", "audio/", "application/pdf", "application/zip",
        "application/x-zip-compressed", "application/octet-stream", "multipart/form-data",
        "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument",
        "application/msword", "application/vnd.ms-powerpoint"
    )
    return fileMarkers.none { marker -> contentType.contains(marker) } && !contentDisposition.contains("attachment")
}

internal fun AndroidDebugTools.trimNetworkHistory() {
    val cutoff = System.currentTimeMillis() - networkHistoryRetentionMs
    networkHistoryRecords.removeAll { it.timestamp < cutoff || !isPersistableNetworkRecord(it) }
    while (networkHistoryRecords.size > MAX_NETWORK_HISTORY_RECORDS) networkHistoryRecords.removeAt(0)
}

internal fun AndroidDebugTools.encodeHeaders(headers: Map<String, List<String>>): org.json.JSONObject =
    org.json.JSONObject().also { json -> headers.forEach { (key, values) -> json.put(key, org.json.JSONArray(values)) } }

internal fun AndroidDebugTools.decodeHeaders(headers: org.json.JSONObject?): Map<String, List<String>> {
    if (headers == null) return emptyMap()
    return buildMap {
        val keys = headers.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val values = headers.optJSONArray(key) ?: continue
            put(key, buildList { for (index in 0 until values.length()) add(values.optString(index)) })
        }
    }
}

internal fun AndroidDebugTools.headerValue(headers: Map<String, List<String>>, name: String): String? =
    headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value?.firstOrNull()

internal fun AndroidDebugTools.formatHeaders(headers: Map<String, List<String>>): String =
    headers.entries.joinToString("\n") { (name, values) -> "$name: ${values.joinToString(", ")}" }

internal fun AndroidDebugTools.networkSnapshot(featureID: String): String {
    if (featureID == "network_injection") {
        return "Injection enabled: $networkInjectionEnabled\nDelay: ${requestDelayMs}ms\nFail next request: ${failNextRequest.get()}\nHTTP error: ${httpErrorCode.takeIf { it != 0 } ?: "off"}\nResponse rewrites: ${responseRewrites.size}\nBlocked URL patterns: ${blockedURLPatterns.size}"
    }
    if (featureID == "network_thresholds") {
        return thresholdSnapshot()
    }
    if (featureID == "websocket") {
        return webSocketSnapshot()
    }
    if (featureID == "webview_network") {
        val requests = networkRecords.filter { it.source == "webview" }.takeLast(30).asReversed()
        return "Observed WebView hosts:\n" + webViewHosts.takeLast(30).joinToString("\n").ifEmpty { "No host app WebViews have reported activity." } +
            "\n\nRecorded navigation/resources:\n" + requests.joinToString("\n") { "${it.method} ${it.url}" }.ifEmpty { "Install DebugSwiftWebViewClient on host WebViews to record navigation and resource requests." }
    }
    if (featureID == "har_export") {
        val count = networkRecords.count { it.source == "http" }
        return "Captured requests available for HAR export: $count\nUse Export to write a .har file into the app cache."
    }
    if (featureID == "network_encryption") {
        return "Response decryption: ${if (DebugSwiftNetworkConfig.isDecryptionEnabled()) "enabled" else "disabled"}\nRegistered URL patterns: ${DebugSwiftNetworkConfig.decryptors.size}\nKeys are kept in memory for this process."
    }
    val historyDescription = if (featureID == "network_history") {
        "Saved HTTP sessions: ${networkHistoryRecords.groupBy { it.sessionID }.size} · requests: ${networkHistoryRecords.size}\nHistory is retained for the last 7 days.\n"
    } else ""
    val recordsForFeature = when (featureID) {
        "graphql" -> networkRecords.filter { it.source == "http" && it.graphqlOperation.isNotBlank() }
        "http" -> networkRecords.filter { it.source == "http" }
        "network_history" -> liveHistoryRecords()
        else -> networkRecords.toList()
    }
    val matchingRecords = recordsForFeature.filter { record ->
        val query = networkFilter.trim().lowercase()
        query.isEmpty() || listOf(record.url, record.method, record.requestBody, record.responseBody, record.graphqlOperation)
            .any { it.lowercase().contains(query) }
    }
    val lines = matchingRecords.takeLast(40).asReversed().mapIndexed { index, record ->
        "#${index + 1} ${record.method} ${record.url}\n  ${record.status} · ${record.durationMs}ms · ${record.responseBytes} bytes" +
            (record.graphqlOperation.takeIf { it.isNotBlank() }?.let { "\n  GraphQL: $it" } ?: "") +
            (record.error.takeIf { it.isNotBlank() }?.let { "\n  Error: $it" } ?: "") +
            (formatHeaders(record.requestHeaders).takeIf { it.isNotBlank() }?.let { "\n  Request headers:\n$it" } ?: "") +
            (record.requestBody.takeIf { it.isNotBlank() }?.let { "\n  Request body: ${it.take(2_000)}" } ?: "") +
            (formatHeaders(record.responseHeaders).takeIf { it.isNotBlank() }?.let { "\n  Response headers:\n$it" } ?: "") +
            (record.decryptedResponseBody.takeIf { it.isNotBlank() }?.let { "\n  Decrypted response: ${it.take(2_000)}" } ?: "") +
            (record.responseBody.takeIf { it.isNotBlank() }?.let { "\n  Response: ${it.take(2_000)}" } ?: "")
    }
    val filterDescription = networkFilter.takeIf { it.isNotBlank() }?.let { "\nFilter: $it · ${matchingRecords.size} matches" }.orEmpty()
    val capturedTitle = when (featureID) {
        "graphql" -> "GraphQL operations"
        "network_history" -> "Saved network requests"
        else -> "HTTP requests"
    }
    return historyDescription + "Captured $capturedTitle: ${recordsForFeature.size}$filterDescription\n" + lines.joinToString("\n\n").ifEmpty { "No matching requests. Add DebugSwiftOkHttpInterceptor to the host OkHttpClient.Builder." }
}

fun AndroidDebugTools.networkInspectorSnapshotJSON(featureID: String): String {
    val records = when (featureID) {
        "webview_network" -> networkRecords.filter { it.source == "webview" }
        "graphql" -> networkRecords.filter { it.source == "http" && it.graphqlOperation.isNotBlank() }
        "har_export" -> networkRecords.filter { it.source == "http" }
        "network_history" -> liveHistoryRecords()
        else -> networkRecords.filter { it.source == "http" }
    }
    val rows = JSONArray()
    records.takeLast(if (featureID == "network_history") MAX_NETWORK_HISTORY_RECORDS else MAX_RECORDS).forEach { record ->
        rows.put(JSONObject()
            .put("id", record.id)
            .put("url", record.url)
            .put("method", record.method)
            .put("statusCode", record.status.toString())
            .put("timestamp", SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(record.timestamp)))
            .put("timestampMilliseconds", record.timestamp)
            .put("durationMilliseconds", record.durationMs)
            .put("requestBytes", record.requestBytes)
            .put("responseBytes", record.responseBytes)
            .put("requestHeaders", JSONObject().apply { record.requestHeaders.forEach { (key, values) -> put(key, values.joinToString(", ")) } })
            .put("responseHeaders", JSONObject().apply { record.responseHeaders.forEach { (key, values) -> put(key, values.joinToString(", ")) } })
            .put("requestBody", record.requestBody)
            .put("responseBody", record.responseBody)
            .put("decryptedResponseBody", record.decryptedResponseBody)
            .put("requestBodyBase64", android.util.Base64.encodeToString(record.requestBody.toByteArray(StandardCharsets.UTF_8), android.util.Base64.NO_WRAP))
            .put("responseBodyBase64", android.util.Base64.encodeToString(record.responseBody.toByteArray(StandardCharsets.UTF_8), android.util.Base64.NO_WRAP))
            .put("decryptedResponseBodyBase64", android.util.Base64.encodeToString(record.decryptedResponseBody.toByteArray(StandardCharsets.UTF_8), android.util.Base64.NO_WRAP))
            .put("mimeType", headerValue(record.responseHeaders, "Content-Type") ?: "")
            .put("error", record.error)
            .put("graphqlOperation", record.graphqlOperation)
            .put("source", record.source)
            .put("isSuccess", isSuccessfulExchange(record)))
    }
    return JSONObject().put("requests", rows).toString()
}

/**
 * Matches iOS, where a 1xx, 3xx, 4xx or 5xx status marks the request as failed: only a 2xx
 * response without a transport error counts as a success.
 */
internal fun AndroidDebugTools.isSuccessfulExchange(record: NetworkRecord): Boolean =
    record.error.isBlank() && record.status in 200..299

fun AndroidDebugTools.networkSessionHistorySnapshotJSON(): String {
    val cutoff = System.currentTimeMillis() - networkHistoryRetentionMs
    val sessions = JSONArray()
    networkHistoryRecords.asSequence()
        .filter { it.timestamp >= cutoff }
        .groupBy { it.sessionID }
        .entries
        .sortedByDescending { (_, records) -> records.minOfOrNull { it.timestamp } ?: 0L }
        .forEach { (sessionID, records) ->
            val startedAt = records.minOfOrNull { it.timestamp } ?: 0L
            val endedAt = records.maxOfOrNull { it.timestamp } ?: startedAt
            val active = sessionID == currentNetworkSessionID
            sessions.put(JSONObject()
                .put("id", sessionID)
                .put("startedAtMilliseconds", startedAt)
                .put("endedAtMilliseconds", if (active) JSONObject.NULL else endedAt)
                .put("requestCount", records.size)
                .put("isActive", active))
        }
    return JSONObject()
        .put("sessions", sessions)
        .put("retentionDays", networkHistoryRetentionMs / (24L * 60 * 60 * 1_000))
        .toString()
}

fun AndroidDebugTools.networkSessionRequestsSnapshotJSON(sessionID: String): String {
    val requests = JSONArray()
    liveHistoryRecords()
        .filter { it.sessionID == sessionID }
        .sortedBy { it.timestamp }
        .forEach { requests.put(networkSessionRequestJSONObject(it)) }
    return JSONObject().put("requests", requests).toString()
}

fun AndroidDebugTools.performNetworkSessionHistoryAction(actionID: String, sessionID: String): String = when (actionID) {
    "clear_all" -> {
        networkHistoryRecords.clear()
        currentNetworkSessionID = UUID.randomUUID().toString()
        persistNetworkHistory()
        publishEvent("network", "Saved network sessions cleared")
        "All saved network sessions were cleared."
    }
    "delete_session" -> {
        if (networkHistoryRecords.none { it.sessionID == sessionID }) {
            "This session is no longer available."
        } else {
            networkHistoryRecords.removeAll { it.sessionID == sessionID }
            if (sessionID == currentNetworkSessionID) currentNetworkSessionID = UUID.randomUUID().toString()
            persistNetworkHistory()
            publishEvent("network", "Deleted saved session $sessionID")
            "Network session deleted."
        }
    }
    "import_session" -> importNetworkSessionAsRewriteRules(sessionID)
    else -> "Unknown session history action: $actionID."
}

fun AndroidDebugTools.shareNetworkSessionRequestLog(text: String): String {
    val context = appContext ?: return "Android runtime has not been installed."
    val file = File(context.cacheDir, "debugswift-request-${System.currentTimeMillis()}.txt")
    file.writeText(text)
    return shareExport(file, context)
}

fun AndroidDebugTools.replayNetworkSessionRequest(requestID: String): String {
    val record = liveHistoryRecords().firstOrNull { it.id == requestID }
        ?: return "This request is no longer available."
    return replayNetworkRecord(record)
}

internal fun AndroidDebugTools.importNetworkSessionAsRewriteRules(sessionID: String): String {
    return synchronized(this) {
        val records = liveHistoryRecords().filter { it.sessionID == sessionID }.sortedBy { it.timestamp }
        if (records.isEmpty()) return "This session has no requests to import."

        val rules = JSONArray()
        val uniqueRules = mutableSetOf<String>()
        records.forEach { record ->
            val pattern = record.url.trim()
            if (pattern.isEmpty()) return@forEach
            val responseBody = record.decryptedResponseBody.ifBlank { record.responseBody }
            val method = record.method.trim().uppercase(Locale.ROOT)
                .takeIf { it in setOf("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS") }
                .orEmpty()
            val status = record.status
            val key = listOf(pattern, method, status?.toString().orEmpty(), responseBody).joinToString("\u001f")
            if (!uniqueRules.add(key)) return@forEach
            rules.put(JSONObject()
                .put("id", UUID.randomUUID().toString())
                .put("urlPattern", pattern)
                .put("responseBody", responseBody)
                .put("responseStatusCode", status ?: JSONObject.NULL)
                .put("httpMethod", if (method.isBlank()) JSONObject.NULL else method)
                .put("isEnabled", true)
                .put("matchType", "exact"))
        }

        val settings = JSONObject(networkInjectionSettingsJSON())
        val rewrite = settings.optJSONObject("rewrite") ?: JSONObject()
        rewrite.put("isEnabled", true)
            .put("rules", rules)
            .put("shortCircuitEnabled", true)
        settings.put("rewrite", rewrite)
        applyNetworkInjectionSettingsJSON(settings.toString())
        return "Replaced existing Response Modifier rules with ${rules.length()} rule(s) from this session. Response Modifier is now active."
    }
}

internal fun AndroidDebugTools.networkSessionRequestJSONObject(record: NetworkRecord): JSONObject {
    val timestamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(record.timestamp))
    return JSONObject()
        .put("id", record.id)
        .put("url", record.url)
        .put("method", record.method)
        .put("statusCode", record.status.toString())
        .put("timestamp", timestamp)
        .put("timestampMilliseconds", record.timestamp)
        .put("durationMilliseconds", record.durationMs.toInt())
        .put("requestBytes", record.requestBytes)
        .put("responseBytes", record.responseBytes)
        .put("requestHeaders", JSONObject().apply { record.requestHeaders.forEach { (key, values) -> put(key, values.joinToString(", ")) } })
        .put("responseHeaders", JSONObject().apply { record.responseHeaders.forEach { (key, values) -> put(key, values.joinToString(", ")) } })
        .put("requestBody", record.requestBody)
        .put("responseBody", record.responseBody)
        .put("decryptedResponseBody", record.decryptedResponseBody)
        .put("requestBodyBase64", android.util.Base64.encodeToString(record.requestBody.toByteArray(StandardCharsets.UTF_8), android.util.Base64.NO_WRAP))
        .put("responseBodyBase64", android.util.Base64.encodeToString(record.responseBody.toByteArray(StandardCharsets.UTF_8), android.util.Base64.NO_WRAP))
        .put("decryptedResponseBodyBase64", android.util.Base64.encodeToString(record.decryptedResponseBody.toByteArray(StandardCharsets.UTF_8), android.util.Base64.NO_WRAP))
        .put("mimeType", headerValue(record.responseHeaders, "Content-Type") ?: "")
        .put("error", record.error)
        .put("graphqlOperation", record.graphqlOperation)
        .put("source", record.source)
        .put("isSuccess", isSuccessfulExchange(record))
}

fun AndroidDebugTools.performNetworkInspectorAction(featureID: String, actionID: String, requestID: String): String {
    val context = appContext ?: return "Android runtime has not been installed."
    if (actionID == "copy_text") return copyToClipboard(context, "DebugSwift", requestID)
    if (actionID == "clear") return clear(featureID)
    if (actionID == "export_har") {
        val file = exportHar(featureID) ?: return "There are no requests to export."
        return shareExport(file, context)
    }

    val records = when (featureID) {
        "webview_network" -> networkRecords.filter { it.source == "webview" }
        "graphql" -> networkRecords.filter { it.source == "http" && it.graphqlOperation.isNotBlank() }
        "har_export" -> networkRecords.filter { it.source == "http" }
        "network_history" -> liveHistoryRecords()
        else -> networkRecords.filter { it.source == "http" }
    }
    val record = records.firstOrNull { it.id == requestID }
        ?: return "This request is no longer available."

    return when (actionID) {
        "copy_url" -> copyToClipboard(context, "Request URL", record.url)
        "copy_log" -> copyToClipboard(context, "Request log", networkRecordLog(record))
        "copy_curl" -> copyToClipboard(context, "cURL", networkRecordCurl(record))
        "share_log" -> {
            val file = File(context.cacheDir, "debugswift-request-${record.id.take(8)}.txt")
            file.writeText(networkRecordLog(record))
            shareExport(file, context)
        }
        "delete" -> {
            if (featureID == "network_history") networkHistoryRecords.removeAll { it.id == record.id }
            else networkRecords.removeAll { it.id == record.id }
            persistNetworkHistory()
            publishEvent("network", "Removed ${record.method} ${record.url}")
            "Request removed."
        }
        "replay" -> replayNetworkRecord(record)
        else -> "Unknown network action: $actionID."
    }
}

internal fun AndroidDebugTools.copyToClipboard(context: Context, label: String, text: String): String {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager
        ?: return "Android clipboard is unavailable."
    clipboard.setPrimaryClip(ClipData.newPlainText(label, text))
    return "$label copied."
}

internal fun AndroidDebugTools.networkRecordLog(record: NetworkRecord): String = buildString {
    appendLine("[${record.method}] ${Date(record.timestamp)} (${record.status})")
    appendLine("\n------- URL -------\n${record.url}")
    appendLine("\n------- REQUEST HEADER -------\n${formatHeaders(record.requestHeaders).ifBlank { "No data" }}")
    appendLine("\n------- REQUEST -------\n${record.requestBody.ifBlank { "No data" }}")
    appendLine("\n------- RESPONSE HEADER -------\n${formatHeaders(record.responseHeaders).ifBlank { "No data" }}")
    appendLine("\n------- RESPONSE -------\n${record.decryptedResponseBody.ifBlank { record.responseBody.ifBlank { "No data" } }}")
    appendLine("\n------- RESPONSE SIZE -------\n${formatBytes(record.responseBytes)}")
    appendLine("\n------- TOTAL TIME -------\n${record.durationMs}ms")
    append("\n------- MIME TYPE -------\n${headerValue(record.responseHeaders, "Content-Type") ?: "No data"}")
}

/** DebugSwiftCore's cURL command for the request, credentials masked, as on iOS. */
internal fun AndroidDebugTools.networkRecordCurl(record: NetworkRecord): String {
    val input = JSONObject().put("method", record.method).put("url", record.url)
        .put("headers", headersJSON(record.requestHeaders)).put("body", record.requestBody)
    return JSONObject(DebugSwiftCoreBridge.call("curl.command", input.toString())).optString("command")
}

internal fun AndroidDebugTools.headersJSON(headers: Map<String, List<String>>): JSONObject =
    JSONObject().also { json -> headers.forEach { (name, values) -> json.put(name, org.json.JSONArray(values)) } }

internal fun AndroidDebugTools.replayNetworkRecord(record: NetworkRecord): String {
    val method = record.method.uppercase(Locale.ROOT)
    // Records loaded from the history file only have masked values, so their credentials are not resent.
    val original = replayRequest(record)
    val replayUrl = original?.url ?: record.url
    val replayHeaders = original?.headers ?: record.requestHeaders
    val replayBody = original?.body ?: record.requestBody
    val requestBody = if (method == "GET" || method == "HEAD") null else
        replayBody.toRequestBody(headerValue(replayHeaders, "Content-Type")?.toMediaTypeOrNull())
    val request = runCatching {
        Request.Builder().url(replayUrl).apply {
            replayHeaders.forEach { (name, values) -> values.forEach { addHeader(name, it) } }
        }.method(method, requestBody).build()
    }.getOrElse { return "Could not replay request: ${it.message ?: "invalid request"}" }
    val started = SystemClock.elapsedRealtime()
    networkReplayClient.newCall(request).enqueue(object : Callback {
        override fun onFailure(call: Call, error: IOException) {
            recordNetwork(
                method = method,
                url = replayUrl,
                status = 0,
                durationMs = SystemClock.elapsedRealtime() - started,
                requestBytes = replayBody.toByteArray(StandardCharsets.UTF_8).size.toLong(),
                responseBytes = 0,
                requestBody = replayBody,
                responseBody = "",
                error = error.localizedMessage ?: "Replay failed",
                requestHeaders = replayHeaders,
                source = record.source
            )
        }

        override fun onResponse(call: Call, response: Response) {
            response.use {
                val bytes = it.body?.bytes() ?: ByteArray(0)
                recordNetwork(
                    method = method,
                    url = replayUrl,
                    status = it.code,
                    durationMs = SystemClock.elapsedRealtime() - started,
                    requestBytes = replayBody.toByteArray(StandardCharsets.UTF_8).size.toLong(),
                    responseBytes = bytes.size.toLong(),
                    requestBody = replayBody,
                    responseBody = String(bytes, StandardCharsets.UTF_8),
                    requestHeaders = replayHeaders,
                    responseHeaders = it.headers.toMultimap(),
                    source = record.source
                )
            }
        }
    })
    val note = if (original == null) " Masked credentials from the saved history are not resent." else ""
    if (!networkAccepts(replayUrl)) {
        return "Request replay started. The app's ignoredURLs or onlyURLs filters leave this URL out, so its response will not appear in the request list.$note"
    }
    return "Request replay started. Its response will appear in the request list.$note"
}

internal fun AndroidDebugTools.selectNetworkRequest(featureID: String, value: String): String {
    if (featureID !in setOf("http", "graphql", "network_history")) {
        return "Request details are not available for $featureID."
    }
    val records = when (featureID) {
        "http" -> networkRecords.filter { it.source == "http" }
        "graphql" -> networkRecords.filter { it.source == "http" && it.graphqlOperation.isNotBlank() }
        else -> networkRecords.toList()
    }
    val matching = records.filter { record ->
        val query = networkFilter.trim().lowercase()
        query.isEmpty() || listOf(record.url, record.method, record.requestBody, record.responseBody, record.graphqlOperation)
            .any { it.lowercase().contains(query) }
    }.takeLast(40).asReversed()
    val index = value.trim().toIntOrNull()
    val selected = if (index != null) matching.getOrNull(index - 1) else {
        val query = value.trim()
        matching.firstOrNull { it.url.contains(query, ignoreCase = true) || it.graphqlOperation.contains(query, ignoreCase = true) }
    }
    if (selected == null) {
        return if (index != null) "No request at position $index. Refresh the list; request numbers start at 1 with the newest request."
        else "Enter a request number from the list, or a URL/GraphQL operation name to search."
    }
    return buildString {
        appendLine("${selected.method} ${selected.url}")
        appendLine("Status: ${selected.status}")
        appendLine("Duration: ${selected.durationMs}ms")
        appendLine("Started: ${Date(selected.timestamp)}")
        appendLine("Request size: ${formatBytes(selected.requestBytes)}")
        appendLine("Response size: ${formatBytes(selected.responseBytes)}")
        selected.graphqlOperation.takeIf { it.isNotBlank() }?.let { appendLine("GraphQL operation: $it") }
        selected.error.takeIf { it.isNotBlank() }?.let { appendLine("Error: $it") }
        appendLine("\nRequest headers\n${formatHeaders(selected.requestHeaders).ifBlank { "(none)" }}")
        appendLine("\nRequest body\n${selected.requestBody.ifBlank { "(none)" }}")
        appendLine("\nResponse headers\n${formatHeaders(selected.responseHeaders).ifBlank { "(none)" }}")
        appendLine("\nResponse body\n${selected.responseBody.ifBlank { "(none)" }}")
        if (selected.decryptedResponseBody.isNotBlank() && selected.decryptedResponseBody != selected.responseBody) {
            appendLine("\nDecrypted response body\n${selected.decryptedResponseBody}")
        }
    }
}

/** Saved history inside the retention window: what every history read and action sees. */
internal fun AndroidDebugTools.liveHistoryRecords(): List<NetworkRecord> {
    val cutoff = System.currentTimeMillis() - networkHistoryRetentionMs
    return networkHistoryRecords.filter { it.timestamp >= cutoff }
}

/**
 * Whether a request passes the host's `ignoredURLs` and `onlyURLs` filters. As on iOS, where such
 * a request never reaches DebugSwift, one left out is not captured, counted, blocked or injected.
 */
fun AndroidDebugTools.networkAccepts(url: String): Boolean {
    if (networkIgnoredURLs.any { it.isNotEmpty() && url.contains(it) }) return false
    val only = networkOnlyURLs.filter { it.isNotEmpty() }
    return only.isEmpty() || only.any { url.contains(it) }
}
