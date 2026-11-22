package debug.swift.android

import android.os.SystemClock
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.io.IOException
import java.io.InterruptedIOException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLHandshakeException

/** Add this interceptor to the host app's OkHttpClient.Builder to capture HTTP traffic. */
class DebugSwiftOkHttpInterceptor : Interceptor {
    private companion object {
        /** The largest body kept for inspection; it is masked whole before being trimmed. */
        const val INSPECTED_BODY_LIMIT = 1_000_000L

        fun tooLargeToKeep(size: Long?): String =
            "[DebugSwift: body${size?.let { " of $it bytes" } ?: ""} not kept: larger than $INSPECTED_BODY_LIMIT bytes, too large to mask]"
    }

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val url = request.url.toString()
        // A URL the host's ignoredURLs/onlyURLs leave out goes through untouched: not counted,
        // blocked, injected or recorded, as on iOS.
        if (!AndroidDebugTools.networkAccepts(url)) return chain.proceed(request)
        val start = SystemClock.elapsedRealtime()
        // Whole bodies only: a cut JSON body no longer parses and so could not be masked. One too
        // large to read whole is not kept; recordNetwork masks, then trims for display.
        val requestBody = runCatching {
            val buffer = Buffer()
            request.body?.writeTo(buffer)
            // The declared charset: the body's media type, then the request's Content-Type header.
            val declared = request.body?.contentType()?.charset()
                ?: request.header("Content-Type")?.toMediaTypeOrNull()?.charset()
            if (buffer.size > INSPECTED_BODY_LIMIT) tooLargeToKeep(buffer.size)
            else decodeBody(buffer.readByteArray(), declared)
        }.getOrDefault("")
        val requestBytes = request.body?.contentLength()?.takeIf { it >= 0 } ?: 0L

        val delay = AndroidDebugTools.requestDelay(url, request.method)
        if (delay > 0) Thread.sleep(delay)

        if (AndroidDebugTools.shouldBlock(url)) {
            val responseBody = "Blocked by DebugSwift network rules."
            val response = syntheticResponse(chain, 403, responseBody)
            record(request, 403, start, requestBytes, responseBody, requestBody, "Request blocked by an active network rule")
            return response
        }
        val injectedFailure = AndroidDebugTools.consumeNetworkFailure(url, request.method)
        if (injectedFailure?.failureType == "httpError") {
            val injectedStatus = injectedFailure.statusCode ?: 500
            val body = """{"error":"Injected HTTP Error","statusCode":$injectedStatus,"message":"This is a simulated HTTP $injectedStatus error for testing purposes.","injected":true}"""
            val response = syntheticResponse(chain, injectedStatus, body)
            record(request, injectedStatus, start, requestBytes, body, requestBody)
            return response
        }
        if (injectedFailure != null) {
            val failure = networkIOException(injectedFailure)
            AndroidDebugTools.recordNetwork(request.method, url, 0, SystemClock.elapsedRealtime() - start, requestBytes, 0, requestBody, "", failure.message ?: "network error", recordedRequestHeaders(request))
            throw failure
        }

        val rewriteRule = AndroidDebugTools.matchingNetworkRewriteRule(url, request.method)
        if (rewriteRule != null && AndroidDebugTools.shouldShortCircuitResponseRewrite()) {
            val status = rewriteRule.responseStatusCode ?: 200
            val body = rewriteRule.responseBody
            val response = syntheticResponse(chain, status, body)
            record(request, status, start, requestBytes, body, requestBody)
            return response
        }

