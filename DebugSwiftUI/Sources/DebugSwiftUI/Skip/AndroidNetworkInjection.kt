package debug.swift.android

import android.content.Context
import android.os.Build
import android.os.Looper
import android.os.SystemClock
import android.net.Uri
import java.io.File
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import okhttp3.Request
import okhttp3.Response

// Network injection: delays, failures, rewrites, blocking, request thresholds and their CSV rules.
// Part of AndroidDebugTools: these extensions use the object's state, which lives in AndroidDebugTools.kt.

internal fun AndroidDebugTools.rememberReplayRequest(id: String, request: ReplayRequest) {
    synchronized(replayRequests) { replayRequests[id] = request }
}

internal fun AndroidDebugTools.replayRequest(record: NetworkRecord): ReplayRequest? = synchronized(replayRequests) { replayRequests[record.id] }

fun AndroidDebugTools.setRequestDelay(milliseconds: Long) {
    synchronized(this) {
        requestDelayMs = milliseconds.coerceIn(0L, 60_000L)
        val current = networkInjectionSettings
        networkInjectionSettings = current.copy(delay = current.delay.copy(
            isEnabled = requestDelayMs > 0,
            fixedDelay = requestDelayMs / 1_000.0
        ))
    }
}

fun AndroidDebugTools.failNextNetworkRequest() {
    failNextRequest.set(true)
}

fun AndroidDebugTools.setHTTPErrorInjection(statusCode: Int) {
    synchronized(this) {
        httpErrorCode = if (statusCode in 400..599) statusCode else 0
        val current = networkInjectionSettings
        networkInjectionSettings = current.copy(failure = current.failure.copy(
            isEnabled = httpErrorCode != 0,
            failureRate = 1.0,
            failureType = "httpError",
            customStatusCodes = listOfNotNull(httpErrorCode.takeIf { it != 0 })
        ))
    }
}

fun AndroidDebugTools.addResponseRewrite(pattern: String, replacement: String) {
    synchronized(this) {
        val current = networkInjectionSettings
        val rule = NetworkRewriteRule(
            id = UUID.randomUUID().toString(),
            urlPattern = pattern,
            responseBody = replacement,
            responseStatusCode = null,
            httpMethod = null,
            isEnabled = true,
            matchType = "wildcard"
        )
        networkInjectionSettings = current.copy(rewrite = current.rewrite.copy(isEnabled = true, rules = current.rewrite.rules + rule))
        runCatching { responseRewrites.add(Regex(pattern) to replacement) }
    }
}

fun AndroidDebugTools.exportNetworkInjectionRulesCSV(): String {
    val context = appContext ?: return "Android runtime has not been installed."
    val file = File(context.cacheDir, "response_modifier_rules_${System.currentTimeMillis()}.csv")
    return runCatching {
        file.writeText(networkInjectionRulesCSV(), Charsets.UTF_8)
        shareExport(file, context)
    }.getOrElse { "Could not export response modifier rules: ${it.message}" }
}

/** The response modifier rules as CSV, the format the iOS settings screen uses. No file, no sharing. */
fun AndroidDebugTools.networkInjectionRulesCSV(): String {
    val rows = mutableListOf("url_pattern,response_status_code,response_body,http_method")
    networkInjectionSettings.rewrite.rules.forEach { rule ->
        rows.add(listOf(
            csvEscape(rule.urlPattern),
            csvEscape(rule.responseStatusCode?.toString().orEmpty()),
            csvEscape(rule.responseBody),
            csvEscape(rule.httpMethod.orEmpty())
        ).joinToString(","))
    }
    return rows.joinToString("\n")
}

