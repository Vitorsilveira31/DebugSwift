package debug.swift.android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.view.Choreographer
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import androidx.appcompat.app.AppCompatDelegate
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import debug.swift.android.AndroidDebugTools.RecordedInteraction

// Interface tools: grid, interface toggles, appearance, screenshots, touches and the documentation recorder.
// Part of AndroidDebugTools: these extensions use the object's state, which lives in AndroidDebugTools.kt.

/** Starts or stops keeping tapped and scrolled gestures for the documentation recorder. */
fun AndroidDebugTools.setDocumentationRecording(value: Boolean) {
    documentationRecording = value
    publishEvent("interface", "Documentation recording ${if (value) "started" else "stopped"}")
}

fun AndroidDebugTools.documentationState(): String {
    val density = appContext?.resources?.displayMetrics?.density ?: 1f
    val gestures = org.json.JSONArray()
    recordedInteractions.toList().forEach {
        gestures.put(
            JSONObject().put("kind", it.kind).put("startX", it.startX.toDouble()).put("startY", it.startY.toDouble())
                .put("endX", it.endX.toDouble()).put("endY", it.endY.toDouble())
        )
    }
    return JSONObject().put("recording", documentationRecording).put("density", density.toDouble())
        .put("gestures", gestures).put("screenshot", lastRecordingPath).put("message", lastCaptureMessage).toString()
}

fun AndroidDebugTools.captureDocumentationScreenshot(): String = captureScreenshot(annotateTouches = true)

fun AndroidDebugTools.clearDocumentation() {
    recordedInteractions.clear()
    recentTouches.clear()
    lastRecordingPath = ""
}

internal fun AndroidDebugTools.setGridOptions(value: String): String {
    val parts = value.split(",", limit = 2).map { it.trim() }
    val spacing = parts.firstOrNull()?.toFloatOrNull()
        ?: return "Enter grid spacing in dp, optionally followed by a color such as 24,#663399FF."
    if (spacing !in 4f..256f) return "Grid spacing must be between 4 and 256 dp."
    val color = parts.getOrNull(1)?.takeIf { it.isNotEmpty() }?.let {
        runCatching { Color.parseColor(it) }.getOrElse { return "Invalid color. Use #RRGGBB or #AARRGGBB." }
    }
    gridSpacingDp = spacing
    if (color != null) gridColor = color
    debugOverlay?.postInvalidate()
    publishEvent("interface", "Grid set to ${gridSpacingDp}dp")
    return "Grid spacing set to ${gridSpacingDp}dp" + (color?.let { " with #${"%08X".format(it)}." } ?: ".")
}

fun AndroidDebugTools.gridSettings(): String {
    val enabled = synchronized(enabledTools) { "grid" in enabledTools }
    return "$enabled|$gridSpacingDp|$gridOpacity|$gridColorIndex"
}

fun AndroidDebugTools.setGridSettings(value: String): String {
    val parts = value.split("|")
    if (parts.size != 4) return "Expected enabled|size|opacity|colorIndex."
    val isEnabled = parts[0].toBooleanStrictOrNull()
        ?: return "Grid enabled value must be true or false."
    val spacing = parts[1].toFloatOrNull()
        ?: return "Grid size must be a number from 4 to 64 dp."
    val opacity = parts[2].toFloatOrNull()
        ?: return "Grid opacity must be a number from 0.1 to 1.0."
    val colorIndex = parts[3].toIntOrNull()
        ?: return "Grid color index must be an integer from 0 to 5."
    if (spacing !in 4f..64f) return "Grid size must be between 4 and 64 dp."
    if (opacity !in 0.1f..1f) return "Grid opacity must be between 0.1 and 1.0."
    if (colorIndex !in gridColors.indices) return "Grid color index must be between 0 and 5."

    gridSpacingDp = spacing
    gridOpacity = opacity
    gridColorIndex = colorIndex
    gridColor = gridColors[colorIndex]
    synchronized(enabledTools) {
        if (isEnabled) enabledTools.add("grid") else enabledTools.remove("grid")
    }
    updateOverlay()
    publishEvent("interface", "Grid ${if (isEnabled) "enabled" else "disabled"} at ${spacing}dp")
    return "Grid ${if (isEnabled) "enabled" else "disabled"}: ${spacing}dp, ${"%.1f".format(opacity)} opacity, color $colorIndex."
}

