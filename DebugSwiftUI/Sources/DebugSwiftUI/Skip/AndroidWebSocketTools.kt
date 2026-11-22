package debug.swift.android

import android.content.Context
import android.content.ClipData
import android.util.Log
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.util.Date
import java.util.Locale
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import okhttp3.WebSocket
import debug.swift.android.AndroidDebugTools.WebSocketConnectionRecord
import debug.swift.android.AndroidDebugTools.WebSocketFrameRecord

// WebSocket capture and the WebSocket inspector.
// Part of AndroidDebugTools: these extensions use the object's state, which lives in AndroidDebugTools.kt.

fun AndroidDebugTools.webSocketOpened(webSocket: WebSocket, url: String, responseCode: Int) {
    if (!webSocketMonitoringEnabled || webSocket in clearedWebSockets) return
    val connection = findOrCreateWebSocketConnection(webSocket, url)
    connection.status = "Connected"
    connection.statusDetail = "HTTP $responseCode"
    connection.lastActivityAtMs = System.currentTimeMillis()
    recordWebSocketEvent(connection, "connected", connection.statusDetail)
}

fun AndroidDebugTools.recordWebSocketFrame(
    webSocket: WebSocket,
    url: String,
    direction: String,
    type: String,
    payload: ByteArray
) {
    if (!webSocketMonitoringEnabled || webSocket in clearedWebSockets) return
    val connection = findOrCreateWebSocketConnection(webSocket, url)
    if (connection.status == "Connecting") connection.status = "Connected"
    recordWebSocketFrame(connection, direction, type, payload)
}

fun AndroidDebugTools.webSocketClosing(webSocket: WebSocket, url: String, code: Int, reason: String) {
    val connection = webSocketConnectionForUpdate(webSocket, url) ?: return
    connection.status = "Closing"
    connection.statusDetail = listOf(code.toString(), reason).filter { it.isNotBlank() }.joinToString(" · ")
    connection.lastActivityAtMs = System.currentTimeMillis()
    if (webSocketMonitoringEnabled) recordWebSocketEvent(connection, "closing", connection.statusDetail)
}

fun AndroidDebugTools.webSocketClosed(webSocket: WebSocket, url: String, code: Int, reason: String) {
    // Look the row up first: a socket whose row was cleared must not bring it back. It is over
    // either way, so it is forgotten after.
    val connection = webSocketConnectionForUpdate(webSocket, url)
    clearedWebSockets.remove(webSocket)
    if (connection == null) return
    connection.status = "Closed"
    connection.statusDetail = listOf(code.toString(), reason).filter { it.isNotBlank() }.joinToString(" · ")
    connection.lastActivityAtMs = System.currentTimeMillis()
    activeWebSockets.remove(connection.id, webSocket)
    webSocketByInstance.remove(webSocket, connection.id)
    if (webSocketMonitoringEnabled) recordWebSocketEvent(connection, "closed", connection.statusDetail)
}

fun AndroidDebugTools.webSocketFailed(webSocket: WebSocket, url: String, error: String, responseCode: Int?) {
    // Look the row up first: a socket whose row was cleared must not bring it back. It is over
    // either way, so it is forgotten after.
    val connection = webSocketConnectionForUpdate(webSocket, url)
    clearedWebSockets.remove(webSocket)
    if (connection == null) return
    connection.status = "Error"
    connection.statusDetail = listOfNotNull(responseCode?.let { "HTTP $it" }, error).joinToString(" · ")
    connection.lastActivityAtMs = System.currentTimeMillis()
    activeWebSockets.remove(connection.id, webSocket)
    webSocketByInstance.remove(webSocket, connection.id)
    if (webSocketMonitoringEnabled) recordWebSocketEvent(connection, "failed", connection.statusDetail)
}