fun AndroidDebugTools.importNetworkInjectionRulesCSV(csv: String): String {
    return synchronized(this) {
        val (rows, parseError) = parseCSVRows(csv)
        if (parseError != null) return parseError
        val header = rows.firstOrNull() ?: return "The CSV file is empty."
        if (header.map { it.trim().lowercase(Locale.ROOT) } != listOf("url_pattern", "response_status_code", "response_body", "http_method")) {
            return "Invalid CSV header. Expected: url_pattern,response_status_code,response_body,http_method"
        }
        val imported = mutableListOf<NetworkRewriteRule>()
        rows.drop(1).forEachIndexed { index, row ->
            val rowNumber = index + 2
            if (row.all { it.trim().isEmpty() }) return@forEachIndexed
            if (row.size != 4) return "Row $rowNumber has an invalid number of columns."
            val pattern = row[0].trim()
            if (pattern.isEmpty()) return "Row $rowNumber has an empty url_pattern value."
            val rawStatus = row[1].trim()
            val status = if (rawStatus.isEmpty()) null else rawStatus.toIntOrNull()?.takeIf { it in 100..599 }
                ?: return "Row $rowNumber has an invalid response_status_code value."
            val method = row[3].trim().uppercase(Locale.ROOT).takeIf { value ->
                value in setOf("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS")
            }
            imported.add(NetworkRewriteRule(
                id = UUID.randomUUID().toString(),
                urlPattern = pattern,
                responseBody = row[2],
                responseStatusCode = status,
                httpMethod = method,
                isEnabled = true,
                matchType = if (pattern.contains('*') || pattern.contains('?')) "wildcard" else "exact"
            ))
        }
        val current = networkInjectionSettings
        val rules = current.rewrite.rules.toMutableList()
        var created = 0
        var updated = 0
        imported.forEach { incoming ->
            val existingIndex = rules.indexOfFirst { it.urlPattern == incoming.urlPattern && it.httpMethod == incoming.httpMethod }
            if (existingIndex >= 0) {
                rules[existingIndex] = rules[existingIndex].copy(
                    responseBody = incoming.responseBody,
                    responseStatusCode = incoming.responseStatusCode,
                    httpMethod = incoming.httpMethod
                )
                updated += 1
            } else {
                rules.add(incoming)
                created += 1
            }
        }
        networkInjectionSettings = current.copy(rewrite = current.rewrite.copy(rules = rules))
        appContext?.getSharedPreferences(NETWORK_INJECTION_STATE_PREFS, Context.MODE_PRIVATE)?.edit()
            ?.putString("settings", networkInjectionSettingsJSONObject(networkInjectionSettings).toString())
            ?.apply()
        return "Imported $created new rule(s) and updated $updated existing rule(s)."
    }
}

internal fun AndroidDebugTools.csvEscape(value: String): String = if (value.any { it == ',' || it == '"' || it == '\n' || it == '\r' }) {
    "\"${value.replace("\"", "\"\"")}\""
} else value

internal fun AndroidDebugTools.parseCSVRows(text: String): Pair<List<List<String>>, String?> {
    val rows = mutableListOf<List<String>>()
    var row = mutableListOf<String>()
    val field = StringBuilder()
    var inQuotes = false
    var didCloseQuotedField = false
    var rowNumber = 1
    var index = 0
    while (index < text.length) {
        val character = text[index]
        when {
            character == '"' && inQuotes && index + 1 < text.length && text[index + 1] == '"' -> {
                field.append('"')
                index += 1
            }
            character == '"' && inQuotes -> {
                inQuotes = false
                didCloseQuotedField = true
            }
            character == '"' && !inQuotes && field.isEmpty() -> inQuotes = true
            character == '"' -> return rows to "Row $rowNumber has invalid CSV format."
            character == ',' && !inQuotes -> {
                row.add(field.toString())
                field.setLength(0)
                didCloseQuotedField = false
            }
            (character == '\n' || character == '\r') && !inQuotes -> {
                row.add(field.toString())
                rows.add(row)
                row = mutableListOf()
                field.setLength(0)
                didCloseQuotedField = false
                rowNumber += 1
                if (character == '\r' && index + 1 < text.length && text[index + 1] == '\n') index += 1
            }
            !inQuotes && didCloseQuotedField && !character.isWhitespace() -> return rows to "Row $rowNumber has invalid CSV format."
            !didCloseQuotedField -> field.append(character)
        }
        index += 1
    }
    if (inQuotes) return rows to "Row $rowNumber has invalid CSV format."
    if (field.isNotEmpty() || row.isNotEmpty()) {
        row.add(field.toString())
        rows.add(row)
    }
    return rows to null
}

/**
 * Applies the delay, failure and rewrite settings. `resetTransientState` also clears the
 * one-shot and quick controls (`failNextNetworkRequest()`, the fixed delay and HTTP error, the
 * quick rewrites): true when the settings are replaced as a whole, false for a patch of a few
 * fields, which must not disarm a failure armed meanwhile.
 */
