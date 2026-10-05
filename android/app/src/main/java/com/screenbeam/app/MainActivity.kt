package com.screenbeam.app

import android.app.Activity
import android.net.Uri
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.speech.RecognizerIntent
import android.view.KeyEvent
import android.view.MotionEvent
import android.widget.Toast
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.Surface
import android.view.SurfaceHolder
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView

class MainActivity : Activity(), SurfaceHolder.Callback, ControlsHost {

    private lateinit var video: ZoomableVideoView
    private lateinit var picker: ScrollView
    private lateinit var pickerMessage: TextView
    private lateinit var hostList: LinearLayout
    private lateinit var manualInput: EditText
    private lateinit var statusPanel: LinearLayout
    private lateinit var statusText: TextView
    private lateinit var hud: LinearLayout
    private lateinit var hudText: TextView
    private lateinit var controls: ControlsOverlay
    private val physicalGamepad = PhysicalGamepad({ client }, { controls.sensitivity })

    private lateinit var discovery: Discovery
    private var discovered: List<Discovery.Host> = emptyList()
    private var surface: Surface? = null
    private var client: StreamClient? = null
    private var clientGeneration = 0             // ignores callbacks from clients we already stopped
    private var target: Discovery.Host? = null   // the Mac we want to be watching
    private var autoConnectTried = false
    private var wifiLock: WifiManager.WifiLock? = null
    private var usbAvailable = false
    @Volatile private var started = false
    private val usbHost = Discovery.Host(USB_NAME, "127.0.0.1", StreamClient.DEFAULT_PORT)