/** Backward-compatible text hook for hosts that record frames without the listener wrapper. */
fun AndroidDebugTools.recordWebSocket(url: String, direction: String, payload: String) {
    val normalizedDirection = direction.lowercase(Locale.ROOT)
    if (!webSocketMonitoringEnabled) {
        // Capture is off: only let a socket tracked before that close, never add a new one.
        val terminal = normalizedDirection in setOf("closed", "failed", "error")
        if (!terminal || legacyWebSocketIDs[url] == null) return
    }
    val connection = findOrCreateLegacyWebSocketConnection(url)
    when (normalizedDirection) {
        "connected" -> {
            connection.status = "Connected"
            connection.statusDetail = payload
            recordWebSocketEvent(connection, direction, payload)
        }
        "closing" -> {
            connection.status = "Closing"
            connection.statusDetail = payload
            recordWebSocketEvent(connection, direction, payload)
        }
        "closed" -> {
            connection.status = "Closed"
            connection.statusDetail = payload
            // With capture off a tracked socket still closes, but no event is recorded.
            if (webSocketMonitoringEnabled) recordWebSocketEvent(connection, direction, payload)
        }
        "failed", "error" -> {
            connection.status = "Error"
            connection.statusDetail = payload
            if (webSocketMonitoringEnabled) recordWebSocketEvent(connection, direction, payload)
        }
        else -> {
            if (!connection.isActive()) {
                connection.status = "Connected"
                connection.statusDetail = ""
            }
            recordWebSocketFrame(
                connection,
                if (normalizedDirection.startsWith("sent")) "Sent" else "Received",
                if (normalizedDirection.contains("binary")) "Binary" else "Text",
                payload.toByteArray(StandardCharsets.UTF_8)
            )
        }
    }
}

internal fun AndroidDebugTools.findOrCreateWebSocketConnection(webSocket: WebSocket, url: String): WebSocketConnectionRecord =
    synchronized(webSocketConnections) {
        val previousID = webSocketByInstance[webSocket]
        if (previousID != null) {
            webSocketConnections.firstOrNull { it.id == previousID }?.let { return@synchronized it }
            activeWebSockets.remove(previousID)
        }

        val connection = WebSocketConnectionRecord(UUID.randomUUID().toString(), url)
        webSocketConnections.add(connection)
        webSocketByInstance[webSocket] = connection.id
        activeWebSockets[connection.id] = webSocket
        while (webSocketConnections.size > MAX_WEBSOCKET_CONNECTIONS) {
            val removed = webSocketConnections.removeAt(0)
            activeWebSockets.remove(removed.id)
            legacyWebSocketIDs.forEach { (legacyURL, id) ->
                if (id == removed.id) legacyWebSocketIDs.remove(legacyURL, id)
            }
            webSocketByInstance.forEach { (socket, id) ->
                if (id == removed.id) webSocketByInstance.remove(socket, id)
            }
        }
        connection
    }

internal fun AndroidDebugTools.findOrCreateLegacyWebSocketConnection(url: String): WebSocketConnectionRecord =
    synchronized(webSocketConnections) {
        legacyWebSocketIDs[url]?.let { id ->
            webSocketConnections.firstOrNull { it.id == id }?.let { return@synchronized it }
        }
        val connection = WebSocketConnectionRecord("legacy:${UUID.randomUUID()}", url).apply {
            status = "Connected"
        }
        webSocketConnections.add(connection)
        legacyWebSocketIDs[url] = connection.id
        while (webSocketConnections.size > MAX_WEBSOCKET_CONNECTIONS) {
            val removed = webSocketConnections.removeAt(0)
            activeWebSockets.remove(removed.id)
            legacyWebSocketIDs.forEach { (legacyURL, id) ->
                if (id == removed.id) legacyWebSocketIDs.remove(legacyURL, id)
            }
            webSocketByInstance.forEach { (socket, id) ->
                if (id == removed.id) webSocketByInstance.remove(socket, id)
            }
        }
        connection
    }

internal fun AndroidDebugTools.recordWebSocketFrame(
    connection: WebSocketConnectionRecord,
    direction: String,
    type: String,
    payload: ByteArray
) {
    val frame = WebSocketFrameRecord(
        id = UUID.randomUUID().toString(),
        timestampMs = System.currentTimeMillis(),
        direction = direction,
        type = type,
        payload = payload.copyOf()
    )
    connection.frames.add(frame)
    while (connection.frames.size > MAX_WEBSOCKET_FRAMES) connection.frames.removeAt(0)
    connection.lastActivityAtMs = frame.timestampMs
    connection.unreadFrameCount.incrementAndGet()
    val preview = decodeWebSocketPayload(frame.payload)?.replace('\n', ' ')?.take(500)
        ?: "<Binary Data: ${frame.payload.size} bytes>"
    recordWebSocketEvent(connection, "${direction.lowercase(Locale.ROOT)} $type", preview)
}