internal fun AndroidDebugTools.applyNetworkInjectionSettings(json: String, resetTransientState: Boolean): String {
    val parsed = runCatching { JSONObject(json) }.getOrElse {
        return "Settings are not valid JSON: ${it.message}"
    }
    val delayJSON = parsed.optJSONObject("delay") ?: JSONObject()
    val failureJSON = parsed.optJSONObject("failure") ?: JSONObject()
    val rewriteJSON = parsed.optJSONObject("rewrite") ?: JSONObject()
    val delay = DelayInjectionSettings(
        isEnabled = delayJSON.optBoolean("isEnabled", false),
        fixedDelay = if (delayJSON.isNull("fixedDelay")) null else delayJSON.optDouble("fixedDelay", 1.0).coerceIn(0.0, 60.0),
        minDelay = delayJSON.optDouble("minDelay", 1.0).coerceIn(0.0, 60.0),
        maxDelay = delayJSON.optDouble("maxDelay", 3.0).coerceIn(delayJSON.optDouble("minDelay", 1.0).coerceIn(0.0, 60.0), 60.0),
        urlPatterns = jsonStringArray(delayJSON.optJSONArray("urlPatterns")),
        httpMethods = jsonStringArray(delayJSON.optJSONArray("httpMethods")).map { it.uppercase(Locale.ROOT) }.distinct()
    )
    val statusCodes = jsonIntArray(failureJSON.optJSONArray("customStatusCodes")).filter { it in 400..599 }.distinct()
    val failure = FailureInjectionSettings(
        isEnabled = failureJSON.optBoolean("isEnabled", false),
        failureRate = failureJSON.optDouble("failureRate", 0.5).coerceIn(0.0, 1.0),
        failureType = failureJSON.optString("failureType", "timeout"),
        customStatusCodes = statusCodes.ifEmpty { listOf(500) },
        urlPatterns = jsonStringArray(failureJSON.optJSONArray("urlPatterns")),
        httpMethods = jsonStringArray(failureJSON.optJSONArray("httpMethods")).map { it.uppercase(Locale.ROOT) }.distinct(),
        customDomain = failureJSON.optString("customDomain", "DebugSwift.CustomNetworkError"),
        customCode = failureJSON.optInt("customCode", -1),
        customDescription = failureJSON.optString("customDescription", "Injected custom network error.")
    )
    val rulesJSON = rewriteJSON.optJSONArray("rules") ?: JSONArray()
    val rules = (0 until rulesJSON.length()).mapNotNull { index ->
        val ruleJSON = rulesJSON.optJSONObject(index) ?: return@mapNotNull null
        val pattern = ruleJSON.optString("urlPattern", "").trim()
        if (pattern.isEmpty()) return@mapNotNull null
        val status = if (ruleJSON.isNull("responseStatusCode")) null else ruleJSON.optInt("responseStatusCode").takeIf { it in 100..599 }
        // org.json turns a JSON null into the string "null", which would never match a method.
        val method = if (ruleJSON.isNull("httpMethod")) null
            else ruleJSON.optString("httpMethod", "").uppercase(Locale.ROOT).takeIf { it.isNotEmpty() }
        NetworkRewriteRule(
            id = ruleJSON.optString("id", UUID.randomUUID().toString()),
            urlPattern = pattern,
            responseBody = ruleJSON.optString("responseBody", ""),
            responseStatusCode = status,
            httpMethod = method,
            isEnabled = ruleJSON.optBoolean("isEnabled", true),
            matchType = if (pattern.contains('*') || pattern.contains('?')) "wildcard" else "exact"
        )
    }
    val rewrite = RewriteInjectionSettings(
        isEnabled = rewriteJSON.optBoolean("isEnabled", false),
        rules = rules,
        autoEnableOnRun = rewriteJSON.optBoolean("autoEnableOnRun", false),
        shortCircuitEnabled = rewriteJSON.optBoolean("shortCircuitEnabled", true),
        multipleMatchEnabled = rewriteJSON.optBoolean("multipleMatchEnabled", false)
    )
    val settings = NetworkInjectionSettings(delay, failure, rewrite)
    networkInjectionSettings = settings
    if (resetTransientState) {
        requestDelayMs = 0L
        httpErrorCode = 0
        responseRewrites.clear()
        failNextRequest.set(false)
    }
    appContext?.getSharedPreferences(NETWORK_INJECTION_STATE_PREFS, Context.MODE_PRIVATE)?.edit()
        ?.putString("settings", networkInjectionSettingsJSONObject(settings).toString())
        ?.apply()
    return "Network injection settings applied."
}

