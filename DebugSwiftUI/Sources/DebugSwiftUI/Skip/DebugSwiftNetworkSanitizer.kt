package debug.swift.android

import org.json.JSONArray
import org.json.JSONObject

/**
 * Masks credentials and personal data in captured traffic with DebugSwiftCore's `NetworkSanitizer`,
 * the one iOS uses, through [DebugSwiftCoreBridge]. Names match case-insensitively and ignoring `_` and `-`.
 *
 * [AndroidDebugTools.recordNetwork] runs every record through it before the record is listed,
 * saved to the history file, exported as HAR or cURL, or written to the agent log.
 */
object DebugSwiftNetworkSanitizer {
    const val REDACTED = "<redacted>"

    private val defaults by lazy { JSONObject(DebugSwiftCoreBridge.call("sanitizer.defaults", "{}")) }
    private fun defaultList(key: String): Set<String> =
        defaults.optJSONArray(key)?.let { array -> (0 until array.length()).map(array::optString).toSet() }.orEmpty()

    /** DebugSwiftCore's default rules, the ones in force until [configure] changes them. */
    val defaultHeaders: Set<String> get() = defaultList("headers")
    val defaultQueryParameters: Set<String> get() = defaultList("queryParameters")
    val defaultBodyKeys: Set<String> get() = defaultList("bodyKeys")

    /** Replaces the rules. Any list left out keeps its current value. */
    @JvmStatic
    fun configure(
        headers: Collection<String>? = null,
        queryParameters: Collection<String>? = null,
        bodyKeys: Collection<String>? = null,
        redactsURLPassword: Boolean? = null
    ) {
        val config = JSONObject()
        headers?.let { config.put("headers", JSONArray(it.toList())) }
        queryParameters?.let { config.put("queryParameters", JSONArray(it.toList())) }
        bodyKeys?.let { config.put("bodyKeys", JSONArray(it.toList())) }
        redactsURLPassword?.let { config.put("redactsURLPassword", it) }
        DebugSwiftCoreBridge.call("sanitizer.configure", config.toString())
    }

    /** The parts of a captured request, masked. */
    data class Masked(
        val url: String,
        val requestHeaders: Map<String, List<String>>,
        val responseHeaders: Map<String, List<String>>,
        val requestBody: String,
        val responseBody: String,
        val decryptedResponseBody: String
    )

    /** Masks a request in one call: each body by its own Content-Type, a decrypted body as JSON or key/value text. */
    fun sanitize(
        url: String,
        requestHeaders: Map<String, List<String>>,
        responseHeaders: Map<String, List<String>>,
        requestBody: String,
        responseBody: String,
        decryptedResponseBody: String
    ): Masked {
        val input = JSONObject()
            .put("url", url)
            .put("requestHeaders", headersJSON(requestHeaders))
            .put("responseHeaders", headersJSON(responseHeaders))
            .put("requestBody", requestBody)
            .put("responseBody", responseBody)
            .put("decryptedResponseBody", decryptedResponseBody)
        val reply = JSONObject(DebugSwiftCoreBridge.call("sanitize.record", input.toString()))
        return Masked(
            url = reply.optString("url", url),
            requestHeaders = headersFrom(reply.optJSONObject("requestHeaders")) ?: requestHeaders,
            responseHeaders = headersFrom(reply.optJSONObject("responseHeaders")) ?: responseHeaders,
            requestBody = reply.optString("requestBody", requestBody),
            responseBody = reply.optString("responseBody", responseBody),
            decryptedResponseBody = reply.optString("decryptedResponseBody", decryptedResponseBody)
        )
    }

    private fun headersJSON(headers: Map<String, List<String>>): JSONObject =
        JSONObject().also { json -> headers.forEach { (name, values) -> json.put(name, JSONArray(values)) } }

    private fun headersFrom(json: JSONObject?): Map<String, List<String>>? = json?.let {
        it.keys().asSequence().associateWith { name ->
            val values = it.optJSONArray(name) ?: return@associateWith emptyList<String>()
            (0 until values.length()).map(values::optString)
        }
    }
}
