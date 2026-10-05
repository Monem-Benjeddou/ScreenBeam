package com.screenbeam.app

import android.annotation.SuppressLint
import android.content.Context
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.SurfaceView
import android.widget.FrameLayout

/**
 * Shows the video letterboxed at its true aspect ratio, with pinch-zoom, pan and double-tap zoom.
 *
 * Uses a SurfaceView (not TextureView) so decoded frames go straight to the display hardware
 * without an extra GPU composition pass — about one frame less latency. Zoom works by
 * resizing/moving the SurfaceView itself; the display hardware does the scaling.
 */
class ZoomableVideoView(context: Context) : FrameLayout(context) {
    val surfaceView = SurfaceView(context)
    var onSingleTap: (() -> Unit)? = null

    /** How the Mac's 16:10 picture fits the phone's ~19.5:9 screen. */
    enum class Scale(val label: String) { FIT("Fit"), FILL("Fill"), STRETCH("Stretch") }

    var scale = Scale.FIT
        set(value) {
            field = value
            zoom = 1f; panX = 0f; panY = 0f
            apply()
        }

    private var videoWidth = 0
    private var videoHeight = 0
    private var zoom = 1f
    private var panX = 0f
    private var panY = 0f

    init {
        addView(surfaceView, LayoutParams(1, 1))
    }

    private val scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(d: ScaleGestureDetector): Boolean {
            zoomTo(zoom * d.scaleFactor, d.focusX, d.focusY)
            return true
        }
    })

    private val gestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, dx: Float, dy: Float): Boolean {
            if (zoom <= 1f) return false
            panX -= dx
            panY -= dy
            apply()
            return true
        }

        override fun onDoubleTap(e: MotionEvent): Boolean {
            if (zoom > 1.05f) {
                zoom = 1f; panX = 0f; panY = 0f
                apply()
            } else {
                zoomTo(2.5f, e.x, e.y)
            }
            return true
        }

        override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
            onSingleTap?.invoke()
            return true
        }
    })

    fun setVideoSize(width: Int, height: Int) {
        if (width == videoWidth && height == videoHeight) return
        videoWidth = width
        videoHeight = height
        // Buffer at the video's native size; the hardware composer scales it to the view.
        surfaceView.holder.setFixedSize(width, height)
        zoom = 1f; panX = 0f; panY = 0f
        apply()
    }

    fun resetZoom() {
        zoom = 1f; panX = 0f; panY = 0f
        apply()
    }

    /** Converts a point in this view to 0..1 coordinates on the Mac's screen, or null if outside the video. */
    fun mapToVideo(x: Float, y: Float): android.graphics.PointF? {
        val w = surfaceView.layoutParams.width.toFloat()
        val h = surfaceView.layoutParams.height.toFloat()
        if (w <= 1 || h <= 1) return null
        val u = (x - surfaceView.translationX) / w
        val v = (y - surfaceView.translationY) / h
        if (u < -0.02f || u > 1.02f || v < -0.02f || v > 1.02f) return null
        return android.graphics.PointF(u.coerceIn(0f, 1f), v.coerceIn(0f, 1f))
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaleDetector.onTouchEvent(event)
        gestureDetector.onTouchEvent(event)
        return true
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        panX = 0f; panY = 0f
        post { apply() } // can't request layout from inside a layout pass
    }

    private fun zoomTo(target: Float, focusX: Float, focusY: Float) {
        val newZoom = target.coerceIn(1f, MAX_ZOOM)
        val factor = newZoom / zoom
        // Keep the point under the fingers fixed while scaling.
        val fx = focusX - width / 2f
        val fy = focusY - height / 2f
        panX = fx - (fx - panX) * factor
        panY = fy - (fy - panY) * factor
        zoom = newZoom
        apply()
    }

    private fun apply() {
        val vw = width.toFloat()
        val vh = height.toFloat()
        if (vw <= 0 || vh <= 0) return
        val srcW = if (videoWidth > 0) videoWidth else width
        val srcH = if (videoHeight > 0) videoHeight else height

        val contentW: Float
        val contentH: Float
        when (scale) {
            Scale.STRETCH -> { contentW = vw * zoom; contentH = vh * zoom }
            else -> {
                val s = if (scale == Scale.FIT) minOf(vw / srcW, vh / srcH) else maxOf(vw / srcW, vh / srcH)
                contentW = srcW * s * zoom
                contentH = srcH * s * zoom
            }
        }

        val maxPanX = maxOf(0f, (contentW - vw) / 2f)
        val maxPanY = maxOf(0f, (contentH - vh) / 2f)
        panX = panX.coerceIn(-maxPanX, maxPanX)
        panY = panY.coerceIn(-maxPanY, maxPanY)

        val lp = surfaceView.layoutParams
        val w = contentW.toInt()
        val h = contentH.toInt()
        if (lp.width != w || lp.height != h) {
            lp.width = w
            lp.height = h
            surfaceView.layoutParams = lp
        }
        surfaceView.translationX = (vw - contentW) / 2f + panX
        surfaceView.translationY = (vh - contentH) / 2f + panY
    }

    companion object {
        private const val MAX_ZOOM = 6f
    }
}