internal fun AndroidDebugTools.loadNetworkInjectionSettings(context: Context) {
    val json = context.getSharedPreferences(NETWORK_INJECTION_STATE_PREFS, Context.MODE_PRIVATE)
        .getString("settings", null) ?: return
    applyNetworkInjectionSettingsJSON(json)
}

internal fun AndroidDebugTools.networkInjectionSettingsJSONObject(settings: NetworkInjectionSettings): JSONObject {
    val delay = settings.delay
    val failure = settings.failure
    val rewrite = settings.rewrite
    val delayJSON = JSONObject()
        .put("isEnabled", delay.isEnabled)
        .put("fixedDelay", delay.fixedDelay ?: JSONObject.NULL)
        .put("minDelay", delay.minDelay)
        .put("maxDelay", delay.maxDelay)
        .put("urlPatterns", JSONArray(delay.urlPatterns))
        .put("httpMethods", JSONArray(delay.httpMethods))
    val failureJSON = JSONObject()
        .put("isEnabled", failure.isEnabled)
        .put("failureRate", failure.failureRate)
        .put("failureType", failure.failureType)
        .put("customStatusCodes", JSONArray(failure.customStatusCodes))
        .put("urlPatterns", JSONArray(failure.urlPatterns))
        .put("httpMethods", JSONArray(failure.httpMethods))
        .put("customDomain", failure.customDomain)
        .put("customCode", failure.customCode)
        .put("customDescription", failure.customDescription)
    val rules = JSONArray()
    rewrite.rules.forEach { rule ->
        rules.put(JSONObject()
            .put("id", rule.id)
            .put("urlPattern", rule.urlPattern)
            .put("responseBody", rule.responseBody)
            .put("responseStatusCode", rule.responseStatusCode ?: JSONObject.NULL)
            .put("httpMethod", rule.httpMethod ?: JSONObject.NULL)
            .put("isEnabled", rule.isEnabled)
            .put("matchType", rule.matchType))
    }
    val rewriteJSON = JSONObject()
        .put("isEnabled", rewrite.isEnabled)
        .put("rules", rules)
        .put("autoEnableOnRun", rewrite.autoEnableOnRun)
        .put("shortCircuitEnabled", rewrite.shortCircuitEnabled)
        .put("multipleMatchEnabled", rewrite.multipleMatchEnabled)
    return JSONObject().put("delay", delayJSON).put("failure", failureJSON).put("rewrite", rewriteJSON)
}

internal fun AndroidDebugTools.jsonStringArray(array: JSONArray?): List<String> = if (array == null) emptyList() else
    (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotBlank) }

internal fun AndroidDebugTools.jsonIntArray(array: JSONArray?): List<Int> = if (array == null) emptyList() else
    (0 until array.length()).mapNotNull { index -> array.optInt(index).takeIf { !array.isNull(index) } }

fun AndroidDebugTools.setRequestThreshold(limit: Int, windowSeconds: Int) {
    synchronized(this) {
        thresholdLimit = limit.coerceIn(1, 1000)
        thresholdWindowMs = windowSeconds.coerceAtLeast(1) * 1000L
        thresholdCount = thresholdRequestTimes.count { SystemClock.elapsedRealtime() - it <= thresholdWindowMs }
    }
    persistThresholdSettings()
}

internal fun AndroidDebugTools.thresholdSnapshot(): String {
    val state = synchronized(this) {
        val now = SystemClock.elapsedRealtime()
        val count = if (thresholdTrackingEnabled) thresholdRequestTimes.count { now - it <= thresholdWindowMs } else 0
        thresholdCount = count
        listOf(thresholdTrackingEnabled, thresholdLimit, thresholdWindowMs / 1000L, thresholdBlockRequests, count, thresholdBreaches.size)
    }
    val endpoints = endpointThresholdLimits.entries.sortedBy { it.key }.joinToString("\n") { (endpoint, config) ->
        "$endpoint — ${config.limit} per ${config.windowMs / 1000L}s"
    }.ifEmpty { "No endpoint limits configured." }
    val breaches = thresholdBreaches.takeLast(5).asReversed().joinToString("\n") { breach ->
        "${Date(breach.timestampMs)} · ${breach.message}"
    }.ifEmpty { "No threshold breaches." }
    return "threshold|${state[0]}|${state[1]}|${state[2]}|${state[3]}|${state[4]}|${state[5]}\n" +
        "ENDPOINT LIMITS\n$endpoints\n\nRECENT BREACHES\n$breaches"
}

