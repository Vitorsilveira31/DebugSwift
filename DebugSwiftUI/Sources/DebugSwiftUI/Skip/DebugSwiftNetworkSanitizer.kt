package debug.swift.android

import org.json.JSONArray
import org.json.JSONObject
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

/**
 * Masks credentials and personal data in captured traffic, with the same rules as the Swift
 * `NetworkSanitizer` in DebugSwiftCore. Names match case-insensitively and ignoring `_` and `-`.
 *
 * [AndroidDebugTools.recordNetwork] runs every record through it before the record is listed,
 * saved to the history file, exported as HAR or cURL, or written to the agent log.
 */
object DebugSwiftNetworkSanitizer {
    const val REDACTED = "<redacted>"
    private const val ENCODED_REDACTED = "%3Credacted%3E"

    val defaultHeaders = setOf(
        "Authorization", "Cookie", "Set-Cookie", "Proxy-Authorization", "X-API-Key", "X-Auth-Token",
        "X-Access-Token", "X-CSRF-Token"
    )
    val defaultQueryParameters = setOf(
        "access_token", "refresh_token", "id_token", "token", "api_key", "apikey", "password", "secret",
        "client_secret", "signature", "sig", "X-Amz-Signature", "X-Amz-Credential", "X-Amz-Security-Token"
    )
    val defaultBodyKeys = setOf(
        "password", "passwd", "new_password", "old_password", "access_token", "refresh_token", "id_token",
        "token", "client_secret", "secret", "api_key", "apikey", "card_number", "cvv", "cvc", "ssn"
    )

    @Volatile private var headers = normalize(defaultHeaders)
    @Volatile private var queryParameters = normalize(defaultQueryParameters)
    @Volatile private var bodyKeys = normalize(defaultBodyKeys)
    @Volatile private var redactsURLPassword = true

    /** Replaces the rules. Any list left out keeps its current value. */
    @JvmStatic
    fun configure(
        headers: Collection<String>? = null,
        queryParameters: Collection<String>? = null,
        bodyKeys: Collection<String>? = null,
        redactsURLPassword: Boolean? = null
    ) {
        headers?.let { this.headers = normalize(it) }
        queryParameters?.let { this.queryParameters = normalize(it) }
        bodyKeys?.let { this.bodyKeys = normalize(it) }
        redactsURLPassword?.let { this.redactsURLPassword = it }
    }

    /** Same as [configure], from `{"headers":[...],"queryParameters":[...],"bodyKeys":[...],"redactsURLPassword":true}`. */
    @JvmStatic
    fun configureJSON(json: String) {
        val config = runCatching { JSONObject(json) }.getOrNull() ?: return
        fun list(key: String): List<String>? = config.optJSONArray(key)?.let { array ->
            (0 until array.length()).map { array.optString(it) }
        }
        configure(
            headers = list("headers"),
            queryParameters = list("queryParameters"),
            bodyKeys = list("bodyKeys"),
            redactsURLPassword = if (config.has("redactsURLPassword")) config.optBoolean("redactsURLPassword") else null
        )
    }

    fun sanitizeHeaders(values: Map<String, List<String>>): Map<String, List<String>> {
        val keys = headers
        if (keys.isEmpty()) return values
        return values.mapValues { (name, list) -> if (normalize(name) in keys) listOf(REDACTED) else list }
    }

    fun sanitizeUrl(url: String): String {
        val keys = queryParameters
        var result = url
        if (redactsURLPassword) {
            result = USER_INFO.replace(result) { match -> "${match.groupValues[1]}${match.groupValues[2]}:$ENCODED_REDACTED@" }
        }
        if (keys.isEmpty()) return result
        val hashIndex = result.indexOf('#')
        val beforeFragment = if (hashIndex >= 0) result.substring(0, hashIndex) else result
        var fragment = if (hashIndex >= 0) result.substring(hashIndex + 1) else null
        val queryIndex = beforeFragment.indexOf('?')
        val base = if (queryIndex >= 0) beforeFragment.substring(0, queryIndex) else beforeFragment
        val query = if (queryIndex >= 0) sanitizeForm(beforeFragment.substring(queryIndex + 1), keys) else null
        if (fragment != null && fragment.contains('=')) fragment = sanitizeForm(fragment, keys)
        return buildString {
            append(base)
            if (query != null) append('?').append(query)
            if (fragment != null) append('#').append(fragment)
        }
    }

    fun sanitizeBody(body: String, contentType: String?): String {
        val keys = bodyKeys
        if (keys.isEmpty() || body.isEmpty()) return body
        val type = contentType?.lowercase().orEmpty()
        return when {
            type.contains("x-www-form-urlencoded") -> sanitizeForm(body, keys)
            type.isEmpty() || type.contains("json") -> sanitizeJson(body, keys) ?: body
            else -> body
        }
    }

    /**
     * Masks text whose format is unknown, such as a decrypted body: as JSON when it parses, and
     * otherwise every `key=value` or `key: value` pair whose key is a masked one.
     */
    fun sanitizeText(body: String): String {
        val keys = bodyKeys
        if (keys.isEmpty() || body.isEmpty()) return body
        sanitizeJson(body, keys)?.let { return it }
        return KEY_VALUE.replace(body) { match ->
            if (normalize(match.groupValues[2]) in keys) {
                match.groupValues[1] + match.groupValues[2] + match.groupValues[3] + REDACTED
            } else {
                match.value
            }
        }
    }

    // Quoted values may hold escaped quotes (`"a\"b"`), so the whole quoted value is masked.
    private val KEY_VALUE = Regex("""(^|[\s&;,{"'])([A-Za-z0-9_.-]+)(["']?\s*[:=]\s*)("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s&;,}]+)""")

    private val USER_INFO = Regex("^([a-zA-Z][a-zA-Z0-9+.-]*://)([^/?#@:]*):([^/?#@]*)@")

    private fun normalize(name: String): String = name.lowercase().filter { it != '_' && it != '-' }

    private fun normalize(names: Collection<String>): Set<String> = names.map(::normalize).toSet()

    private fun sanitizeForm(text: String, keys: Set<String>): String =
        text.split('&').joinToString("&") { pair ->
            val separator = pair.indexOf('=')
            if (separator < 0) return@joinToString pair
            val rawName = pair.substring(0, separator)
            val name = runCatching { URLDecoder.decode(rawName, StandardCharsets.UTF_8.name()) }.getOrDefault(rawName)
            if (normalize(name) in keys) "$rawName=$ENCODED_REDACTED" else pair
        }

    private fun sanitizeJson(body: String, keys: Set<String>): String? {
        val trimmed = body.trimStart()
        val parsed: Any = runCatching {
            when {
                trimmed.startsWith("{") -> JSONObject(body)
                trimmed.startsWith("[") -> JSONArray(body)
                else -> null
            }
        }.getOrNull() ?: return null
        return if (redact(parsed, keys)) parsed.toString() else null
    }

    /** Masks matching keys in place; true when anything changed. */
    private fun redact(value: Any?, keys: Set<String>): Boolean {
        var changed = false
        when (value) {
            is JSONObject -> value.keys().asSequence().toList().forEach { key ->
                if (normalize(key) in keys) {
                    value.put(key, REDACTED)
                    changed = true
                } else if (redact(value.opt(key), keys)) {
                    changed = true
                }
            }
            is JSONArray -> for (index in 0 until value.length()) {
                if (redact(value.opt(index), keys)) changed = true
            }
        }
        return changed
    }
}
