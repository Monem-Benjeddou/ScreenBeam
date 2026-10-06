package com.screenbeam.app

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.drawable.GradientDrawable
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.widget.PopupMenu
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.Surface
import android.view.WindowManager
import android.view.HapticFeedbackConstants
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.sign

/** Where input goes; returns null while not connected. */
typealias InputProvider = () -> StreamClient?

enum class ControlMode(val label: String) {
    VIEW("View"), TOUCH("Touch"), TRACKPAD("Mouse"), GAMEPAD("Game"), PAD("Pad"), SOUND("Sound"), KEYBOARD("Keys"),
    EXTEND("Extend");

    /**
     * No video is sent: PAD = the phone is a controller (you watch the Mac's own screen),
     * SOUND = the phone is just a speaker for the Mac.
     */
    val noVideo get() = this == PAD || this == SOUND

    /** The phone is an extra screen for the Mac (a virtual display), not a mirror of one. */
    val extendsDisplay get() = this == EXTEND

    /** The finger is the cursor: tap exactly where you want to click. */
    val directTouch get() = this == TOUCH || this == EXTEND
}

/** What people want to do. Each goal groups the control styles that serve it. */
enum class Goal(val label: String, val icon: String, val modes: List<ControlMode>) {
    WATCH("Watch", "👁", listOf(ControlMode.VIEW)),
    CONTROL("Control", "🖱", listOf(ControlMode.TRACKPAD, ControlMode.TOUCH, ControlMode.KEYBOARD)),
    PLAY("Play", "🎮", listOf(ControlMode.GAMEPAD, ControlMode.PAD)),
    LISTEN("Listen", "🔊", listOf(ControlMode.SOUND)),
    EXTEND("Extend", "🖥", listOf(ControlMode.EXTEND));

    companion object {
        fun of(mode: ControlMode) = values().first { mode in it.modes }
    }
}

/** Short name for a style inside its goal, and the one-line explanation shown when it's picked. */
private val ControlMode.styleLabel get() = when (this) {
    ControlMode.TRACKPAD -> "Trackpad"
    ControlMode.TOUCH -> "Touch"
    ControlMode.KEYBOARD -> "Keyboard"
    ControlMode.GAMEPAD -> "On screen"
    ControlMode.PAD -> "Controller only"
    ControlMode.EXTEND -> "Second screen"
    else -> label
}

private val ControlMode.hint get() = when (this) {
    ControlMode.VIEW -> "Pinch to zoom, drag to move around, double-tap to zoom in."
    ControlMode.TRACKPAD -> "Slide to move the pointer. Tap to click. Two fingers to scroll or right-click."
    ControlMode.TOUCH -> "Tap exactly where you want to click. Two fingers to scroll or right-click."
    ControlMode.KEYBOARD -> "Type below; the space above is a trackpad. Fn·Num has F-keys and the numpad."
    ControlMode.GAMEPAD -> "Left side moves. Drag on the right to look. Hold AIM and tilt the phone to aim."
    ControlMode.PAD -> "Watch the Mac's screen; your phone is the controller. No video is sent."
    ControlMode.SOUND -> "Your Mac's sound plays on this phone. No video is sent."
    ControlMode.EXTEND -> "Your phone is an extra screen. Drag windows onto it from your Mac. Tap to click."
}

/** What the overlay asks of the activity. */
interface ControlsHost {
    fun voiceInput()
    fun typeText()
    fun showStats()
    fun disconnect()
    fun setSound(on: Boolean)
    fun isSoundOn(): Boolean
    fun modeChanged(old: ControlMode, new: ControlMode)
}

/** A Mac input an on-screen control can hold down. */
sealed class Action {
    data class Key(val code: Int) : Action()
    data class Mouse(val button: Int) : Action()

    fun send(input: StreamClient?, down: Boolean) {
        when (this) {
            is Key -> input?.key(code, down)
            is Mouse -> input?.mouseButton(button, down)
        }
    }
}

/** Tracks which Mac keys we hold so a control only sends transitions (and can release everything). */
class HeldKeys(private val input: InputProvider) {
    private val held = HashSet<Int>()

    fun set(code: Int, down: Boolean) {
        if (down == held.contains(code)) return
        if (down) held += code else held -= code
        input()?.key(code, down)
    }

    fun releaseAll() {
        for (code in held.toList()) set(code, false)
    }
}

/**
 * Remote-control layer drawn over the video: a mode bar plus the touch/trackpad, gamepad and keyboard surfaces.
 * In VIEW mode it is transparent to touches so pinch-zoom works on the video.
 */