internal fun AndroidDebugTools.recordThresholdRequest(url: String) {
    val now = SystemClock.elapsedRealtime()
    val endpoint = thresholdEndpoint(url)
    var breach: ThresholdBreachRecord? = null
    synchronized(this) {
        if (!thresholdTrackingEnabled) return
        if (thresholdStartMs == 0L || now - thresholdStartMs > thresholdWindowMs) {
            thresholdStartMs = now
        }
        thresholdRequestTimes.addLast(now)
        while (thresholdRequestTimes.isNotEmpty() && now - thresholdRequestTimes.peekFirst() > maxOf(thresholdWindowMs, 300_000L)) {
            thresholdRequestTimes.removeFirst()
        }
        thresholdCount = thresholdRequestTimes.count { now - it <= thresholdWindowMs }

        val endpointCounter = endpointThresholdCounts.computeIfAbsent(endpoint) { EndpointThresholdCount() }
        endpointCounter.timestamps.addLast(now)
        val endpointWindow = maxOf(endpointThresholdLimits[endpoint]?.windowMs ?: 0L, thresholdWindowMs, 300_000L)
        while (endpointCounter.timestamps.isNotEmpty() && now - endpointCounter.timestamps.peekFirst() > endpointWindow) {
            endpointCounter.timestamps.removeFirst()
        }

        val endpointLimit = endpointThresholdLimits[endpoint]
        val effectiveCount: Int
        val effectiveLimit: Int
        if (endpointLimit != null) {
            effectiveCount = endpointCounter.timestamps.count { now - it <= endpointLimit.windowMs }
            effectiveLimit = endpointLimit.limit
        } else {
            effectiveCount = thresholdCount
            effectiveLimit = thresholdLimit
        }
        if (effectiveCount > effectiveLimit) {
            val emoji = if (endpointLimit == null) thresholdAlertEmoji else "⚠️"
            val text = if (endpointLimit == null) thresholdAlertMessage else "Request limit exceeded!"
            val message = "$emoji $text ($effectiveCount/$effectiveLimit)"
            // Wall-clock time: the breach is shown with its date; `now` stays for the rate windows.
            breach = ThresholdBreachRecord(System.currentTimeMillis(), effectiveCount, effectiveLimit, endpoint, message)
            thresholdBreaches.add(breach!!)
            while (thresholdBreaches.size > 1000) thresholdBreaches.removeAt(0)
        }
    }
    breach?.let { publishEvent("network", it.message) }
}

internal fun AndroidDebugTools.thresholdEndpoint(url: String): String {
    val parsed = Uri.parse(url)
    val components = parsed.pathSegments.filter { it.isNotBlank() }
    return components.take(2).joinToString("/").ifEmpty { parsed.host ?: "unknown" }
}

internal fun AndroidDebugTools.loadThresholdSettings(context: Context) {
    val prefs = context.getSharedPreferences(THRESHOLD_STATE_PREFS, Context.MODE_PRIVATE)
    thresholdLimit = prefs.getInt("limit", 1000)
    thresholdWindowMs = prefs.getLong("window_ms", 60_000L).coerceAtLeast(1_000L)
    thresholdTrackingEnabled = prefs.getBoolean("tracking_enabled", false)
    thresholdBlockRequests = prefs.getBoolean("block_requests", false)
    thresholdAlertEmoji = prefs.getString("alert_emoji", "⚠️") ?: "⚠️"
    thresholdAlertMessage = prefs.getString("alert_message", "Request limit exceeded!") ?: "Request limit exceeded!"
    val endpoints = runCatching { JSONArray(prefs.getString("endpoint_limits", "[]")) }.getOrNull()
    endpointThresholdLimits.clear()
    if (endpoints != null) {
        for (index in 0 until endpoints.length()) {
            val endpoint = endpoints.optJSONObject(index) ?: continue
            val name = endpoint.optString("endpoint").takeIf { it.isNotBlank() } ?: continue
            val limit = endpoint.optInt("limit", 0).takeIf { it > 0 } ?: continue
            val windowMs = endpoint.optLong("windowMs", 60_000L).coerceAtLeast(1_000L)
            endpointThresholdLimits[name] = EndpointThresholdLimit(limit, windowMs)
        }
    }
    if (thresholdTrackingEnabled) thresholdStartMs = SystemClock.elapsedRealtime()
}