    private val ui = Handler(Looper.getMainLooper())
    private val hideHud = Runnable { hud.visibility = View.GONE }
    private val prefs by lazy { getSharedPreferences("screenbeam", Context.MODE_PRIVATE) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        volumeControlStream = android.media.AudioManager.STREAM_MUSIC // volume keys adjust the Mac's sound
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        setContentView(buildUi())
        discovery = Discovery(this) { hosts ->
            discovered = hosts
            renderHosts()
            maybeAutoConnect()
        }
        showPicker(null)
        intent?.data?.let { handlePairLink(it.toString()) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.data?.let { handlePairLink(it.toString()) }
    }

    // MARK: QR pairing

    private fun scanQr() {
        val options = GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .enableAutoZoom()
            .build()
        GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { code -> handlePairLink(code.rawValue ?: "") }
            .addOnFailureListener {
                Toast.makeText(this, "Couldn't open the scanner. Enter the address instead.", Toast.LENGTH_LONG).show()
            }
    }

    /** screenbeam://pair?name=…&ips=a,b&port=…&code=… — saves the code and connects in one step. */
    private fun handlePairLink(raw: String) {
        val uri = Uri.parse(raw)
        if (uri.scheme != "screenbeam" || uri.host != "pair") {
            Toast.makeText(this, "That isn't a ScreenBeam code", Toast.LENGTH_SHORT).show()
            return
        }
        val name = uri.getQueryParameter("name") ?: "Mac"
        val code = uri.getQueryParameter("code") ?: return
        val port = uri.getQueryParameter("port")?.toIntOrNull() ?: StreamClient.DEFAULT_PORT
        val ip = uri.getQueryParameter("ips")?.split(",")?.firstOrNull { it.isNotBlank() }
        prefs.edit()
            .putString("pin_$name", code).putString("pin_$USB_NAME", code).putString("pin_last", code)
            .apply()
        // Prefer the cable, then this Mac as found on the network, then the address in the code.
        val host = when {
            usbAvailable -> usbHost
            else -> discovered.firstOrNull { it.name == name } ?: ip?.let { Discovery.Host(name, it, port) }
        } ?: run {
            Toast.makeText(this, "Paired, but $name isn't reachable. Is it on the same Wi-Fi?", Toast.LENGTH_LONG).show()
            return
        }
        Toast.makeText(this, "Paired with $name", Toast.LENGTH_SHORT).show()
        connect(host)
    }

    // Stream on start/stop (not resume/pause) so the voice-input popup doesn't drop the connection.
    override fun onStart() {
        super.onStart()
        started = true
        if (::controls.isInitialized) controls.resume()
        startUsbProbe()
        discovery.start()
        if (target != null && surface != null && client == null) startClient()
    }

    override fun onResume() {
        super.onResume()
        goImmersive()
    }

    override fun onStop() {
        super.onStop()
        started = false
        controls.pause()
        discovery.stop()
        stopClient() // keeps `target`, so we reconnect when the app comes back
    }

    // A controller paired with the phone drives the game directly.
    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean =
        (client != null && physicalGamepad.onMotion(event)) || super.dispatchGenericMotionEvent(event)

    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        (client != null && physicalGamepad.onKey(event)) || super.dispatchKeyEvent(event)

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_VOICE || resultCode != RESULT_OK) return
        val text = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull() ?: return
        client?.text(text)
    }

    /**
     * The Mac runs `adb reverse` when the phone is plugged in, which makes it reachable at 127.0.0.1.
     * Probe for that tunnel every couple of seconds while the app is visible.
     */
    private fun startUsbProbe() {
        Thread({
            while (started) {
                val ok = try {
                    java.net.Socket().use { it.connect(java.net.InetSocketAddress("127.0.0.1", StreamClient.DEFAULT_PORT), 300) }
                    true
                } catch (_: Exception) {
                    false
                }
                ui.post {
                    if (ok != usbAvailable) {
                        usbAvailable = ok
                        renderHosts()
                        maybeAutoConnect()
                    }
                }
                try { Thread.sleep(2000) } catch (_: InterruptedException) { return@Thread }
            }
        }, "ScreenBeam-usb").start()
    }

    // MARK: ControlsHost

    override fun voiceInput() = startVoiceInput()
    override fun typeText() = showTypeDialog()
    override fun showStats() = flashHud()
    override fun isSoundOn() = prefs.getBoolean("sound", true)

    override fun setSound(on: Boolean) {
        prefs.edit().putBoolean("sound", on).apply()
        client?.soundOn = on
        // Pad mode only asks the Mac for sound when it's on, so reconnect to start/stop it.
        if (controls.mode == ControlMode.PAD && target != null) startClient()
    }

    override fun modeChanged(old: ControlMode, new: ControlMode) {
        applyPadLook()
        // Pad mode connects without video; switching in or out of it renegotiates with the Mac.
        // Pad and Sound connect without video; moving into, out of, or between them renegotiates with the Mac.
        if ((old.noVideo || new.noVideo) && target != null) {
            showStatus(when (new) {
                ControlMode.PAD -> "Switching to controller mode…"
                ControlMode.SOUND -> "Switching to sound only…"
                else -> "Starting video…"
            })
            startClient()
        }
    }

    /** Pad mode: black screen and low brightness (saves battery; you're watching the Mac). */
    private fun applyPadLook() {
        val pad = controls.mode.noVideo
        controls.setBackgroundColor(if (pad) Color.BLACK else Color.TRANSPARENT)
        window.attributes = window.attributes.apply {
            screenBrightness = if (pad) 0.15f else WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
        }
    }

    private fun startVoiceInput() {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_PROMPT, "Speak to type on your Mac")
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQUEST_VOICE)
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(this, "Voice input isn't available on this phone", Toast.LENGTH_SHORT).show()
        }
    }

    private fun showTypeDialog() {
        val field = EditText(this).apply {
            hint = "Text to type on the Mac"
            isSingleLine = false
        }
        AlertDialog.Builder(this)
            .setTitle("Type on Mac")
            .setView(field)
            .setPositiveButton("Send") { _, _ -> client?.text(field.text.toString()) }
            .setNeutralButton("Send + Return") { _, _ ->
                client?.text(field.text.toString())
                client?.key(MacKeys.RETURN, true); client?.key(MacKeys.RETURN, false)
            }
            .setNegativeButton("Cancel", null)
            .show()
        field.requestFocus()
    }

    private fun askPairingCode(host: Discovery.Host, message: String) {
        val field = EditText(this).apply {
            hint = "6-digit code"
            inputType = InputType.TYPE_CLASS_NUMBER
            setText("")
        }
        AlertDialog.Builder(this)
            .setTitle("Pair with ${host.name}")
            .setMessage("$message\n\nThe code is shown in the ScreenBeam window on your Mac.")
            .setView(field)
            .setPositiveButton("Pair") { _, _ ->
                val pin = field.text.toString().trim()
                prefs.edit().putString("pin_${host.name}", pin).putString("pin_last", pin).apply()
                connect(host)
            }
            .setNegativeButton("Cancel") { _, _ -> showPicker(null) }
            .setCancelable(false)
            .show()
        field.requestFocus()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) goImmersive()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (target != null) disconnect() else @Suppress("DEPRECATION") super.onBackPressed()
    }

    // MARK: Connection

    private fun connect(host: Discovery.Host) {
        target = host
        prefs.edit()
            .putString("name", host.name).putString("address", host.address).putInt("port", host.port)
            .apply()
        hideKeyboard()
        showStatus("Connecting to ${host.name}…")
        if (surface != null) startClient()
    }

    override fun disconnect() {
        target = null
        stopClient()
        showPicker(null)
    }

    private fun startClient() {
        val host = target ?: return
        val s = surface ?: return
        stopClient()
        acquireWifiLock()
        clientGeneration++
        // USB and Wi-Fi reach the same Mac, so fall back to the last code that worked.
        val pin = prefs.getString("pin_${host.name}", null) ?: prefs.getString("pin_last", "") ?: ""
        client = StreamClient(
            host.address, host.port, s, deviceName(), pin,
            noVideo = controls.mode.noVideo,
            // Sound mode always wants audio; Pad plays it if sound is on; video modes always receive it (muted locally if off).
            wantsAudio = controls.mode == ControlMode.SOUND || !controls.mode.noVideo || isSoundOn(),
            soundOnly = controls.mode == ControlMode.SOUND,
            listener = Callbacks(clientGeneration),
        ).also {
            it.soundOn = isSoundOn() || controls.mode == ControlMode.SOUND
            it.start()
        }
    }

    private fun stopClient() {
        clientGeneration++
        if (::controls.isInitialized) controls.releaseAll()
        physicalGamepad.releaseAll()
        client?.stop()
        client = null
        wifiLock?.let { if (it.isHeld) it.release() }
    }

    /** Stops Wi-Fi power saving while streaming; this removes most latency spikes on phones. */
    private fun acquireWifiLock() {
        val lock = wifiLock ?: run {
            val wm = applicationContext.getSystemService(WifiManager::class.java)
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wm.createWifiLock(mode, "ScreenBeam").apply { setReferenceCounted(false) }
        }
        wifiLock = lock
        if (!lock.isHeld) lock.acquire()
    }

    private fun maybeAutoConnect() {
        if (autoConnectTried || target != null || picker.visibility != View.VISIBLE) return
        val lastName = prefs.getString("name", null) ?: return
        if (usbAvailable && prefs.getString("pin_last", null) != null) {
            // A cable is plugged in and we've paired before: USB beats Wi-Fi.
            autoConnectTried = true
            connect(usbHost)
            return
        }
        val match = discovered.firstOrNull { it.name == lastName } ?: return
        autoConnectTried = true
        connect(match)
    }

    private fun deviceName(): String =
        Settings.Global.getString(contentResolver, "device_name")?.takeIf { it.isNotBlank() } ?: Build.MODEL

    // MARK: StreamClient.Listener

    /** Hops callbacks from the network thread to the UI thread, dropping ones from stale clients. */
    private inner class Callbacks(private val generation: Int) : StreamClient.Listener {
        private fun onUi(block: () -> Unit) {
            ui.post { if (generation == clientGeneration) block() }
        }

        override fun onConnecting(attempt: Int, lastError: String?) = onUi {
            val name = target?.name ?: "Mac"
            showStatus(if (lastError == null) "Connecting to $name…" else "Reconnecting to $name…\n$lastError")
        }

        override fun onStreaming() = onUi {
            statusPanel.visibility = View.GONE
            picker.visibility = View.GONE
            controls.visibility = View.VISIBLE
            flashHud()
        }

        override fun onVideoSize(width: Int, height: Int) = onUi { video.setVideoSize(width, height) }

        override fun onStats(stats: StreamClient.Stats) = onUi {
            controls.updateQuality(stats, viaUsb = target?.address == "127.0.0.1")
            hudText.text = buildString {
                append("${stats.fps} fps  ·  ${stats.latencyMs} ms latency  ·  ")
                append("%.0f/%.0f Mbps".format(stats.mbps, stats.targetMbps))
                append("  ·  ping ${stats.rttMs} ms")
                if (stats.skipped > 0) append("  ·  ${stats.skipped} skipped")
            }
        }

        override fun onStopped(message: String) = onUi {
            target = null
            stopClient()
            showPicker(message)
        }

        override fun onPairingRequired(message: String) = onUi {
            val host = target ?: return@onUi
            target = null
            stopClient()
            controls.visibility = View.GONE
            askPairingCode(host, message)
        }
    }

    // MARK: Surface

    override fun surfaceCreated(holder: SurfaceHolder) {
        surface = holder.surface
        if (target != null && client == null) startClient()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        stopClient()
        surface = null
    }

    // MARK: UI

    private fun showPicker(message: String?) {
        controls.visibility = View.GONE
        statusPanel.visibility = View.GONE
        hud.visibility = View.GONE
        picker.visibility = View.VISIBLE
        pickerMessage.visibility = if (message == null) View.GONE else View.VISIBLE
        pickerMessage.text = message
        renderHosts()
    }

    private fun showStatus(text: String) {
        controls.visibility = View.GONE
        picker.visibility = View.GONE
        statusPanel.visibility = View.VISIBLE
        statusText.text = text
    }

    private fun flashHud() {
        hud.visibility = View.VISIBLE
        ui.removeCallbacks(hideHud)
        ui.postDelayed(hideHud, 3500)
    }

    private fun renderHosts() {
        hostList.removeAllViews()
        val hosts = discovered.toMutableList()
        if (usbAvailable) hosts.add(0, usbHost)
        val lastName = prefs.getString("name", null)
        val lastAddress = prefs.getString("address", null)
        if (lastName != null && lastName != USB_NAME && lastAddress != null && hosts.none { it.name == lastName }) {
            hosts += Discovery.Host(lastName, lastAddress, prefs.getInt("port", StreamClient.DEFAULT_PORT))
        }
        if (discovered.isEmpty()) {
            hostList.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, dp(8), 0, dp(8))
                addView(ProgressBar(context).apply { isIndeterminate = true }, LinearLayout.LayoutParams(dp(20), dp(20)))
                addView(label("Searching for Macs on this Wi-Fi…", 14f, MUTED).apply { setPadding(dp(12), 0, 0, 0) })
            })
        }
        for (host in hosts) {
            val found = host === usbHost || discovered.any { it.name == host.name }
            hostList.addView(
                pillButton("${host.name}\n${host.address}${if (found) "" else "  ·  last used"}", primary = found) {
                    connect(host)
                },
                LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = dp(8) },
            )
        }
    }

    private fun connectManual() {
        val text = manualInput.text.toString().trim()
        if (text.isEmpty()) return
        val parts = text.split(":")
        val port = parts.getOrNull(1)?.toIntOrNull() ?: StreamClient.DEFAULT_PORT
        connect(Discovery.Host(parts[0], parts[0], port))
    }

    private fun buildUi(): View {
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }

        video = ZoomableVideoView(this).apply {
            surfaceView.holder.addCallback(this@MainActivity)
            onSingleTap = { if (hud.visibility == View.VISIBLE) hud.visibility = View.GONE else flashHud() }
        }
        root.addView(video, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))

        controls = ControlsOverlay(this, video, { client }, this).apply {
            visibility = View.GONE
        }
        root.addView(controls, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        applyPadLook()

        // Connection picker.
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(28), dp(48), dp(28), dp(32))
        }
        content.addView(label("ScreenBeam", 30f, Color.WHITE, bold = true))
        content.addView(label("Open ScreenBeam on your Mac, then scan the QR code in its window.", 15f, MUTED).apply {
            setPadding(0, dp(6), 0, dp(16))
        })
        content.addView(
            pillButton("📷  Scan QR code", primary = true) { scanQr() }.apply {
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                gravity = Gravity.CENTER
                textAlignment = View.TEXT_ALIGNMENT_CENTER
                setPadding(dp(16), dp(16), dp(16), dp(16))
                contentDescription = "Scan the QR code shown on your Mac to pair and connect"
            },
            LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { bottomMargin = dp(20) },
        )
        content.addView(label("Or pick your Mac", 13f, MUTED).apply { setPadding(0, 0, 0, dp(4)) })
        pickerMessage = label("", 14f, Color.parseColor("#FFB4A9")).apply {
            background = rounded(Color.parseColor("#3A1D1A"), dp(10).toFloat())
            setPadding(dp(14), dp(12), dp(14), dp(12))
        }
        content.addView(pickerMessage, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { bottomMargin = dp(12) })
        hostList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        content.addView(hostList)

        content.addView(label("Or enter the address shown in the Mac's menu bar", 13f, MUTED).apply {
            setPadding(0, dp(28), 0, dp(8))
        })
        val manualRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        manualInput = EditText(this).apply {
            hint = "192.168.1.20"
            setTextColor(Color.WHITE)
            setHintTextColor(Color.parseColor("#66FFFFFF"))
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            imeOptions = EditorInfo.IME_ACTION_GO
            isSingleLine = true
            background = rounded(Color.parseColor("#1C1F26"), dp(12).toFloat())
            setPadding(dp(14), dp(12), dp(14), dp(12))
            setText(prefs.getString("address", ""))
            setOnEditorActionListener { _, _, _ -> connectManual(); true }
        }
        manualRow.addView(manualInput, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        manualRow.addView(pillButton("Connect", primary = true) { connectManual() },
            LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { marginStart = dp(10) })
        content.addView(manualRow)

        picker = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor("#0E1014"))
            isFillViewport = true
            addView(content)
        }
        root.addView(picker, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))

        // Connecting / reconnecting overlay.
        statusPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            background = rounded(Color.parseColor("#E6141820"), dp(18).toFloat())
            setPadding(dp(28), dp(24), dp(28), dp(20))
            addView(ProgressBar(context).apply { isIndeterminate = true })
            statusText = label("", 15f, Color.WHITE).apply {
                gravity = Gravity.CENTER
                setPadding(0, dp(14), 0, dp(14))
            }
            addView(statusText)
            addView(pillButton("Cancel", primary = false) { disconnect() })
        }
        root.addView(statusPanel, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.CENTER).apply {
            leftMargin = dp(32); rightMargin = dp(32)
        })

        // Tap-to-show stats bar while streaming.
        hud = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rounded(Color.parseColor("#CC000000"), dp(14).toFloat())
            setPadding(dp(16), dp(6), dp(6), dp(6))
            hudText = label("", 13f, Color.WHITE)
            addView(hudText)
            addView(pillButton("Disconnect", primary = false) { disconnect() },
                LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { marginStart = dp(12) })
            visibility = View.GONE
        }
        root.addView(hud, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply {
            topMargin = dp(54) // below the control bars
        })
        return root
    }

    private fun label(text: String, sizeSp: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        this.text = text
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
        setTextColor(color)
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    private fun pillButton(text: String, primary: Boolean, onClick: () -> Unit) = Button(this).apply {
        this.text = text
        isAllCaps = false
        setTextColor(Color.WHITE)
        textAlignment = View.TEXT_ALIGNMENT_VIEW_START
        gravity = Gravity.CENTER_VERTICAL or Gravity.START
        background = rounded(if (primary) ACCENT else Color.parseColor("#2A2E37"), dp(12).toFloat())
        setPadding(dp(16), dp(10), dp(16), dp(10))
        stateListAnimator = null
        setOnClickListener { onClick() }
    }

    private fun rounded(color: Int, radius: Float) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = radius
    }

    private fun goImmersive() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)
        }
    }

    private fun hideKeyboard() {
        getSystemService(InputMethodManager::class.java)?.hideSoftInputFromWindow(manualInput.windowToken, 0)
        manualInput.clearFocus()
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    companion object {
        private val ACCENT = Color.parseColor("#2F6FEB")
        private val MUTED = Color.parseColor("#9AA3B2")
        private const val REQUEST_VOICE = 1
        private const val USB_NAME = "Mac via USB cable"
    }
}