internal fun AndroidDebugTools.recordWebSocketEvent(connection: WebSocketConnectionRecord, action: String, payload: String) {
    val line = "${timestamp()} WebSocket $action ${connection.url}: ${payload.take(500)}"
    webSocketRecords.add(line)
    trim(webSocketRecords)
    publishEvent("network", line)
    log("WebSocket $action ${connection.url}: ${payload.take(500)}", Log.VERBOSE)
}

internal fun AndroidDebugTools.decodeWebSocketPayload(payload: ByteArray): String? = runCatching {
    StandardCharsets.UTF_8.newDecoder()
        .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
        .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(payload))
        .toString()
}.getOrNull()

/** Structured connection and frame data for the shared SwiftUI WebSocket inspector. */
fun AndroidDebugTools.webSocketInspectorSnapshotJSON(connectionID: String, query: String, direction: String): String {
    val connections = webSocketConnections.sortedByDescending { it.lastActivityAtMs }
    val connectionRows = JSONArray()
    connections.forEach { connection ->
        val sentCount = connection.frames.count { it.direction.equals("Sent", ignoreCase = true) }
        connectionRows.put(JSONObject()
            .put("id", connection.id)
            .put("url", connection.url)
            .put("name", connection.url)
            .put("status", connection.status)
            .put("statusDetail", connection.statusDetail)
            .put("createdAtMilliseconds", connection.createdAtMs)
            .put("lastActivityAtMilliseconds", connection.lastActivityAtMs)
            .put("frameCount", connection.frames.size)
            .put("sentCount", sentCount)
            .put("receivedCount", connection.frames.size - sentCount)
            .put("unreadFrameCount", connection.unreadFrameCount.get()))
    }

    val frameRows = JSONArray()
    val selectedConnection = connections.firstOrNull { it.id == connectionID }
    selectedConnection?.frames?.sortedByDescending { it.timestampMs }?.forEach { frame ->
        val payloadText = decodeWebSocketPayload(frame.payload).orEmpty()
        val normalizedQuery = query.trim()
        if (direction.isNotBlank() && !frame.direction.equals(direction, ignoreCase = true)) return@forEach
        if (normalizedQuery.isNotEmpty() && !payloadText.contains(normalizedQuery, ignoreCase = true)) return@forEach

        val hexLimit = minOf(frame.payload.size, 4_096)
        val hex = frame.payload.take(hexLimit).joinToString(" ") { "%02X".format(it.toInt() and 0xFF) }
        frameRows.put(JSONObject()
            .put("id", frame.id)
            .put("connectionID", selectedConnection.id)
            .put("timestampMilliseconds", frame.timestampMs)
            .put("direction", frame.direction)
            .put("type", frame.type)
            .put("size", frame.payload.size)
            .put("payload", payloadText)
            .put("prettyPayload", payloadText.takeIf { it.isNotEmpty() }?.let(::prettyWebSocketPayload).orEmpty())
            .put("payloadBase64", android.util.Base64.encodeToString(frame.payload, android.util.Base64.NO_WRAP))
            .put("hexDump", hex)
            .put("hexTruncated", frame.payload.size > hexLimit))
    }
    return JSONObject()
        .put("connections", connectionRows)
        .put("frames", frameRows)
        .toString()
}

/** Native WebSocket operations used by the shared SwiftUI inspector. */
fun AndroidDebugTools.performWebSocketInspectorAction(
    actionID: String,
    connectionID: String,
    frameID: String,
    value: String
): String {
    val context = appContext ?: return "Android runtime has not been installed."
    if (actionID == "clear_all") return clearWebSocketHistory()
    val connection = webSocketConnections.firstOrNull { it.id == connectionID }
        ?: return "This WebSocket connection is no longer available."
    selectedWebSocketConnectionID = connectionID
    selectedWebSocketFrameID = frameID
    return when (actionID) {
        "select_connection" -> {
            connection.unreadFrameCount.set(0)
            "Connection opened."
        }
        "close_connection" -> closeSelectedWebSocketConnection()
        "clear_frames" -> clearSelectedWebSocketFrames()
        "copy_url" -> copyWebSocketURL(context)
        "copy_payload" -> copyWebSocketPayload(context)
        "send_frame" -> sendWebSocketFrame(value, resendSelected = false)
        "resend_frame" -> sendWebSocketFrame(value, resendSelected = true)
        "export" -> shareExport(exportWebSockets(context), context)
        else -> "Unknown WebSocket action: $actionID."
    }
}