internal fun AndroidDebugTools.persistThresholdSettings() {
    val context = appContext ?: return
    val endpoints = JSONArray()
    endpointThresholdLimits.entries.sortedBy { it.key }.forEach { (name, config) ->
        endpoints.put(JSONObject().put("endpoint", name).put("limit", config.limit).put("windowMs", config.windowMs))
    }
    context.getSharedPreferences(THRESHOLD_STATE_PREFS, Context.MODE_PRIVATE).edit()
        .putInt("limit", thresholdLimit)
        .putLong("window_ms", thresholdWindowMs)
        .putBoolean("tracking_enabled", thresholdTrackingEnabled)
        .putBoolean("block_requests", thresholdBlockRequests)
        .putString("alert_emoji", thresholdAlertEmoji)
        .putString("alert_message", thresholdAlertMessage)
        .putString("endpoint_limits", endpoints.toString())
        .apply()
}

fun AndroidDebugTools.shouldBlock(url: String): Boolean {
    if (!networkAccepts(url)) return false
    if (networkInjectionEnabled && blockedURLPatterns.any { it.containsMatchIn(url) }) return true
    return synchronized(this) {
        if (!thresholdTrackingEnabled || !thresholdBlockRequests) return@synchronized false
        val endpoint = thresholdEndpoint(url)
        val endpointLimit = endpointThresholdLimits[endpoint]
        val endpointCounter = endpointThresholdCounts[endpoint]
        val now = SystemClock.elapsedRealtime()
        val window = endpointLimit?.windowMs ?: thresholdWindowMs
        val count = if (endpointLimit != null) {
            endpointCounter?.timestamps?.count { now - it <= window } ?: 0
        } else {
            thresholdRequestTimes.count { now - it <= window }
        }
        val limit = endpointLimit?.limit ?: thresholdLimit
        limit > 0 && count >= limit
    }
}

fun AndroidDebugTools.requestDelay(): Long = requestDelayMs.takeIf { networkInjectionEnabled } ?: 0L

fun AndroidDebugTools.requestDelay(url: String, method: String): Long {
    if (!networkInjectionEnabled) return 0L
    val config = networkInjectionSettings.delay
    if (!config.isEnabled || !matchesRequest(url, method, config.urlPatterns, config.httpMethods)) {
        return requestDelayMs.coerceAtLeast(0L)
    }
    val seconds = config.fixedDelay ?: run {
        if (config.maxDelay <= config.minDelay) config.minDelay
        else config.minDelay + (config.maxDelay - config.minDelay) * kotlin.random.Random.nextDouble()
    }
    return (seconds.coerceIn(0.0, 60.0) * 1_000).toLong()
}

fun AndroidDebugTools.consumeFailure(): Boolean {
    return networkInjectionEnabled && failNextRequest.compareAndSet(true, false)
}

fun AndroidDebugTools.consumeNetworkFailure(url: String, method: String): NetworkFailure? {
    if (!networkInjectionEnabled) return null
    val config = networkInjectionSettings.failure
    if (config.isEnabled && matchesRequest(url, method, config.urlPatterns, config.httpMethods) &&
        kotlin.random.Random.nextDouble() <= config.failureRate) {
        if (config.failureType == "httpError") {
            return NetworkFailure(config.failureType, config.customStatusCodes.randomOrNull() ?: 500)
        }
        return NetworkFailure(config.failureType, customDomain = config.customDomain, customCode = config.customCode, customDescription = config.customDescription)
    }
    if (failNextRequest.compareAndSet(true, false)) return NetworkFailure("timeout")
    if (httpErrorCode in 400..599) return NetworkFailure("httpError", httpErrorCode)
    return null
}

fun AndroidDebugTools.injectedHTTPError(): Int = httpErrorCode.takeIf { networkInjectionEnabled } ?: 0