fun AndroidDebugTools.interfaceToolEnabled(featureID: String): Boolean {
    if (featureID == "dark_mode") {
        return AppCompatDelegate.getDefaultNightMode() == AppCompatDelegate.MODE_NIGHT_YES
    }
    return synchronized(enabledTools) { featureID in enabledTools }
}

fun AndroidDebugTools.setInterfaceToolEnabled(featureID: String, enabled: Boolean): String {
    if (featureID == "dark_mode") {
        val context = appContext ?: return "Android runtime has not been installed."
        return setDarkModeOverride(context, enabled)
    }
    if (featureID !in setOf("grid", "touches", "view_borders")) {
        return "Interface toggle '$featureID' is not available on Android."
    }
    synchronized(enabledTools) {
        if (enabled) enabledTools.add(featureID) else enabledTools.remove(featureID)
    }
    updateOverlay()
    publishEvent("interface", "$featureID ${if (enabled) "enabled" else "disabled"}")
    return "$featureID ${if (enabled) "enabled" else "disabled"}."
}

fun AndroidDebugTools.recordWebViewHost(host: String) {
    if (host.isNotBlank() && host !in webViewHosts) webViewHosts.add(host)
}

internal fun AndroidDebugTools.localTouchPosition(event: MotionEvent): Pair<Float, Float> {
    val offset = IntArray(2)
    foregroundActivity.get()?.window?.decorView?.getLocationOnScreen(offset)
    return (event.rawX - offset[0]) to (event.rawY - offset[1])
}

fun AndroidDebugTools.captureHierarchy(): String {
    val activity = foregroundActivity.get() ?: return "No foreground activity is available."
    val root = activity.window.decorView
    return buildString {
        append("Window ${root.width} × ${root.height}px\n")
        describeView(root, 0, this)
    }.take(40_000)
}

internal fun AndroidDebugTools.interfaceSnapshot(context: Context, featureID: String): String {
    return when (featureID) {
        "view_hierarchy", "measurement" -> captureHierarchy()
        "grid", "touches", "view_borders" -> "Enabled: ${synchronized(enabledTools) { featureID in enabledTools }}\nOverlay is drawn in the host app window without the system draw-over-other-apps permission.\nGrid: ${gridSpacingDp}dp, ${"%.1f".format(gridOpacity)} opacity, #${"%08X".format(gridColor)}\nRecent touches: ${recentTouches.size}"
        "animation_control" -> {
            val keys = listOf("window_animation_scale", "transition_animation_scale", "animator_duration_scale")
            "Android system animation scales:\n" + keys.joinToString("\n") { key ->
                val value = runCatching { android.provider.Settings.Global.getFloat(context.contentResolver, key, 1f) }.getOrDefault(1f)
                "$key: ${value}×"
            } + "\n\nUse Open Developer options to change these system-wide settings."
        }
        "dark_mode" -> appearanceSnapshot(context)
        "render_tracking" -> "Compose recompositions observed: $composeRenderCount\nMeasured frame callbacks: $frameCount\nSlow frames: $slowFrameCount"
        "doc_recorder" -> "Recorded gestures: ${recordedInteractions.size}\nTaps: ${recordedInteractions.count { it.kind == "tap" }}\nScrolls: ${recordedInteractions.count { it.kind == "scroll" }}\nLast screenshot: ${lastRecordingPath.ifEmpty { "none" }}"
        "color_palette" -> "Most common colors in the last captured app window:\n${lastPalette.joinToString("\n").ifEmpty { "Capture a screen to sample its colors." }}"
        else -> "View hierarchy entries: ${captureHierarchy().lineSequence().count()}"
    }
}