@SuppressLint("ViewConstructor")
class ControlsOverlay(
    context: Context,
    private val video: ZoomableVideoView,
    private val input: InputProvider,
    private val host: ControlsHost,
) : FrameLayout(context) {

    private val prefs = context.getSharedPreferences("screenbeam", Context.MODE_PRIVATE)
    var mode = ControlMode.VIEW
        private set
    var sensitivity = prefs.getFloat("sensitivity", 1.5f)
        private set

    private val pointer = PointerLayer()
    private val gamepad = GamepadLayer()
    private val keyboard = KeyboardLayer()
    private val goalButtons = HashMap<Goal, TextView>()
    private val styleRow = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        background = pill(Color.parseColor("#66000000"), 12)
        setPadding(dp(3), dp(3), dp(3), dp(3))
    }
    private val hintView = TextView(context).apply {
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        background = pill(Color.parseColor("#CC000000"), 12)
        setPadding(dp(14), dp(8), dp(14), dp(8))
        visibility = GONE
    }
    private val hideHint = Runnable { hintView.visibility = GONE }

    /** Connection quality at a glance; tap for what to do about it. */
    private val qualityDot = TextView(context).apply {
        text = "●"
        gravity = Gravity.CENTER
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        setTextColor(Color.parseColor("#888888"))
        setPadding(dp(10), dp(6), dp(8), dp(6))
        contentDescription = "Connection quality"
    }
    private var qualityAdvice = "Measuring the connection…"

    /** Edit-layout mode: game buttons can be dragged/resized and send no input. */
    private var editingLayout = false
    private val soundPanel = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        addView(TextView(context).apply {
            text = "🔊"
            gravity = Gravity.CENTER
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 56f)
        })
        addView(TextView(context).apply {
            text = "Playing your Mac's sound"
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#E6FFFFFF"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            setPadding(0, dp(12), 0, dp(6))
        })
        addView(TextView(context).apply {
            text = "Use the phone's volume buttons. No video is sent, so the screen stays dim."
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#99FFFFFF"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        })
    }
    private val barItems = ArrayList<View>()
    private var barCollapsed = false
    /** Button transparency, so controls don't cover the game. */
    private var controlOpacity = prefs.getFloat("opacity", 0.55f)
    private val gyro = GyroAim()
    /** True while AIM is held (gyro "while aiming" mode). */
    private var aiming = false
    private var initialized = false

    init {
        addView(pointer, LayoutParams(MATCH_PARENT, MATCH_PARENT))
        addView(gamepad, LayoutParams(MATCH_PARENT, MATCH_PARENT))
        addView(keyboard, LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.BOTTOM))
        addView(soundPanel, LayoutParams(MATCH_PARENT, MATCH_PARENT))

        val bar = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            background = pill(Color.parseColor("#66000000"), 14)
            setPadding(dp(3), dp(3), dp(3), dp(3))
        }
        qualityDot.setOnClickListener { showHint(qualityAdvice) }
        bar.addView(qualityDot)
        for (g in Goal.values()) {
            val b = chip("${g.icon} ${g.label}") {
                // Re-open the style last used for this goal.
                val saved = prefs.getString("style_${g.name}", null)
                setMode(g.modes.firstOrNull { it.name == saved } ?: g.modes.first())
            }
            b.contentDescription = g.label
            goalButtons[g] = b
            bar.addView(b); barItems += b
        }
        chip("🎤") { host.voiceInput() }.also { bar.addView(it); barItems += it }
        chip("Aa") { host.typeText() }.also { bar.addView(it); barItems += it }
        lateinit var menuChip: TextView
        menuChip = chip("☰") { showMenu(menuChip) }
        bar.addView(menuChip); barItems += menuChip
        // Collapse the bar to one small dot so it doesn't cover the game's HUD.
        val collapse = chip("‹") {}
        collapse.setOnClickListener {
            barCollapsed = !barCollapsed
            barItems.forEach { it.visibility = if (barCollapsed) GONE else VISIBLE }
            if (!barCollapsed && styleRow.childCount == 0) styleRow.visibility = GONE
            collapse.text = if (barCollapsed) "›" else "‹"
            prefs.edit().putBoolean("barCollapsed", barCollapsed).apply()
        }
        bar.addView(collapse)
        if (prefs.getBoolean("barCollapsed", false)) collapse.performClick()
        barItems += styleRow
        addView(bar, LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.TOP or Gravity.END).apply {
            topMargin = dp(8); rightMargin = dp(8)
        })
        // Separate sibling (not stacked in one container), so each row sizes itself.
        addView(styleRow, LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.TOP or Gravity.END).apply {
            topMargin = dp(52); rightMargin = dp(8)
        })
        addView(hintView, LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
            bottomMargin = dp(24); leftMargin = dp(24); rightMargin = dp(24)
        })

        video.scale = runCatching { ZoomableVideoView.Scale.valueOf(prefs.getString("scale", "FIT")!!) }
            .getOrDefault(ZoomableVideoView.Scale.FIT)
        gamepad.alpha = controlOpacity
        setMode(runCatching { ControlMode.valueOf(prefs.getString("mode", "VIEW")!!) }.getOrDefault(ControlMode.VIEW))
        initialized = true
    }

    private fun showMenu(anchor: View) {
        val menu = PopupMenu(context, anchor)
        val scaleItem = menu.menu.add("Picture: ${video.scale.label}  (Fit · Fill · Stretch)")
        val soundItem = menu.menu.add("Sound on phone: ${if (host.isSoundOn()) "On" else "Off"}")
        val opacityItem = menu.menu.add("Button visibility: ${(controlOpacity * 100).toInt()}%")
        val gyroItem = menu.menu.add("Gyro aim: ${gyro.modeLabel}")
        val editItem = menu.menu.add("Edit game buttons")
        val statsItem = menu.menu.add("Show stats")
        val disconnectItem = menu.menu.add("Disconnect")
        menu.setOnMenuItemClickListener { item ->
            when (item) {
                scaleItem -> {
                    val all = ZoomableVideoView.Scale.values()
                    video.scale = all[(video.scale.ordinal + 1) % all.size]
                    prefs.edit().putString("scale", video.scale.name).apply()
                }
                soundItem -> host.setSound(!host.isSoundOn())
                opacityItem -> {
                    val steps = floatArrayOf(0.25f, 0.4f, 0.55f, 0.75f, 1f)
                    controlOpacity = steps[(steps.indexOfFirst { it >= controlOpacity - 0.01f } + 1) % steps.size]
                    gamepad.alpha = controlOpacity
                    prefs.edit().putFloat("opacity", controlOpacity).apply()
                }
                gyroItem -> gyro.cycleMode()
                editItem -> {
                    if (mode != ControlMode.GAMEPAD && mode != ControlMode.PAD) setMode(ControlMode.GAMEPAD)
                    gamepad.setEditing(true)
                }
                statsItem -> host.showStats()
                disconnectItem -> host.disconnect()
            }
            true
        }
        menu.show()
    }

    fun setMode(m: ControlMode) {
        releaseAll()
        val old = mode
        mode = m
        prefs.edit().putString("mode", m.name).apply()
        // Keyboard mode keeps a trackpad above the keys.
        pointer.visibility = if (m.directTouch || m == ControlMode.TRACKPAD || m == ControlMode.KEYBOARD) VISIBLE else GONE
        gamepad.visibility = if (m == ControlMode.GAMEPAD || m == ControlMode.PAD) VISIBLE else GONE
        if (editingLayout && gamepad.visibility != VISIBLE) gamepad.setEditing(false)
        soundPanel.visibility = if (m == ControlMode.SOUND) VISIBLE else GONE
        gyro.enabled = m == ControlMode.GAMEPAD || m == ControlMode.PAD
        keyboard.visibility = if (m == ControlMode.KEYBOARD) VISIBLE else GONE
        if (m != ControlMode.VIEW) video.resetZoom()
        val goal = Goal.of(m)
        prefs.edit().putString("style_${goal.name}", m.name).apply()
        for ((g, b) in goalButtons) {
            b.background = pill(if (g == goal) ACCENT else Color.TRANSPARENT, 11)
        }
        // Second row only where the goal offers a choice of style.
        styleRow.removeAllViews()
        if (goal.modes.size > 1) {
            for (style in goal.modes) {
                styleRow.addView(chip(style.styleLabel) { setMode(style) }.apply {
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                    background = pill(if (style == m) Color.parseColor("#992F6FEB") else Color.TRANSPARENT, 10)
                })
            }
        }
        styleRow.visibility = if (goal.modes.size > 1 && !barCollapsed) VISIBLE else GONE
        if (old != m && initialized) {
            showHint(m.hint)
            host.modeChanged(old, m)
        }
    }

    /** Called once a second with fresh stats. */
    fun updateQuality(stats: StreamClient.Stats, viaUsb: Boolean) {
        val noVideo = mode.noVideo
        val frames = stats.fps + stats.skipped
        val skipRatio = if (frames > 0) stats.skipped.toFloat() / frames else 0f
        var level = 0 // 0 good, 1 fair, 2 poor
        if (!noVideo && (stats.latencyMs > 120 || skipRatio > 0.2f)) level = 2
        else if (!noVideo && (stats.latencyMs > 60 || skipRatio > 0.05f)) level = 1
        if (stats.rttMs > 80) level = 2 else if (stats.rttMs > 30) level = maxOf(level, 1)
        if (stats.audioBufferMs > 70) level = maxOf(level, 1)

        qualityDot.setTextColor(Color.parseColor(arrayOf("#34C759", "#FFB020", "#FF453A")[level]))
        qualityAdvice = when {
            level == 0 -> "Connection is great" + if (viaUsb) " (USB cable)." else " (Wi-Fi)."
            !viaUsb -> "Wi-Fi is slowing things down. Plug in the USB cable, or move closer to your router."
            !noVideo && stats.targetMbps > 40 -> "Video is heavy for this link. On the Mac, open Advanced and set Bitrate to 40 Mbps."
            else -> "The Mac is busy. Close heavy apps, or set Picture to Smooth on the Mac."
        }
    }

    private fun showHint(text: String) {
        hintView.text = text
        hintView.visibility = VISIBLE
        removeCallbacks(hideHint)
        postDelayed(hideHint, 3500)
    }

    /** Stop sensors when the app goes to the background. */
    fun pause() {
        gyro.enabled = false
        releaseAll()
    }

    fun resume() {
        gyro.enabled = mode == ControlMode.GAMEPAD || mode == ControlMode.PAD
    }

    /** Lift every key/button we hold (mode switch, disconnect, app backgrounded). */
    fun releaseAll() {
        gamepad.releaseAll()
        keyboard.releaseAll()
        pointer.release()
    }

    private fun cycleSensitivity(): Float {
        val steps = floatArrayOf(0.75f, 1f, 1.5f, 2f, 3f, 4f)
        sensitivity = steps[(steps.indexOfFirst { it >= sensitivity - 0.01f } + 1) % steps.size]
        prefs.edit().putFloat("sensitivity", sensitivity).apply()
        return sensitivity
    }

    // MARK: Touch + trackpad

    /** TOUCH: the finger is the cursor. TRACKPAD: relative cursor like a laptop trackpad. */
    private inner class PointerLayer : View(context) {
        private val slop = ViewConfiguration.get(context).scaledTouchSlop
        private var startX = 0f
        private var startY = 0f
        private var lastX = 0f
        private var lastY = 0f
        private var downAt = 0L
        private var moved = false
        private var maxPointers = 0
        private var buttonDown = false
        private var remX = 0f
        private var remY = 0f
        private val longPress = Runnable {
            if (!moved && maxPointers == 1 && !mode.directTouch) {
                input()?.mouseButton(0, true) // long-press then drag = click-and-drag
                buttonDown = true
                performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            }
        }

        fun release() {
            removeCallbacks(longPress)
            if (buttonDown) input()?.mouseButton(0, false)
            buttonDown = false
        }

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(e: MotionEvent): Boolean {
            val c = input()
            val direct = mode.directTouch
            val (x, y) = average(e)
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = x; startY = y; lastX = x; lastY = y
                    downAt = e.eventTime; moved = false; maxPointers = 1; remX = 0f; remY = 0f
                    if (direct) {
                        video.mapToVideo(x, y)?.let { c?.mouseMoveAbsolute(it.x, it.y) }
                        c?.mouseButton(0, true)
                        buttonDown = true
                    } else {
                        postDelayed(longPress, 450)
                    }
                }
                MotionEvent.ACTION_POINTER_DOWN -> {
                    maxPointers = maxOf(maxPointers, e.pointerCount)
                    lastX = x; lastY = y
                    removeCallbacks(longPress)
                    if (direct && buttonDown && !moved) {
                        c?.mouseButton(0, false) // second finger: this is a right-click or scroll, not a drag
                        buttonDown = false
                    }
                }
                MotionEvent.ACTION_POINTER_UP -> {
                    // Re-anchor on the remaining fingers so the cursor doesn't jump.
                    val (rx, ry) = average(e, excluding = e.actionIndex)
                    lastX = rx; lastY = ry
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = x - lastX
                    val dy = y - lastY
                    lastX = x; lastY = y
                    if (!moved && hypot(x - startX, y - startY) > slop) {
                        moved = true
                        if (!buttonDown) removeCallbacks(longPress)
                    }
                    when {
                        e.pointerCount >= 2 -> if (moved) c?.scroll((dx * 1.5f).toInt(), (dy * 1.5f).toInt())
                        direct -> video.mapToVideo(x, y)?.let { c?.mouseMoveAbsolute(it.x, it.y) }
                        else -> {
                            // Pointer acceleration: slow moves are precise, fast flicks cross the screen.
                            val speed = hypot(dx, dy)
                            val gain = sensitivity * (0.55f + min(speed / 22f, 1.8f))
                            remX += dx * gain
                            remY += dy * gain
                            val sx = remX.toInt()
                            val sy = remY.toInt()
                            remX -= sx; remY -= sy
                            c?.mouseMove(sx, sy)
                        }
                    }
                }
                MotionEvent.ACTION_UP -> {
                    removeCallbacks(longPress)
                    val tap = !moved && e.eventTime - downAt < 300
                    when {
                        buttonDown -> { c?.mouseButton(0, false); buttonDown = false }
                        tap && maxPointers >= 2 -> { c?.mouseButton(1, true); c?.mouseButton(1, false) }
                        tap && !direct -> { c?.mouseButton(0, true); c?.mouseButton(0, false) }
                    }
                }
                MotionEvent.ACTION_CANCEL -> release()
            }
            return true
        }

        private fun average(e: MotionEvent, excluding: Int = -1): Pair<Float, Float> {
            var sx = 0f
            var sy = 0f
            var n = 0
            for (i in 0 until e.pointerCount) {
                if (i == excluding) continue
                sx += e.getX(i); sy += e.getY(i); n++
            }
            return if (n == 0) e.x to e.y else sx / n to sy / n
        }
    }

    // MARK: Gamepad (GTA V keyboard/mouse layout)

    private inner class GamepadLayer : FrameLayout(context) {
        private val keys = HeldKeys(input)
        private val buttons = ArrayList<ActionButton>()

        init {
            // Anywhere not covered by a control: drag to look around (mouse).
            addView(LookPad(), LayoutParams(MATCH_PARENT, MATCH_PARENT))
            // Floating movement stick over the left half.
            addView(Joystick(keys), LayoutParams(0, 0).also { it.width = MATCH_PARENT; it.height = MATCH_PARENT })

            // Right-hand cluster, measured from the bottom-right corner (dp): label, action, right, bottom, size, look-while-held.
            val cluster = listOf(
                Spec("FIRE", Action.Mouse(0), 22, 34, 92, look = true),
                Spec("AIM", Action.Mouse(1), 30, 146, 74, look = true),
                Spec("Jump", Action.Key(MacKeys.SPACE), 128, 22, 64),
                Spec("Sprint", Action.Key(MacKeys.SHIFT), 204, 22, 64),
                Spec("Reload", Action.Key(MacKeys.R), 128, 98, 60),
                Spec("Cover", Action.Key(MacKeys.Q), 200, 98, 60),
                Spec("Enter", Action.Key(MacKeys.F), 128, 170, 60),
                Spec("Duck", Action.Key(MacKeys.CONTROL), 200, 170, 60),
                Spec("E", Action.Key(MacKeys.E), 272, 22, 56),
            )
            for (s in cluster) {
                val b = ActionButton(s.label, s.action, s.look)
                buttons += b
                addView(b, LayoutParams(dp(s.size), dp(s.size), Gravity.BOTTOM or Gravity.END).apply {
                    rightMargin = dp(s.right); bottomMargin = dp(s.bottom)
                })
            }

            // Top row: menus, weapon wheel, phone, camera, and the usual mod-menu keys.
            val top = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
            val small = listOf(
                "Esc" to MacKeys.ESCAPE, "Weapons" to MacKeys.TAB, "Phone" to MacKeys.UP, "Cam" to MacKeys.V,
                "Behind" to MacKeys.C, "Map" to MacKeys.P, "F4" to MacKeys.F_KEYS[3], "F5" to MacKeys.F_KEYS[4],
                "F8" to MacKeys.F_KEYS[7],
            )
            for ((label, code) in small) {
                val b = ActionButton(label, Action.Key(code), look = false, round = false)
                buttons += b
                top.addView(b, LinearLayout.LayoutParams(WRAP_CONTENT, dp(34)).apply { rightMargin = dp(6) })
            }
            val sens = chip("Look ${sensitivity}x") {}
            sens.setOnClickListener { sens.text = "Look ${cycleSensitivity()}x" }
            top.addView(sens, LinearLayout.LayoutParams(WRAP_CONTENT, dp(34)))
            // Below the goal bar, so the two never overlap on narrower screens.
            addView(top, LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.TOP or Gravity.START).apply {
                topMargin = dp(56); leftMargin = dp(12)
            })
        }

        private val editBar = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = pill(Color.parseColor("#E6000000"), 14)
            setPadding(dp(14), dp(6), dp(6), dp(6))
            addView(TextView(context).apply {
                text = "Drag to move · tap to resize"
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            })
            addView(chip("Reset") { resetLayout() }, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { marginStart = dp(10) })
            addView(chip("Done") { setEditing(false) }.apply { background = pill(ACCENT, 11) },
                LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { marginStart = dp(6) })
            visibility = GONE
        }

        init {
            addView(editBar, LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.CENTER))
        }

        fun releaseAll() {
            keys.releaseAll()
            buttons.forEach { it.release() }
        }

        fun setEditing(on: Boolean) {
            releaseAll()
            editingLayout = on
            editBar.visibility = if (on) VISIBLE else GONE
            buttons.forEach { it.showEditing(on) }
            if (on) showHint("Drag buttons where your thumbs rest. Tap one to change its size.")
        }

        private fun resetLayout() {
            val e = prefs.edit()
            buttons.forEach { e.remove(it.prefKey) }
            e.apply()
            buttons.forEach { it.applySaved(width, height) }
        }

        override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
            super.onSizeChanged(w, h, oldw, oldh)
            // Saved positions are fractions of the screen, so they survive rotation and other phones.
            post { buttons.forEach { it.applySaved(w, h) } }
        }
    }

    private data class Spec(
        val label: String, val action: Action, val right: Int, val bottom: Int, val size: Int, val look: Boolean = false,
    )

    /** Drag to look: relative mouse movement scaled by sensitivity. */
    private inner class LookPad : View(context) {
        private var lastX = 0f
        private var lastY = 0f
        private var remX = 0f
        private var remY = 0f
        private var pointerId = -1

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(e: MotionEvent): Boolean {
            if (editingLayout) return true
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    pointerId = e.getPointerId(0); lastX = e.x; lastY = e.y
                }
                MotionEvent.ACTION_MOVE -> {
                    val i = e.findPointerIndex(pointerId)
                    if (i < 0) return true
                    remX += (e.getX(i) - lastX) * sensitivity
                    remY += (e.getY(i) - lastY) * sensitivity
                    lastX = e.getX(i); lastY = e.getY(i)
                    val sx = remX.toInt()
                    val sy = remY.toInt()
                    remX -= sx; remY -= sy
                    input()?.mouseMove(sx, sy)
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> pointerId = -1
            }
            return true
        }
    }

    /** Floating stick on the left half: touch anywhere there to place it; drives W/A/S/D. */
    private inner class Joystick(private val keys: HeldKeys) : View(context) {
        private val base = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#22000000") }
        private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#59FFFFFF"); style = Paint.Style.STROKE; strokeWidth = dp(1.5f)
        }
        private val knob = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#80FFFFFF") }
        private val radius = dp(62).toFloat()
        private var active = false
        private var cx = 0f
        private var cy = 0f
        private var kx = 0f
        private var ky = 0f

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    // Only claim touches on the left 45% of the screen; the rest is the look pad.
                    if (editingLayout || e.x > width * 0.45f) return false
                    active = true
                    cx = e.x; cy = e.y; kx = cx; ky = cy
                }
                MotionEvent.ACTION_MOVE -> if (active) {
                    var dx = e.x - cx
                    var dy = e.y - cy
                    val dist = hypot(dx, dy)
                    if (dist > radius) {
                        // Drag the base along so the stick never "runs out".
                        cx += dx * (1 - radius / dist); cy += dy * (1 - radius / dist)
                        dx = e.x - cx; dy = e.y - cy
                    }
                    kx = e.x; ky = e.y
                    update(dx / radius, dy / radius)
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    active = false
                    update(0f, 0f)
                }
            }
            invalidate()
            return true
        }

        private fun update(vx: Float, vy: Float) {
            keys.set(MacKeys.W, vy < -0.38f)
            keys.set(MacKeys.S, vy > 0.38f)
            keys.set(MacKeys.A, vx < -0.38f)
            keys.set(MacKeys.D, vx > 0.38f)
        }

        override fun onDraw(canvas: Canvas) {
            val x = if (active) cx else dp(120).toFloat()
            val y = if (active) cy else height - dp(120).toFloat()
            canvas.drawCircle(x, y, radius, base)
            canvas.drawCircle(x, y, radius, ring)
            canvas.drawCircle(if (active) kx else x, if (active) ky else y, radius * 0.42f, knob)
        }
    }

    /** Holds its action while pressed. `look`: dragging on it also turns the camera (fire while aiming). */
    private inner class ActionButton(
        label: String, private val action: Action, private val look: Boolean, private val round: Boolean = true,
    ) : TextView(context) {
        private var pressedDown = false
        private var lastX = 0f
        private var lastY = 0f
        private var remX = 0f
        private var remY = 0f
        val prefKey = "layout_$label"
        private var sizeScale = 1f
        private var dragStartX = 0f
        private var dragStartY = 0f
        private var dragMoved = false
        // Dark glass with a thin outline: visible on bright scenes without glaring on dark ones.
        private val idle = if (round) circle(Color.parseColor("#33000000")) else pill(Color.parseColor("#40000000"), 10)
        private val active = if (round) circle(Color.parseColor("#992F6FEB")) else pill(Color.parseColor("#992F6FEB"), 10)

        init {
            text = label
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#E6FFFFFF"))
            setShadowLayer(dp(2).toFloat(), 0f, 0f, Color.BLACK)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, if (round) 13f else 12f)
            setPadding(dp(10), 0, dp(10), 0)
            background = idle
        }

        fun release() {
            if (!pressedDown) return
            pressedDown = false
            background = idle
            if (action == Action.Mouse(1)) aiming = false
            action.send(input(), false)
        }

        fun showEditing(on: Boolean) {
            background = if (on) (if (round) circle(Color.parseColor("#552F6FEB")) else pill(Color.parseColor("#552F6FEB"), 10)) else idle
        }

        /** Saved as "x,y,scale" with x/y the offset as a fraction of the screen. */
        fun applySaved(screenW: Int, screenH: Int) {
            val parts = prefs.getString(prefKey, null)?.split(",")?.mapNotNull { it.toFloatOrNull() }
            if (parts == null || parts.size != 3 || screenW == 0) {
                translationX = 0f; translationY = 0f; sizeScale = 1f
            } else {
                translationX = parts[0] * screenW; translationY = parts[1] * screenH; sizeScale = parts[2]
            }
            scaleX = sizeScale; scaleY = sizeScale
        }

        private fun save() {
            val root = this@ControlsOverlay
            if (root.width == 0) return
            prefs.edit().putString(prefKey, "${translationX / root.width},${translationY / root.height},$sizeScale").apply()
        }

        @SuppressLint("ClickableViewAccessibility")
        private fun editTouch(e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    dragStartX = e.rawX - translationX; dragStartY = e.rawY - translationY
                    lastX = e.rawX; lastY = e.rawY
                    dragMoved = false
                }
                MotionEvent.ACTION_MOVE -> {
                    if (hypot(e.rawX - lastX, e.rawY - lastY) > dp(6)) dragMoved = true
                    if (dragMoved) {
                        translationX = e.rawX - dragStartX
                        translationY = e.rawY - dragStartY
                    }
                }
                MotionEvent.ACTION_UP -> {
                    if (!dragMoved) {
                        // Tap cycles through sizes.
                        val sizes = floatArrayOf(0.75f, 1f, 1.25f, 1.5f)
                        sizeScale = sizes[(sizes.indexOfFirst { it >= sizeScale - 0.01f } + 1) % sizes.size]
                        scaleX = sizeScale; scaleY = sizeScale
                        performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                    }
                    save()
                }
            }
            return true
        }

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(e: MotionEvent): Boolean {
            if (editingLayout) return editTouch(e)
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    pressedDown = true
                    background = active
                    lastX = e.rawX; lastY = e.rawY
                    performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                    if (action == Action.Mouse(1)) aiming = true
                    action.send(input(), true)
                }
                MotionEvent.ACTION_MOVE -> if (look && pressedDown) {
                    remX += (e.rawX - lastX) * sensitivity
                    remY += (e.rawY - lastY) * sensitivity
                    lastX = e.rawX; lastY = e.rawY
                    val sx = remX.toInt()
                    val sy = remY.toInt()
                    remX -= sx; remY -= sy
                    input()?.mouseMove(sx, sy)
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> release()
            }
            return true
        }
    }

    // MARK: Keyboard

    private inner class KeyboardLayer : LinearLayout(context) {
        private val keys = ArrayList<KeyView>()
        private val latched = HashSet<KeyView>()
        private var functionPage = false

        init {
            orientation = VERTICAL
            setBackgroundColor(Color.parseColor("#E60E1014"))
            setPadding(dp(4), dp(4), dp(4), dp(6))
            render()
        }

        fun releaseAll() {
            keys.forEach { it.release() }
            latched.clear()
        }

        private fun render() {
            releaseAll()
            removeAllViews()
            keys.clear()
            if (functionPage) renderFunctionPage() else renderMainPage()
        }

        private fun renderMainPage() {
            val k = MacKeys
            row(K("Esc", k.ESCAPE, 1.2f), K("`", k.GRAVE), K("1", k.N1), K("2", k.N2), K("3", k.N3), K("4", k.N4),
                K("5", k.N5), K("6", k.N6), K("7", k.N7), K("8", k.N8), K("9", k.N9), K("0", k.N0), K("-", k.MINUS),
                K("=", k.EQUAL), K("⌫", k.DELETE, 1.5f))
            row(K("Tab", k.TAB, 1.5f), K("Q", k.Q), K("W", k.W), K("E", k.E), K("R", k.R), K("T", k.T), K("Y", k.Y),
                K("U", k.U), K("I", k.I), K("O", k.O), K("P", k.P), K("[", k.LEFT_BRACKET), K("]", k.RIGHT_BRACKET),
                K("\\", k.BACKSLASH, 1.2f))
            row(K("Caps", k.CAPS_LOCK, 1.8f), K("A", k.A), K("S", k.S), K("D", k.D), K("F", k.F), K("G", k.G),
                K("H", k.H), K("J", k.J), K("K", k.K), K("L", k.L), K(";", k.SEMICOLON), K("'", k.QUOTE),
                K("Return", k.RETURN, 2f))
            row(K("Shift", k.SHIFT, 2.3f), K("Z", k.Z), K("X", k.X), K("C", k.C), K("V", k.V), K("B", k.B),
                K("N", k.N), K("M", k.M), K(",", k.COMMA), K(".", k.PERIOD), K("/", k.SLASH), K("↑", k.UP),
                K("Shift", k.RIGHT_SHIFT, 1.4f))
            row(K("Fn·Num", -1, 1.8f), K("Ctrl", k.CONTROL, 1.3f), K("Opt", k.OPTION, 1.3f), K("⌘", k.COMMAND, 1.3f),
                K("Space", k.SPACE, 5f), K("⌘", k.COMMAND, 1.3f), K("←", k.LEFT), K("↓", k.DOWN), K("→", k.RIGHT))
        }

        private fun renderFunctionPage() {
            val k = MacKeys
            row(*Array(12) { K("F${it + 1}", k.F_KEYS[it]) }, K("Esc", k.ESCAPE, 1.2f))
            row(K("Home", k.HOME, 1.3f), K("PgUp", k.PAGE_UP, 1.3f), K("⌦", k.FORWARD_DELETE, 1.3f), K("", 0, 0.6f),
                K("Num 7", k.KP7), K("Num 8", k.KP8), K("Num 9", k.KP9), K("Num /", k.KP_DIVIDE))
            row(K("End", k.END, 1.3f), K("PgDn", k.PAGE_DOWN, 1.3f), K("↑", k.UP, 1.3f), K("", 0, 0.6f),
                K("Num 4", k.KP4), K("Num 5", k.KP5), K("Num 6", k.KP6), K("Num *", k.KP_MULTIPLY))
            row(K("←", k.LEFT, 1.3f), K("↓", k.DOWN, 1.3f), K("→", k.RIGHT, 1.3f), K("", 0, 0.6f),
                K("Num 1", k.KP1), K("Num 2", k.KP2), K("Num 3", k.KP3), K("Num -", k.KP_MINUS))
            row(K("ABC", -1, 1.95f), K("Shift", k.SHIFT, 1.95f), K("", 0, 0.6f),
                K("Num 0", k.KP0), K("Num .", k.KP_DECIMAL), K("Num ↵", k.KP_ENTER), K("Num +", k.KP_PLUS))
        }

        private inner class K(val label: String, val code: Int, val weight: Float = 1f)

        private fun row(vararg specs: K) {
            val r = LinearLayout(context).apply { orientation = HORIZONTAL }
            for (s in specs) {
                val view: View = when {
                    s.label.isEmpty() -> View(context)
                    s.code == -1 -> TextView(context).apply {
                        text = s.label
                        gravity = Gravity.CENTER
                        setTextColor(Color.WHITE)
                        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                        background = pill(Color.parseColor("#3A3F4B"), 7)
                        setOnClickListener { functionPage = !functionPage; render() }
                    }
                    else -> KeyView(s.label, s.code).also { keys += it }
                }
                r.addView(view, LayoutParams(0, dp(40), s.weight).apply { setMargins(dp(2), dp(2), dp(2), dp(2)) })
            }
            addView(r, LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }

        /** Normal keys press/release with the finger (holdable in games); modifiers latch until the next key. */
        private inner class KeyView(label: String, private val code: Int) : TextView(context) {
            private val modifier = code in MacKeys.MODIFIERS || code == MacKeys.CAPS_LOCK
            private var down = false

            init {
                text = label
                gravity = Gravity.CENTER
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, if (label.length > 3) 12f else 15f)
                background = pill(if (modifier) Color.parseColor("#3A3F4B") else Color.parseColor("#2A2E37"), 7)
            }

            fun release() {
                if (!down) return
                down = false
                input()?.key(code, false)
                background = pill(if (modifier) Color.parseColor("#3A3F4B") else Color.parseColor("#2A2E37"), 7)
            }

            private fun press() {
                down = true
                input()?.key(code, true)
                background = pill(ACCENT, 7)
            }

            @SuppressLint("ClickableViewAccessibility")
            override fun onTouchEvent(e: MotionEvent): Boolean {
                when (e.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                        if (modifier) {
                            if (down) { release(); latched -= this } else { press(); latched += this }
                        } else {
                            press()
                        }
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> if (!modifier) {
                        release()
                        // Shortcut done (e.g. ⌘C): drop latched modifiers, except Caps Lock.
                        latched.filter { it.code != MacKeys.CAPS_LOCK }.forEach { it.release(); latched -= it }
                    }
                }
                return true
            }
        }
    }

    // MARK: Helpers

    private fun chip(label: String, onClick: () -> Unit) = TextView(context).apply {
        text = label
        gravity = Gravity.CENTER
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setPadding(dp(11), dp(6), dp(11), dp(6))
        background = pill(Color.parseColor("#55000000"), 11)
        setOnClickListener { onClick() }
    }

    private fun pill(color: Int, radiusDp: Int) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radiusDp).toFloat()
    }

    private fun circle(color: Int) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
        setStroke(dp(1), Color.parseColor("#59FFFFFF"))
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun dp(v: Float) = v * resources.displayMetrics.density

    // MARK: Gyro aim

    /**
     * Turn/tilt the phone to aim, mapped to mouse movement. Far more precise than dragging a thumb.
     * Modes: off, only while AIM is held (default), or always.
     */
    private inner class GyroAim : SensorEventListener {
        private val sensors = context.getSystemService(SensorManager::class.java)
        private val gyroSensor = sensors?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        private var gyroMode = prefs.getInt("gyroMode", 1) // 0 off, 1 while aiming, 2 always
        private var lastTimestamp = 0L
        private var remX = 0f
        private var remY = 0f
        private var registered = false

        var enabled = false
            set(value) {
                field = value
                updateRegistration()
            }

        val modeLabel get() = when {
            gyroSensor == null -> "Not available"
            gyroMode == 0 -> "Off"
            gyroMode == 1 -> "While aiming"
            else -> "Always"
        }

        fun cycleMode() {
            gyroMode = (gyroMode + 1) % 3
            prefs.edit().putInt("gyroMode", gyroMode).apply()
            updateRegistration()
        }

        private fun updateRegistration() {
            val want = enabled && gyroMode != 0 && gyroSensor != null
            if (want && !registered) {
                lastTimestamp = 0
                registered = sensors.registerListener(this, gyroSensor, SensorManager.SENSOR_DELAY_FASTEST)
            } else if (!want && registered) {
                sensors.unregisterListener(this)
                registered = false
            }
        }

        override fun onSensorChanged(e: SensorEvent) {
            val dt = if (lastTimestamp == 0L) 0f else (e.timestamp - lastTimestamp) / 1e9f
            lastTimestamp = e.timestamp
            if (dt <= 0f || dt > 0.1f) return
            if (gyroMode == 1 && !aiming) return
            // Map device axes to screen yaw/pitch for the current landscape orientation.
            @Suppress("DEPRECATION")
            val rotation = context.getSystemService(WindowManager::class.java).defaultDisplay.rotation
            val (yaw, pitch) = when (rotation) {
                Surface.ROTATION_90 -> -e.values[0] to e.values[1]
                Surface.ROTATION_270 -> e.values[0] to -e.values[1]
                Surface.ROTATION_180 -> e.values[1] to e.values[0]
                else -> -e.values[1] to -e.values[0]
            }
            val pixelsPerRadian = 700f * sensitivity
            remX += yaw * dt * pixelsPerRadian
            remY += pitch * dt * pixelsPerRadian
            val sx = remX.toInt()
            val sy = remY.toInt()
            if (sx == 0 && sy == 0) return
            remX -= sx; remY -= sy
            input()?.mouseMove(sx, sy)
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    }

    companion object {
        private val ACCENT = Color.parseColor("#2F6FEB")
    }
}