        val response = try {
            chain.proceed(request)
        } catch (error: IOException) {
            AndroidDebugTools.recordNetwork(request.method, url, 0, SystemClock.elapsedRealtime() - start, requestBytes, 0, requestBody, "", error.message ?: "network error", recordedRequestHeaders(request))
            throw error
        }
        // The response's own size, kept apart from the text recorded for it: a body too large to keep
        // is recorded as a notice, but its size is the response's (Content-Length when known,
        // otherwise at least the limit, which the notice states).
        var originalBytes = 0L
        val originalText = runCatching {
            val peeked = response.peekBody(INSPECTED_BODY_LIMIT + 1)
            val size = peeked.contentLength()
            if (size > INSPECTED_BODY_LIMIT) {
                originalBytes = response.body?.contentLength()?.takeIf { it >= 0 } ?: (INSPECTED_BODY_LIMIT + 1)
                tooLargeToKeep(null)
            } else {
                originalBytes = size
                // Decoded as requests are, so a BOM-prefixed or BOM-less UTF-16 body is text the
                // masker can read downstream.
                decodeBody(peeked.bytes(), peeked.contentType()?.charset())
            }
        }.getOrDefault("")
        val rewrittenText = rewriteRule?.responseBody ?: originalText
        val finalResponse = if (rewriteRule != null) {
            val builder = response.newBuilder()
                .header("Content-Length", rewrittenText.toByteArray().size.toString())
                .body(rewrittenText.toResponseBody(response.body?.contentType() ?: "application/json".toMediaTypeOrNull()))
            rewriteRule.responseStatusCode?.let { status -> builder.code(status).message("Rewritten by DebugSwift") }
            builder.build()
        } else response
        AndroidDebugTools.recordNetwork(
            request.method,
            url,
            finalResponse.code,
            SystemClock.elapsedRealtime() - start,
            requestBytes,
            if (rewriteRule != null) rewrittenText.toByteArray().size.toLong() else originalBytes,
            requestBody,
            rewrittenText,
            requestHeaders = recordedRequestHeaders(request),
            responseHeaders = finalResponse.headers.toMultimap()
        )
        return finalResponse
    }

    private fun record(request: okhttp3.Request, status: Int, start: Long, requestBytes: Long, body: String, requestBody: String, error: String = "") {
        AndroidDebugTools.recordNetwork(
            request.method,
            request.url.toString(),
            status,
            SystemClock.elapsedRealtime() - start,
            requestBytes,
            body.toByteArray().size.toLong(),
            requestBody,
            body,
            error,
            requestHeaders = recordedRequestHeaders(request)
        )
    }

    private fun syntheticResponse(chain: Interceptor.Chain, code: Int, body: String): Response = Response.Builder()
        .request(chain.request())
        .protocol(Protocol.HTTP_1_1)
        .code(code)
        .message("Injected by DebugSwift")
        .header("Content-Type", "application/json")
        .body(body.toResponseBody("application/json".toMediaTypeOrNull()))
        .build()

    private fun networkIOException(failure: AndroidDebugTools.NetworkFailure): IOException = when (failure.failureType) {
        "timeout" -> SocketTimeoutException("The request timed out.")
        "connectionLost" -> SocketException("The network connection was lost.")
        "notConnectedToInternet" -> UnknownHostException("The Internet connection appears to be offline.")
        "cannotFindHost" -> UnknownHostException("A server with the specified hostname could not be found.")
        "dnsLookupFailed" -> UnknownHostException("The DNS lookup failed.")
        "sslError" -> SSLHandshakeException("A secure connection could not be established.")
        "cancelled" -> InterruptedIOException("The request was cancelled.")
        "custom" -> IOException("${failure.customDomain} (${failure.customCode}): ${failure.customDescription}")
        else -> IOException("Failure injected by DebugSwift.")
    }

    /**
     * A captured body as text, read as DebugSwiftCore reads raw bodies: a byte order mark first
     * (dropped), then the declared charset, then the signature of BOM-less UTF-32 or UTF-16 XML
     * (`<` with NULs, XML 1.0 appendix F), else UTF-8.
     */
    private fun decodeBody(bytes: ByteArray, declared: java.nio.charset.Charset?): String {
        fun starts(vararg prefix: Int) = bytes.size >= prefix.size && prefix.indices.all { bytes[it] == prefix[it].toByte() }
        val utf32LE = java.nio.charset.Charset.forName("UTF-32LE")
        val utf32BE = java.nio.charset.Charset.forName("UTF-32BE")
        val (charset, skip) = when {
            starts(0xFF, 0xFE, 0x00, 0x00) -> utf32LE to 4
            starts(0x00, 0x00, 0xFE, 0xFF) -> utf32BE to 4
            starts(0xEF, 0xBB, 0xBF) -> Charsets.UTF_8 to 3
            starts(0xFE, 0xFF) -> Charsets.UTF_16BE to 2
            starts(0xFF, 0xFE) -> Charsets.UTF_16LE to 2
            declared != null -> declared to 0
            starts(0x3C, 0x00, 0x00, 0x00) -> utf32LE to 0
            starts(0x00, 0x00, 0x00, 0x3C) -> utf32BE to 0
            starts(0x3C, 0x00) -> Charsets.UTF_16LE to 0
            starts(0x00, 0x3C) -> Charsets.UTF_16BE to 0
            else -> Charsets.UTF_8 to 0
        }
        return String(bytes, skip, bytes.size - skip, charset)
    }

    /**
     * The request's headers as recorded. OkHttp adds `Content-Type` from the body only after
     * application interceptors, so it is added here when missing: the masker picks the body's
     * format from it.
     */
    private fun recordedRequestHeaders(request: okhttp3.Request): Map<String, List<String>> {
        val headers = request.headers.toMultimap()
        val type = request.body?.contentType() ?: return headers
        if (headers.keys.any { it.equals("Content-Type", ignoreCase = true) }) return headers
        return headers + ("Content-Type" to listOf(type.toString()))
    }
}