internal fun AndroidDebugTools.appearanceSnapshot(context: Context): String {
    val override = when (AppCompatDelegate.getDefaultNightMode()) {
        AppCompatDelegate.MODE_NIGHT_YES -> "Dark"
        AppCompatDelegate.MODE_NIGHT_NO -> "Light"
        else -> "Follow system"
    }
    val windowContext = foregroundActivity.get() ?: context
    val nightMode = windowContext.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK
    val effective = if (nightMode == android.content.res.Configuration.UI_MODE_NIGHT_YES) "Dark" else "Light"
    return "Appearance override: $override\nCurrent host window: $effective\n\nToggle Dark Mode to force light or dark appearance. Follow system appearance clears the override. AppCompat host activities apply the override when their theme supports DayNight."
}

internal fun AndroidDebugTools.toggleDarkMode(context: Context): String {
    val windowContext = foregroundActivity.get() ?: context
    val nightMode = windowContext.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK
    val currentlyDark = when (AppCompatDelegate.getDefaultNightMode()) {
        AppCompatDelegate.MODE_NIGHT_YES -> true
        AppCompatDelegate.MODE_NIGHT_NO -> false
        else -> nightMode == android.content.res.Configuration.UI_MODE_NIGHT_YES
    }
    val newMode = if (currentlyDark) AppCompatDelegate.MODE_NIGHT_NO else AppCompatDelegate.MODE_NIGHT_YES
    val override = if (newMode == AppCompatDelegate.MODE_NIGHT_YES) "dark" else "light"
    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("appearance_override", override).apply()
    AppCompatDelegate.setDefaultNightMode(newMode)
    publishEvent("interface", "Appearance forced to $override mode")
    return "App appearance forced to ${override.replaceFirstChar { it.uppercase() }} mode. AppCompat host activities apply the override when their theme supports DayNight."
}

internal fun AndroidDebugTools.resetDarkMode(context: Context): String {
    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove("appearance_override").apply()
    AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM)
    publishEvent("interface", "Appearance follows system settings")
    return "App appearance now follows the Android system setting."
}

internal fun AndroidDebugTools.setDarkModeOverride(context: Context, enabled: Boolean): String {
    if (!enabled) return resetDarkMode(context)
    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("appearance_override", "dark").apply()
    AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_YES)
    publishEvent("interface", "Appearance forced to dark mode")
    return "App appearance forced to Dark mode. AppCompat host activities apply the override when their theme supports DayNight."
}

internal fun AndroidDebugTools.restoreAppearanceOverride(context: Context) {
    val mode = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("appearance_override", "system")
    AppCompatDelegate.setDefaultNightMode(
        when (mode) {
            "dark" -> AppCompatDelegate.MODE_NIGHT_YES
            "light" -> AppCompatDelegate.MODE_NIGHT_NO
            else -> AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM
        }
    )
}

/**
 * Saves the window as a PNG with the recorded gestures drawn on it. The screen is read with a pixel
 * copy, which sees what is really shown (software drawing fails on shaders), and the floating
 * button is hidden for two frames first. It finishes a moment after this returns; the result shows
 * up in [documentationState].
 */
internal fun AndroidDebugTools.captureScreenshot(annotateTouches: Boolean = false): String {
    val activity = foregroundActivity.get() ?: return "No active window is available."
    val decor = activity.window.decorView
    if (decor.width <= 0 || decor.height <= 0) return "The active window has no layout yet."
    lastCaptureMessage = ""
    mainHandler.post {
        DebugSwiftFloatingButton.setSuppressed(activity, true)
        val choreographer = Choreographer.getInstance()
        choreographer.postFrameCallback {
            choreographer.postFrameCallback {
                Thread {
                    val bitmap = DebugSwiftPalette.windowBitmap(activity)
                    mainHandler.post { DebugSwiftFloatingButton.setSuppressed(activity, false) }
                    if (bitmap == null) {
                        lastCaptureMessage = "The screen could not be read."
                        return@Thread
                    }
                    if (annotateTouches) annotate(bitmap, recordedInteractions.takeLast(24), activity.resources.displayMetrics.density)
                    val file = File(appContext!!.cacheDir, "debugswift-screen-${System.currentTimeMillis()}.png")
                    file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                    bitmap.recycle()
                    lastRecordingPath = file.absolutePath
                    lastCaptureMessage = "Screenshot saved to ${file.absolutePath}"
                    publishEvent("interface", "Screenshot saved: ${file.name}")
                }.start()
            }
        }
    }
    return "Capturing the screen..."
}