/**
 * A Bluetooth/USB controller paired with the phone (Xbox, PlayStation, …), mapped to GTA V's
 * keyboard/mouse controls: left stick → WASD, right stick → mouse look, triggers → aim/fire.
 */
class PhysicalGamepad(private val input: InputProvider, private val sensitivity: () -> Float) {
    private val keys = HeldKeys(input)
    private val ui = Handler(Looper.getMainLooper())
    private var lookX = 0f
    private var lookY = 0f
    private var remX = 0f
    private var remY = 0f
    private var fire = false
    private var aim = false
    private var looping = false

    private val lookLoop = object : Runnable {
        override fun run() {
            if (lookX == 0f && lookY == 0f) { looping = false; return }
            val speed = 16f * sensitivity()
            remX += curve(lookX) * speed
            remY += curve(lookY) * speed
            val sx = remX.toInt()
            val sy = remY.toInt()
            remX -= sx; remY -= sy
            input()?.mouseMove(sx, sy)
            ui.postDelayed(this, 8) // ~120 Hz
        }
    }

    fun onMotion(e: MotionEvent): Boolean {
        if (e.source and InputDevice.SOURCE_JOYSTICK != InputDevice.SOURCE_JOYSTICK ||
            e.actionMasked != MotionEvent.ACTION_MOVE) return false
        val lx = e.getAxisValue(MotionEvent.AXIS_X)
        val ly = e.getAxisValue(MotionEvent.AXIS_Y)
        keys.set(MacKeys.W, ly < -0.4f)
        keys.set(MacKeys.S, ly > 0.4f)
        keys.set(MacKeys.A, lx < -0.4f)
        keys.set(MacKeys.D, lx > 0.4f)

        lookX = deadzone(e.getAxisValue(MotionEvent.AXIS_Z))
        lookY = deadzone(e.getAxisValue(MotionEvent.AXIS_RZ))
        if ((lookX != 0f || lookY != 0f) && !looping) { looping = true; ui.post(lookLoop) }

        val rt = maxOf(e.getAxisValue(MotionEvent.AXIS_RTRIGGER), e.getAxisValue(MotionEvent.AXIS_GAS)) > 0.4f
        val lt = maxOf(e.getAxisValue(MotionEvent.AXIS_LTRIGGER), e.getAxisValue(MotionEvent.AXIS_BRAKE)) > 0.4f
        if (rt != fire) { fire = rt; input()?.mouseButton(0, rt) }
        if (lt != aim) { aim = lt; input()?.mouseButton(1, lt) }

        val hx = e.getAxisValue(MotionEvent.AXIS_HAT_X)
        val hy = e.getAxisValue(MotionEvent.AXIS_HAT_Y)
        keys.set(MacKeys.LEFT, hx < -0.5f)
        keys.set(MacKeys.RIGHT, hx > 0.5f)
        keys.set(MacKeys.UP, hy < -0.5f)
        keys.set(MacKeys.DOWN, hy > 0.5f)
        return true
    }