internal fun AndroidDebugTools.filteredWebSocketConnections(): List<WebSocketConnectionRecord> {
    val query = webSocketFilter.trim()
    return webSocketConnections.sortedByDescending { it.lastActivityAtMs }.filter { connection ->
        query.isEmpty() || connection.url.contains(query, ignoreCase = true) ||
            connection.status.contains(query, ignoreCase = true) ||
            connection.frames.any { frame ->
                decodeWebSocketPayload(frame.payload)?.contains(query, ignoreCase = true) == true
            }
    }
}

internal fun AndroidDebugTools.filteredWebSocketFrames(connection: WebSocketConnectionRecord): List<WebSocketFrameRecord> {
    val query = webSocketFilter.trim()
    return connection.frames.sortedByDescending { it.timestampMs }.filter { frame ->
        (webSocketDirectionFilter.isEmpty() || frame.direction.equals(webSocketDirectionFilter, ignoreCase = true)) &&
            (query.isEmpty() || decodeWebSocketPayload(frame.payload)?.contains(query, ignoreCase = true) == true)
    }
}

internal fun AndroidDebugTools.webSocketSnapshot(): String {
    val connection = webSocketConnections.firstOrNull { it.id == selectedWebSocketConnectionID }
    if (connection == null) {
        selectedWebSocketConnectionID = ""
        selectedWebSocketFrameID = ""
    } else {
        val selectedFrame = connection.frames.firstOrNull { it.id == selectedWebSocketFrameID }
        if (selectedFrame != null) return webSocketFrameSnapshot(connection, selectedFrame)
        selectedWebSocketFrameID = ""

        val frames = filteredWebSocketFrames(connection)
        val directionLabel = webSocketDirectionFilter.takeIf { it.isNotEmpty() }?.let { " · $it only" }.orEmpty()
        return buildString {
            appendLine(connection.url)
            appendLine("Status: ${connection.status}${connection.statusDetail.takeIf { it.isNotBlank() }?.let { " · $it" }.orEmpty()}")
            appendLine("Started: ${Date(connection.createdAtMs)}")
            appendLine("Last activity: ${Date(connection.lastActivityAtMs)}")
            appendLine("Frames: ${connection.frames.size} · Unread: ${connection.unreadFrameCount.get()}$directionLabel")
            if (webSocketFilter.isNotBlank()) appendLine("Filter: $webSocketFilter")
            appendLine("\nFrames (newest first):")
            append(frames.mapIndexed { index, frame -> webSocketFrameRow(index + 1, frame) }
                .joinToString("\n\n").ifEmpty { "No matching frames. Use Send Frame to send text or base64:<data>." })
        }
    }

    val matching = filteredWebSocketConnections()
    val activeCount = webSocketConnections.count { it.isActive() }
    return buildString {
        appendLine("Connections: ${matching.size} · Active: $activeCount")
        if (webSocketFilter.isNotBlank()) appendLine("Filter: $webSocketFilter · ${matching.size} matches")
        append(matching.mapIndexed { index, item ->
            val sent = item.frames.count { it.direction.equals("Sent", ignoreCase = true) }
            val received = item.frames.size - sent
            "#${index + 1} ${item.url}\n  ${item.status} · Sent $sent · Received $received · Unread ${item.unreadFrameCount.get()}" +
                item.statusDetail.takeIf { it.isNotBlank() }?.let { "\n  $it" }.orEmpty()
        }.joinToString("\n\n").ifEmpty { "No WebSocket connections recorded. Install DebugSwiftWebSocketListener on the host OkHttp WebSocket listener." })
    }
}

internal fun AndroidDebugTools.webSocketFrameRow(index: Int, frame: WebSocketFrameRecord): String {
    val preview = decodeWebSocketPayload(frame.payload)?.replace('\n', ' ')?.take(180)
        ?: "<Binary Data: ${frame.payload.size} bytes>"
    return "#$index ${frame.direction} · ${frame.type} · ${formatBytes(frame.payload.size.toLong())} · ${timestampAt(frame.timestampMs)}\n$preview"
}

internal fun AndroidDebugTools.webSocketFrameSnapshot(connection: WebSocketConnectionRecord, frame: WebSocketFrameRecord): String {
    return webSocketFrameSnapshot(connection, frame, forExport = false)
}

