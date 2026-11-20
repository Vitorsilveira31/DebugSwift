package debug.swift.android

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Camera
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.ScaleGestureDetector
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.node.RootForTest
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull

/**
 * The 3D view debugger: the foreground window taken apart into layers, one per view and Compose
 * element, stacked by depth in the tree. Drag to rotate, pinch to space the layers, tap a layer to
 * name it, double tap to reset, and tap Close to go back to the app.
 *
 * Compose elements are not views and cannot be drawn alone, so each layer shows the part of a pixel
 * copy of the window that its element covers.
 */
object DebugSwiftViewDebugger3D {
    private const val MAX_LAYERS = 800
    private val main = Handler(Looper.getMainLooper())
    private var viewer: Viewer? = null

    private class Layer(val rect: Rect, val depth: Int, val name: String, val isCompose: Boolean)

    val isShowing: Boolean get() = viewer != null

    /** Captures the foreground window and shows it in 3D over the app. */
    fun show(): String {
        val activity = AndroidDebugTools.foregroundActivityOrNull() ?: return "No foreground activity is available."
        main.post { present(activity) }
        return "Opening the 3D view debugger."
    }

    fun hide() {
        main.post { dismiss() }
    }

    private fun present(activity: Activity) {
        dismiss()
        val decor = activity.window.decorView as? ViewGroup ?: return
        if (decor.width <= 0 || decor.height <= 0) return
        val layers = mutableListOf<Layer>()
        // Capture the app as it is, without the floating button over it.
        DebugSwiftFloatingButton.setSuppressed(activity, true)
        collect(decor, 0, layers)
        val screenshot = Bitmap.createBitmap(decor.width, decor.height, Bitmap.Config.ARGB_8888)
        val attach = {
            val view = Viewer(activity, screenshot, layers)
            decor.addView(view, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            // The floating button lives in the same window; keep it out of the way while the viewer is open.
            DebugSwiftFloatingButton.setSuppressed(activity, true)
            viewer = view
            AndroidDebugTools.log("3D view debugger opened with ${layers.size} layers")
        }
        // Wait for a frame without the floating button before copying the window.
        main.postDelayed({
            if (Build.VERSION.SDK_INT >= 26) {
                runCatching {
                    PixelCopy.request(activity.window, screenshot, { result ->
                        if (result != PixelCopy.SUCCESS) decor.draw(Canvas(screenshot))
                        attach()
                    }, main)
                }.onFailure {
                    decor.draw(Canvas(screenshot))
                    attach()
                }
            } else {
                decor.draw(Canvas(screenshot))
                attach()
            }
        }, 150)
    }

    private fun dismiss() {
        val view = viewer ?: return
        (view.parent as? ViewGroup)?.removeView(view)
        (view.context as? Activity)?.let { DebugSwiftFloatingButton.setSuppressed(it, false) }
        viewer = null
    }

    private fun collect(view: View, depth: Int, layers: MutableList<Layer>) {
        if (layers.size >= MAX_LAYERS || view is Viewer || view.visibility != View.VISIBLE) return
        if (view.width > 0 && view.height > 0) {
            val location = IntArray(2)
            view.getLocationInWindow(location)
            val rect = Rect(location[0], location[1], location[0] + view.width, location[1] + view.height)
            layers.add(Layer(rect, depth, view.javaClass.simpleName.ifEmpty { view.javaClass.name }, isCompose = false))
        }
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) collect(view.getChildAt(index), depth + 1, layers)
        }
        if (view is RootForTest) {
            runCatching { collect(view.semanticsOwner.unmergedRootSemanticsNode, depth + 1, layers) }
        }
    }

    private fun collect(node: SemanticsNode, depth: Int, layers: MutableList<Layer>) {
        if (layers.size >= MAX_LAYERS) return
        val bounds = node.boundsInWindow
        if (bounds.width > 0f && bounds.height > 0f && !node.config.contains(SemanticsProperties.InvisibleToUser)) {
            val text = node.config.getOrNull(SemanticsProperties.Text)?.joinToString(" ") { it.text }
                ?: node.config.getOrNull(SemanticsProperties.ContentDescription)?.joinToString(" ")
            val role = node.config.getOrNull(SemanticsProperties.Role)?.toString() ?: "Compose"
            val name = if (text.isNullOrBlank()) role else "$role \"${text.take(40)}\""
            val rect = Rect(bounds.left.toInt(), bounds.top.toInt(), bounds.right.toInt(), bounds.bottom.toInt())
            layers.add(Layer(rect, depth, name, isCompose = true))
        }
        node.children.forEach { collect(it, depth + 1, layers) }
    }

    @SuppressLint("ViewConstructor")
    private class Viewer(
        activity: Activity,
        private val screenshot: Bitmap,
        private val layers: List<Layer>
    ) : View(activity) {
        private val density = resources.displayMetrics.density
        private val camera = Camera().apply { setLocation(0f, 0f, -48f) }
        private val matrix = Matrix()
        private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
        private val viewStroke = stroke(0xFF4FC3F7.toInt())
        private val composeStroke = stroke(0xFFFFB74D.toInt())
        private val selectedStroke = stroke(0xFFFF3B30.toInt(), width = 3f)
        private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; textSize = 14f * density }
        private val buttonPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xCC333333.toInt() }
        private val closeRect = RectF()
        private val maxDepth = (layers.maxOfOrNull { it.depth } ?: 0).coerceAtLeast(1)

        private var rotationX = 18f
        private var rotationY = -32f
        private var spacing = 14f * density
        private var selected: Layer? = null

        private val gestures = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(event: MotionEvent) = true

            override fun onScroll(start: MotionEvent?, event: MotionEvent, dx: Float, dy: Float): Boolean {
                rotationY = (rotationY - dx * 0.12f).coerceIn(-80f, 80f)
                rotationX = (rotationX + dy * 0.12f).coerceIn(-80f, 80f)
                invalidate()
                return true
            }

            override fun onSingleTapConfirmed(event: MotionEvent): Boolean {
                if (closeRect.contains(event.x, event.y)) {
                    dismiss()
                    return true
                }
                selected = layerAt(event.x, event.y)
                invalidate()
                return true
            }

            override fun onDoubleTap(event: MotionEvent): Boolean {
                rotationX = 0f
                rotationY = 0f
                spacing = 14f * density
                invalidate()
                return true
            }
        })

        private val pinch = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(detector: ScaleGestureDetector): Boolean {
                spacing = (spacing * detector.scaleFactor).coerceIn(0f, 80f * density)
                invalidate()
                return true
            }
        })

        init {
            isClickable = true
            setBackgroundColor(0xFF121212.toInt())
        }

        private fun stroke(color: Int, width: Float = 1f) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color
            style = Paint.Style.STROKE
            strokeWidth = width * density
        }

        /** Maps a point of the window into the rotated, scaled scene for a layer at `depth`. */
        private fun transform(depth: Int): Matrix {
            val scale = 0.62f
            val centerX = width / 2f
            val centerY = height / 2f
            camera.save()
            camera.rotateX(rotationX)
            camera.rotateY(rotationY)
            camera.translate(0f, 0f, -(depth - maxDepth / 2f) * spacing / density)
            camera.getMatrix(matrix)
            camera.restore()
            matrix.preScale(scale, scale)
            matrix.preTranslate(-screenshot.width / 2f, -screenshot.height / 2f)
            matrix.postTranslate(centerX, centerY)
            return matrix
        }

        private fun layerAt(x: Float, y: Float): Layer? {
            val mapped = RectF()
            return layers.sortedByDescending { it.depth }.firstOrNull { layer ->
                transform(layer.depth).mapRect(mapped, RectF(layer.rect))
                mapped.contains(x, y)
            }
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            for (layer in layers.sortedBy { it.depth }) {
                canvas.save()
                canvas.concat(transform(layer.depth))
                canvas.drawBitmap(screenshot, layer.rect, layer.rect, bitmapPaint)
                canvas.drawRect(layer.rect, if (layer.isCompose) composeStroke else viewStroke)
                if (layer === selected) canvas.drawRect(layer.rect, selectedStroke)
                canvas.restore()
            }
            drawChrome(canvas)
        }

        private fun drawChrome(canvas: Canvas) {
            val margin = 16f * density
            val label = "Close"
            val labelWidth = textPaint.measureText(label)
            closeRect.set(width - margin - labelWidth - 24f * density, margin + 24f * density, width - margin, margin + 64f * density)
            canvas.drawRoundRect(closeRect, 12f * density, 12f * density, buttonPaint)
            canvas.drawText(label, closeRect.left + 12f * density, closeRect.centerY() + 5f * density, textPaint)

            val lines = selected?.let { listOf(it.name, "${it.rect.width()}×${it.rect.height()} px · depth ${it.depth}") }
                ?: listOf("${layers.size} layers · drag to rotate, pinch to space", "tap to identify, double tap to reset")
            val lineHeight = textPaint.textSize * 1.4f
            lines.forEachIndexed { index, line ->
                val fitted = if (textPaint.measureText(line) > width - margin * 2) {
                    line.take(textPaint.breakText(line, true, width - margin * 2 - textPaint.measureText("…"), null)) + "…"
                } else line
                canvas.drawText(fitted, margin, height - margin * 2 - (lines.size - 1 - index) * lineHeight, textPaint)
            }
        }

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(event: MotionEvent): Boolean {
            pinch.onTouchEvent(event)
            if (!pinch.isInProgress) gestures.onTouchEvent(event)
            return true
        }
    }
}