    fun onKey(e: KeyEvent): Boolean {
        if (e.source and InputDevice.SOURCE_GAMEPAD != InputDevice.SOURCE_GAMEPAD) return false
        val code = when (e.keyCode) {
            KeyEvent.KEYCODE_BUTTON_A -> MacKeys.SHIFT        // sprint
            KeyEvent.KEYCODE_BUTTON_B -> MacKeys.R            // reload / melee
            KeyEvent.KEYCODE_BUTTON_X -> MacKeys.SPACE        // jump / handbrake
            KeyEvent.KEYCODE_BUTTON_Y -> MacKeys.F            // enter / exit vehicle
            KeyEvent.KEYCODE_BUTTON_L1 -> MacKeys.TAB         // weapon wheel
            KeyEvent.KEYCODE_BUTTON_R1 -> MacKeys.Q           // cover
            KeyEvent.KEYCODE_BUTTON_THUMBL -> MacKeys.CONTROL // duck
            KeyEvent.KEYCODE_BUTTON_THUMBR -> MacKeys.C       // look behind
            KeyEvent.KEYCODE_BUTTON_START -> MacKeys.ESCAPE   // pause
            KeyEvent.KEYCODE_BUTTON_SELECT -> MacKeys.V       // camera
            KeyEvent.KEYCODE_DPAD_UP -> MacKeys.UP
            KeyEvent.KEYCODE_DPAD_DOWN -> MacKeys.DOWN
            KeyEvent.KEYCODE_DPAD_LEFT -> MacKeys.LEFT
            KeyEvent.KEYCODE_DPAD_RIGHT -> MacKeys.RIGHT
            else -> return false
        }
        when (e.action) {
            KeyEvent.ACTION_DOWN -> keys.set(code, true)
            KeyEvent.ACTION_UP -> keys.set(code, false)
        }
        return true
    }

    fun releaseAll() {
        keys.releaseAll()
        if (fire) input()?.mouseButton(0, false)
        if (aim) input()?.mouseButton(1, false)
        fire = false; aim = false; lookX = 0f; lookY = 0f
    }

    private fun deadzone(v: Float) = if (abs(v) < 0.12f) 0f else v
    private fun curve(v: Float) = v * v * sign(v) // fine control near center, fast at the edge
}