internal fun AndroidDebugTools.webSocketFrameSnapshot(
    connection: WebSocketConnectionRecord,
    frame: WebSocketFrameRecord,
    forExport: Boolean
): String {
    val decoded = decodeWebSocketPayload(frame.payload)
    val rawPayload = if (forExport || decoded == null) decoded else decoded.take(64_000)
    val pretty = rawPayload?.let(::prettyWebSocketPayload)
    val hexLimit = if (forExport) frame.payload.size else minOf(frame.payload.size, 4096)
    val hex = frame.payload.take(hexLimit).joinToString(" ") { "%02X".format(it.toInt() and 0xFF) }
    return buildString {
        appendLine(connection.url)
        appendLine("Direction: ${frame.direction}")
        appendLine("Timestamp: ${Date(frame.timestampMs)}")
        appendLine("Type: ${frame.type}")
        appendLine("Size: ${formatBytes(frame.payload.size.toLong())}")
        appendLine("\nPretty / decoded payload")
        appendLine(pretty ?: if (decoded == null) "<Binary data>" else "<Payload too large to format>")
        if (!forExport && decoded != null && decoded.length > 64_000) appendLine("… payload preview truncated …")
        appendLine("\nRaw payload")
        appendLine(rawPayload ?: "<Binary data>")
        if (!forExport && decoded != null && decoded.length > 64_000) appendLine("… payload preview truncated …")
        appendLine("\nHex")
        append(hex.ifBlank { "(empty)" })
        if (!forExport && frame.payload.size > hexLimit) appendLine("\n… showing $hexLimit of ${frame.payload.size} bytes …")
    }
}

internal fun AndroidDebugTools.prettyWebSocketPayload(payload: String): String = runCatching {
    when {
        payload.trim().startsWith("{") -> JSONObject(payload).toString(2)
        payload.trim().startsWith("[") -> JSONArray(payload).toString(2)
        else -> payload
    }
}.getOrDefault(payload)

internal fun AndroidDebugTools.selectWebSocketConnection(value: String): String {
    val index = value.trim().removePrefix("#").toIntOrNull()
        ?: return "Enter a connection number from the current list."
    val connection = filteredWebSocketConnections().getOrNull(index - 1)
        ?: return "No WebSocket connection at position $index. Refresh the list; the newest activity is #1."
    selectedWebSocketConnectionID = connection.id
    selectedWebSocketFrameID = ""
    webSocketDirectionFilter = ""
    connection.unreadFrameCount.set(0)
    return webSocketSnapshot()
}

internal fun AndroidDebugTools.selectWebSocketFrame(value: String): String {
    val connection = webSocketConnections.firstOrNull { it.id == selectedWebSocketConnectionID }
        ?: return "Open a WebSocket connection first."
    val index = value.trim().removePrefix("#").toIntOrNull()
        ?: return "Enter a frame number from the current connection."
    val frame = filteredWebSocketFrames(connection).getOrNull(index - 1)
        ?: return "No WebSocket frame at position $index. Refresh the frame list; the newest frame is #1."
    selectedWebSocketFrameID = frame.id
    return webSocketSnapshot()
}

internal fun AndroidDebugTools.closeSelectedWebSocketConnection(): String {
    val connection = webSocketConnections.firstOrNull { it.id == selectedWebSocketConnectionID }
        ?: return "Open a WebSocket connection first."
    val socket = activeWebSockets[connection.id]
        ?: return "Connection is already closed."
    val accepted = runCatching { socket.close(1000, "Closed from DebugSwift") }.getOrDefault(false)
    if (!accepted) return "The WebSocket client rejected the close request.\n\n${webSocketSnapshot()}"
    connection.status = "Closing"
    connection.statusDetail = "Close requested by DebugSwift"
    recordWebSocketEvent(connection, "closing", connection.statusDetail)
    selectedWebSocketFrameID = ""
    return webSocketSnapshot()
}

internal fun AndroidDebugTools.copyWebSocketURL(context: Context): String {
    val connection = webSocketConnections.firstOrNull { it.id == selectedWebSocketConnectionID }
        ?: return "Open a WebSocket connection first."
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager
        ?: return "Clipboard service is not available."
    clipboard.setPrimaryClip(ClipData.newPlainText("WebSocket URL", connection.url))
    return "WebSocket URL copied to clipboard.\n\n${webSocketSnapshot()}"
}