/** Numbered dots for taps; a numbered dot and an arrow for scrolls. */
internal fun AndroidDebugTools.annotate(bitmap: Bitmap, interactions: List<RecordedInteraction>, density: Float) {
    val canvas = Canvas(bitmap)
    val markPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.RED; style = Paint.Style.FILL }
    val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.RED; style = Paint.Style.STROKE; strokeWidth = 2.5f * density }
    val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 11f * density
        textAlign = Paint.Align.CENTER
        style = Paint.Style.FILL
        isFakeBoldText = true
    }
    val radius = 11f * density
    interactions.forEachIndexed { index, interaction ->
        val label = (index + 1).toString()
        if (interaction.kind == "scroll") {
            canvas.drawLine(interaction.startX, interaction.startY, interaction.endX, interaction.endY, linePaint)
            val angle = atan2(interaction.endY - interaction.startY, interaction.endX - interaction.startX)
            val headLength = 12f * density
            val spread = (PI / 6).toFloat()
            canvas.drawLine(interaction.endX, interaction.endY, interaction.endX - headLength * cos(angle - spread), interaction.endY - headLength * sin(angle - spread), linePaint)
            canvas.drawLine(interaction.endX, interaction.endY, interaction.endX - headLength * cos(angle + spread), interaction.endY - headLength * sin(angle + spread), linePaint)
            canvas.drawCircle(interaction.startX, interaction.startY, radius, markPaint)
            canvas.drawText(label, interaction.startX, interaction.startY + labelPaint.textSize / 3f, labelPaint)
        } else {
            canvas.drawCircle(interaction.endX, interaction.endY, radius, markPaint)
            canvas.drawText(label, interaction.endX, interaction.endY + labelPaint.textSize / 3f, labelPaint)
        }
    }
}

internal fun AndroidDebugTools.capturePalette(): String {
    val activity = foregroundActivity.get() ?: return "No active window is available."
    val view = activity.window.decorView
    if (view.width <= 0 || view.height <= 0) return "The active window has no layout yet."
    val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
    view.draw(Canvas(bitmap))
    val pixels = IntArray(bitmap.width * bitmap.height)
    bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
    lastPalette = pixels.asSequence()
        .filter { Color.alpha(it) > 200 }
        .map { color -> Color.rgb(Color.red(color) / 16 * 16, Color.green(color) / 16 * 16, Color.blue(color) / 16 * 16) }
        .groupingBy { it }
        .eachCount()
        .entries
        .sortedByDescending { it.value }
        .take(12)
        .map { "#%06X · %d px".format(it.key and 0xFFFFFF, it.value) }
    bitmap.recycle()
    publishEvent("interface", "Sampled ${lastPalette.size} screen colors")
    return lastPalette.joinToString("\n").ifEmpty { "No opaque colors could be sampled." }
}

internal fun AndroidDebugTools.describeView(view: View, depth: Int, output: StringBuilder) {
    if (depth > 12 || output.length > 40_000) return
    val rect = Rect()
    view.getGlobalVisibleRect(rect)
    output.append("  ".repeat(depth))
        .append(view.javaClass.simpleName)
        .append(" [${rect.left},${rect.top} ${rect.width()}×${rect.height()}]")
    if (view.id != View.NO_ID) {
        val id = runCatching { view.resources.getResourceEntryName(view.id) }.getOrNull()
        if (id != null) output.append(" id=").append(id)
    }
    if (view.contentDescription != null) output.append(" label=").append(view.contentDescription)
    output.append('\n')
    if (view is ViewGroup) for (index in 0 until view.childCount) describeView(view.getChildAt(index), depth + 1, output)
}