fun AndroidDebugTools.rewriteResponse(url: String, body: String): String {
    if (!networkInjectionEnabled) return body
    return matchingNetworkRewriteRule(url, "GET")?.responseBody ?: body
}

fun AndroidDebugTools.matchingNetworkRewriteRule(url: String, method: String): NetworkRewriteRule? {
    if (!networkInjectionEnabled) return null
    val rewrite = networkInjectionSettings.rewrite
    if (!rewrite.isEnabled) {
        val legacy = responseRewrites.firstOrNull { (pattern, _) -> pattern.containsMatchIn(url) }
        return legacy?.let { (pattern, replacement) ->
            NetworkRewriteRule(pattern.toString(), pattern.toString(), replacement, null, null, true, "wildcard")
        }
    }
    val matches = rewrite.rules.filter { rule ->
        if (!rule.isEnabled) return@filter false
        if (!rule.httpMethod.isNullOrEmpty() && !rule.httpMethod.equals(method, ignoreCase = true)) return@filter false
        when (rule.matchType) {
            "exact" -> url.equals(rule.urlPattern, ignoreCase = true)
            else -> matchesWildcardURL(url, listOf(rule.urlPattern), full = true, queryExact = true)
        }
    }
    if (matches.isEmpty()) return null
    if (!rewrite.multipleMatchEnabled || matches.size == 1) return matches.first()
    return chooseNetworkRewriteRule(matches)
}

internal fun AndroidDebugTools.chooseNetworkRewriteRule(matches: List<NetworkRewriteRule>): NetworkRewriteRule? {
    val activity = foregroundActivity.get() ?: return matches.firstOrNull()
    if (Looper.myLooper() == Looper.getMainLooper()) return matches.firstOrNull()
    val latch = CountDownLatch(1)
    var selection: NetworkRewriteRule? = null
    mainHandler.post {
        if (activity.isFinishing || (Build.VERSION.SDK_INT >= 17 && activity.isDestroyed)) {
            latch.countDown()
        } else {
            val labels = matches.map { rule ->
                "HTTP ${rule.responseStatusCode ?: 200} · ${rule.httpMethod ?: "All methods"} · ${rule.urlPattern}"
            }.toTypedArray()
            android.app.AlertDialog.Builder(activity)
                .setTitle("Choose Response Modifier Rule")
                .setItems(labels) { _, index ->
                    selection = matches.getOrNull(index)
                    latch.countDown()
                }
                .setNegativeButton("No Rewrite") { _, _ -> latch.countDown() }
                .setOnCancelListener { latch.countDown() }
                .show()
        }
    }
    latch.await(30, TimeUnit.SECONDS)
    return selection
}

fun AndroidDebugTools.shouldShortCircuitResponseRewrite(): Boolean = networkInjectionEnabled && networkInjectionSettings.rewrite.shortCircuitEnabled

internal fun AndroidDebugTools.matchesRequest(url: String, method: String, urlPatterns: List<String>, httpMethods: List<String>): Boolean {
    val methodMatches = httpMethods.isEmpty() || httpMethods.any { it.equals(method, ignoreCase = true) }
    if (!methodMatches) return false
    return urlPatterns.isEmpty() || matchesWildcardURL(url, urlPatterns, full = false, queryExact = false)
}

/** DebugSwiftCore's URL wildcard matching, the one iOS uses for the same rules. */
internal fun AndroidDebugTools.matchesWildcardURL(url: String, patterns: List<String>, full: Boolean, queryExact: Boolean): Boolean {
    val input = JSONObject().put("url", url).put("patterns", org.json.JSONArray(patterns))
        .put("full", full).put("queryExact", queryExact)
    return JSONObject(DebugSwiftCoreBridge.call("url.matches", input.toString())).optBoolean("matches")
}

internal fun AndroidDebugTools.clearInjectionRules() {
    synchronized(this) {
        requestDelayMs = 0L
        httpErrorCode = 0
        failNextRequest.set(false)
        responseRewrites.clear()
        blockedURLPatterns.clear()
        networkInjectionSettings = NetworkInjectionSettings()
        appContext?.getSharedPreferences(NETWORK_INJECTION_STATE_PREFS, Context.MODE_PRIVATE)?.edit()?.remove("settings")?.apply()
    }
}