internal fun AndroidDebugTools.copyWebSocketPayload(context: Context): String {
    val connection = webSocketConnections.firstOrNull { it.id == selectedWebSocketConnectionID }
        ?: return "Open a WebSocket connection first."
    val frame = connection.frames.firstOrNull { it.id == selectedWebSocketFrameID }
        ?: return "Open a frame first."
    val content = decodeWebSocketPayload(frame.payload)?.let(::prettyWebSocketPayload)
        ?: frame.payload.joinToString(" ") { "%02X".format(it.toInt() and 0xFF) }
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager
        ?: return "Clipboard service is not available."
    clipboard.setPrimaryClip(ClipData.newPlainText("WebSocket payload", content))
    return "Frame payload copied to clipboard.\n\n${webSocketFrameSnapshot(connection, frame)}"
}

internal fun AndroidDebugTools.clearSelectedWebSocketFrames(): String {
    val connection = webSocketConnections.firstOrNull { it.id == selectedWebSocketConnectionID }
    if (connection == null) {
        webSocketConnections.forEach { it.frames.clear(); it.unreadFrameCount.set(0) }
    } else {
        connection.frames.clear()
        connection.unreadFrameCount.set(0)
    }
    selectedWebSocketFrameID = ""
    recordWebSocketEvent(connection ?: WebSocketConnectionRecord("history", "all connections"), "frames cleared", "")
    return webSocketSnapshot()
}

internal fun AndroidDebugTools.sendWebSocketFrame(value: String, resendSelected: Boolean): String {
    val connection = webSocketConnections.firstOrNull { it.id == selectedWebSocketConnectionID }
        ?: return "Open a WebSocket connection first."
    val socket = activeWebSockets[connection.id] ?: return "Connection is closed. Frames cannot be sent."
    val frame = if (resendSelected) {
        connection.frames.firstOrNull { it.id == selectedWebSocketFrameID }
            ?: return "Select a frame to resend first."
    } else null

    val isBase64Payload = !resendSelected && value.startsWith("base64:", ignoreCase = true)
    val payloadText = when {
        frame?.type == "Binary" || isBase64Payload -> null
        frame != null -> decodeWebSocketPayload(frame.payload)
        else -> value
    }
    val payloadBytes = when {
        frame != null -> frame.payload
        value.startsWith("base64:", ignoreCase = true) -> runCatching {
            android.util.Base64.decode(value.substringAfter(':'), android.util.Base64.DEFAULT)
        }.getOrElse { return "Invalid base64 payload: ${it.message}" }
        else -> value.toByteArray(StandardCharsets.UTF_8)
    }
    val sent = if (payloadText == null) {
        runCatching { socket.send(okio.ByteString.of(*payloadBytes)) }.getOrDefault(false)
    } else {
        runCatching { socket.send(payloadText) }.getOrDefault(false)
    }
    if (!sent) return "The WebSocket client rejected the frame.\n\n${webSocketSnapshot()}"
    recordWebSocketFrame(connection, "Sent", if (payloadText == null) "Binary" else "Text", payloadBytes)
    selectedWebSocketFrameID = ""
    return "Frame sent.\n\n${webSocketSnapshot()}"
}

/**
 * The row a closing, closed or failed callback updates. With capture on it is found or made; with
 * capture off, or for a socket whose row was cleared, only a row that still exists is updated.
 */
internal fun AndroidDebugTools.webSocketConnectionForUpdate(webSocket: WebSocket, url: String): WebSocketConnectionRecord? {
    if (webSocketMonitoringEnabled && webSocket !in clearedWebSockets) return findOrCreateWebSocketConnection(webSocket, url)
    val id = webSocketByInstance[webSocket] ?: return null
    return synchronized(webSocketConnections) { webSocketConnections.firstOrNull { it.id == id } }
}

internal fun AndroidDebugTools.clearWebSocketHistory(): String {
    synchronized(webSocketConnections) {
        clearedWebSockets.addAll(webSocketByInstance.keys)
        webSocketByInstance.clear()
        activeWebSockets.clear()
    }
    webSocketConnections.clear()
    webSocketRecords.clear()
    legacyWebSocketIDs.clear()
    selectedWebSocketConnectionID = ""
    selectedWebSocketFrameID = ""
    webSocketFilter = ""
    webSocketDirectionFilter = ""
    events.removeAll { it.contains("WebSocket") }
    publishEvent("network", "WebSocket history cleared")
    return "WebSocket connections and frames cleared."
}
